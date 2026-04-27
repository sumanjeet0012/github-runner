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

echo "=== Installing Docker ==="
# Install Docker using official Docker repository
apt-get install -y ca-certificates gnupg lsb-release
mkdir -p /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" | tee /etc/apt/sources.list.d/docker.list > /dev/null
apt-get update
apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

# Start Docker daemon
systemctl enable docker
systemctl start docker

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
  --output text 2>/dev/null || true)
# Fall back to Name tag, then to instance-id based name
if [[ -z "$RUNNER_NAME" || "$RUNNER_NAME" == "None" || "$RUNNER_NAME" == "__FROM_TAG__" ]]; then
  RUNNER_NAME=$(aws ec2 describe-tags \
    --region "$REGION" \
    --filters "Name=resource-id,Values=$INSTANCE_ID" "Name=key,Values=Name" \
    --query 'Tags[0].Value' \
    --output text 2>/dev/null || true)
fi
if [[ -z "$RUNNER_NAME" || "$RUNNER_NAME" == "None" ]]; then
  RUNNER_NAME="ec2-runner-$INSTANCE_ID"
fi
echo "Runner name: $RUNNER_NAME"

# ── All of the following were pre-installed in the AMI by Packer: ──────────
#   • actions-runner user + sudoers + docker group
#   • /actions-runner/{run.sh,config.sh,...} + OS deps
#   • /usr/local/bin/github-runner-entrypoint.sh
#   • /usr/local/bin/github-runner-wrapper.sh
#   • /etc/systemd/system/github-runner.service  (pre-enabled)
# ────────────────────────────────────────────────────────────────────────────
# Boot-time only: write the dynamic env file and start the service.

echo "=== Writing runner environment file ==="
cat > /etc/github-runner.env << ENV_EOF
ACCESS_TOKEN=$ACCESS_TOKEN
RUNNER_SCOPE=${runner_scope}
REPO_URL=${repo_url}
ORG_NAME=${org_name}
LABELS=${runner_labels}
RUNNER_NAME=$RUNNER_NAME
ENV_EOF
chmod 600 /etc/github-runner.env
chown root:root /etc/github-runner.env

echo "=== Starting github-runner service ==="
systemctl daemon-reload
systemctl start github-runner

echo "=== Bootstrap complete ==="
