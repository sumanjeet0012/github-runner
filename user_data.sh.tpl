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

echo "=== Creating systemd service ==="
cat > /etc/systemd/system/github-runner.service << SERVICE_EOF
[Unit]
Description=GitHub Actions Runner
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
Environment="RUNNER_NAME=${runner_name}"
ExecStart=/usr/local/bin/github-runner-entrypoint.sh
Restart=on-failure
RestartSec=10
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
