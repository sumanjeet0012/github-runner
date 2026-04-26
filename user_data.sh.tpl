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

echo "=== Writing runner wrapper (run + self-terminate) ==="
cat > /usr/local/bin/github-runner-wrapper.sh << 'WRAPPER_EOF'
#!/bin/bash
# Run the GitHub Actions runner (ephemeral – exits after one job).
# Then terminate this EC2 instance regardless of exit code.
set -euo pipefail

INSTANCE_ID=$(curl -fsSL http://169.254.169.254/latest/meta-data/instance-id)
REGION=$(curl -fsSL http://169.254.169.254/latest/meta-data/placement/region)

echo "[wrapper] Starting runner on instance $INSTANCE_ID"

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
