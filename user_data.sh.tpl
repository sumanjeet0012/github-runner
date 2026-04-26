#!/bin/bash
set -euo pipefail
exec > >(tee /var/log/github-runner-init.log | logger -t github-runner-init) 2>&1

echo "=== Updating system packages ==="
apt-get update -y
apt-get upgrade -y
apt-get install -y curl jq unzip

echo "=== Installing AWS CLI v2 ==="
curl -fsSL "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o /tmp/awscliv2.zip
unzip -q /tmp/awscliv2.zip -d /tmp
/tmp/aws/install
rm -rf /tmp/awscliv2.zip /tmp/aws

echo "=== Fetching GitHub PAT from Secrets Manager ==="
ACCESS_TOKEN=$(aws secretsmanager get-secret-value \
  --region ${aws_region} \
  --secret-id '${github_pat_secret_name}' \
  --query SecretString \
  --output text)

if [[ -z "$ACCESS_TOKEN" ]]; then
  echo "ERROR: Failed to fetch PAT from Secrets Manager"
  exit 1
fi
echo "PAT fetched successfully."

echo "=== Resolving runner name from instance tag ==="
INSTANCE_ID=$(curl -fsSL http://169.254.169.254/latest/meta-data/instance-id)
REGION=$(curl -fsSL http://169.254.169.254/latest/meta-data/placement/region)
RUNNER_NAME=$(aws ec2 describe-tags \
  --region "$REGION" \
  --filters "Name=resource-id,Values=$INSTANCE_ID" "Name=key,Values=RunnerName" \
  --query 'Tags[0].Value' \
  --output text 2>/dev/null || echo "${runner_name}")
# Fall back to template value if tag is missing or is the placeholder
if [[ -z "$RUNNER_NAME" || "$RUNNER_NAME" == "None" || "$RUNNER_NAME" == "__FROM_TAG__" ]]; then
  RUNNER_NAME="${runner_name}-$INSTANCE_ID"
fi
echo "Runner name: $RUNNER_NAME"

echo "=== Creating actions-runner user ==="
useradd -m -s /bin/bash actions-runner || true

echo "=== Downloading GitHub Actions Runner ==="
RUNNER_VERSION=$(curl -fsSL https://api.github.com/repos/actions/runner/releases/latest | jq -r '.tag_name' | sed 's/v//')
echo "Runner version: $RUNNER_VERSION"
RUNNER_DIR=/actions-runner
mkdir -p "$RUNNER_DIR"
curl -fsSL \
  "https://github.com/actions/runner/releases/download/v$${RUNNER_VERSION}/actions-runner-linux-x64-$${RUNNER_VERSION}.tar.gz" \
  -o /tmp/runner.tar.gz
tar -xzf /tmp/runner.tar.gz -C "$RUNNER_DIR"
rm /tmp/runner.tar.gz
chown -R actions-runner:actions-runner "$RUNNER_DIR"

echo "=== Installing runner dependencies ==="
"$RUNNER_DIR/bin/installdependencies.sh"

echo "=== Writing entrypoint script ==="
cat > /usr/local/bin/github-runner-entrypoint.sh << 'ENTRYPOINT_EOF'
${entrypoint_script}
ENTRYPOINT_EOF
chmod +x /usr/local/bin/github-runner-entrypoint.sh

echo "=== Writing runner wrapper (status check + run + self-terminate) ==="
cat > /usr/local/bin/github-runner-wrapper.sh << 'WRAPPER_EOF'
#!/bin/bash
# Pre-flight check: verify job is still active
# Run the GitHub Actions runner (ephemeral – exits after one job)
# Then terminate this EC2 instance regardless of exit code
set -euo pipefail

INSTANCE_ID=$(curl -fsSL http://169.254.169.254/latest/meta-data/instance-id)
REGION=$(curl -fsSL http://169.254.169.254/latest/meta-data/placement/region)

echo "[wrapper] Starting runner on instance $INSTANCE_ID"

# Fetch job_id from EC2 instance tag
JOB_ID=$(aws ec2 describe-tags \
  --region "$REGION" \
  --filters "Name=resource-id,Values=$INSTANCE_ID" "Name=key,Values=GitHubJobId" \
  --query 'Tags[0].Value' \
  --output text 2>/dev/null || echo "")

if [[ -z "$JOB_ID" || "$JOB_ID" == "None" ]]; then
  echo "[wrapper] WARNING: Could not fetch job_id from EC2 tags. Proceeding anyway."
else
  echo "[wrapper] Job ID: $JOB_ID. Checking job status on GitHub..."
  
  # Build GitHub API URL based on runner scope
  if [[ "${RUNNER_SCOPE:-}" == "org" && -n "${ORG_NAME:-}" ]]; then
    # For org-scoped runners, we need to get the job from a repo (use actions API)
    # Try the universal-connectivity repo first, then fall back
    JOB_URL="https://api.github.com/repos/${ORG_NAME}/universal-connectivity/actions/jobs/$JOB_ID"
  else
    JOB_URL="https://api.github.com/repos/$(echo $REPO_URL | awk -F/ '{print $(NF-1)"/"$NF}')/actions/jobs/$JOB_ID"
  fi
  
  # Query GitHub API for job status
  JOB_STATUS=$(curl -fsSL \
    -H "Authorization: Bearer ${ACCESS_TOKEN}" \
    -H "Accept: application/vnd.github+json" \
    "$JOB_URL" 2>/dev/null | jq -r '.status // "unknown"' || echo "unknown")
  
  echo "[wrapper] Job status from GitHub: $JOB_STATUS"
  
  # If job is cancelled or completed, don't run it
  if [[ "$JOB_STATUS" == "completed" ]] || [[ "$JOB_STATUS" == "cancelled" ]]; then
    echo "[wrapper] Job $JOB_ID was $JOB_STATUS. Skipping runner execution."
    echo "[wrapper] Terminating instance $INSTANCE_ID ..."
    aws ec2 terminate-instances --region "$REGION" --instance-ids "$INSTANCE_ID"
    exit 0
  elif [[ "$JOB_STATUS" == "in_progress" ]] || [[ "$JOB_STATUS" == "queued" ]]; then
    echo "[wrapper] Job is $JOB_STATUS. Safe to proceed."
  else
    echo "[wrapper] WARNING: Unexpected job status '$JOB_STATUS'. Proceeding anyway."
  fi
fi

# Run the entrypoint; capture exit code but don't abort the wrapper
/usr/local/bin/github-runner-entrypoint.sh || true
RUNNER_EXIT=$?

echo "[wrapper] Runner exited with code $RUNNER_EXIT. Terminating instance $INSTANCE_ID ..."
aws ec2 terminate-instances --region "$REGION" --instance-ids "$INSTANCE_ID"
WRAPPER_EOF
chmod +x /usr/local/bin/github-runner-wrapper.sh

echo "=== Creating systemd service ==="
cat > /etc/systemd/system/github-runner.service << SERVICE_EOF
[Unit]
Description=GitHub Actions Runner (ephemeral)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=actions-runner
WorkingDirectory=/actions-runner
Environment="ACCESS_TOKEN=$ACCESS_TOKEN"
Environment="RUNNER_SCOPE=${runner_scope}"
Environment="REPO_URL=${repo_url}"
Environment="ORG_NAME=${org_name}"
Environment="LABELS=${runner_labels}"
Environment="RUNNER_NAME=$RUNNER_NAME"
# Use the wrapper so the instance self-terminates after the job (pass or fail)
ExecStart=/usr/local/bin/github-runner-wrapper.sh
Restart=no
StandardOutput=journal
StandardError=journal
SyslogIdentifier=github-runner

[Install]
WantedBy=multi-user.target
SERVICE_EOF

echo "=== Enabling and starting github-runner service ==="
systemctl daemon-reload
systemctl enable github-runner
systemctl start github-runner

echo "=== Bootstrap complete ==="
