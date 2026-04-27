#!/usr/bin/env bash
# =============================================================================
# provision.sh – Pre-bake a GitHub Actions self-hosted runner AMI
#
# Installs everything needed to run:
#   • py-libp2p workflows  (tox matrix: core, demos, interop, lint, utils, wheel, docs)
#   • test-plans workflows (transport-interop, gossipsub-interop, hole-punch, perf)
#
# Expected environment variables (set by Packer):
#   GO_VERSION      – e.g. "1.22.4"
#   NODE_VERSION    – major version, e.g. "22"
#   RUST_TOOLCHAIN  – e.g. "stable"
#
# Run as root.
# =============================================================================
set -euo pipefail

GO_VERSION="${GO_VERSION:-1.22.4}"
NODE_VERSION="${NODE_VERSION:-22}"
RUST_TOOLCHAIN="${RUST_TOOLCHAIN:-stable}"

RUNNER_USER="actions-runner"
HOME_DIR="/home/${RUNNER_USER}"

log() { echo ""; echo ">>> $*"; echo ""; }

# ─────────────────────────────────────────────────────────────
# 1. System packages
# ─────────────────────────────────────────────────────────────
log "1/14  System packages"

export DEBIAN_FRONTEND=noninteractive
apt-get update -y --allow-releaseinfo-change

# Core utilities
apt-get install -y \
  curl wget git unzip zip tar xz-utils \
  ca-certificates gnupg lsb-release \
  software-properties-common apt-transport-https \
  jq

# Build essentials + Shadow simulator deps (gossipsub-interop) + Python + misc
apt-get install -y \
  build-essential make cmake pkg-config \
  findutils libclang-dev libc-dbg \
  libglib2.0-0 libglib2.0-dev netbase \
  python3-networkx \
  python3 python3-pip python3-setuptools python3-venv \
  libgmp-dev \
  acl sudo

# ─────────────────────────────────────────────────────────────
# 2. AWS CLI v2
# ─────────────────────────────────────────────────────────────
log "2/14  AWS CLI v2"

curl -fsSL "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o /tmp/awscliv2.zip
unzip -q /tmp/awscliv2.zip -d /tmp/awscli
/tmp/awscli/aws/install
rm -rf /tmp/awscliv2.zip /tmp/awscli

aws --version

# ─────────────────────────────────────────────────────────────
# 3. Docker CE + Buildx plugin + Compose plugin
# ─────────────────────────────────────────────────────────────
log "3/14  Docker CE + Buildx + Compose"

install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
  | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
chmod a+r /etc/apt/keyrings/docker.gpg

echo \
  "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
  https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" \
  | tee /etc/apt/sources.list.d/docker.list > /dev/null

apt-get update -y
apt-get install -y \
  docker-ce docker-ce-cli containerd.io \
  docker-buildx-plugin docker-compose-plugin

# Verify
docker --version
docker buildx version
docker compose version

# Enable & start Docker daemon so it's ready when the AMI boots
systemctl enable docker
systemctl start docker

# ─────────────────────────────────────────────────────────────
# 4. BuildKit config (enables docker.io mirror to avoid rate limits)
# ─────────────────────────────────────────────────────────────
log "4/14  BuildKit config"

mkdir -p /etc/buildkit
cat > /etc/buildkit/buildkitd.toml << 'EOF'
# Packer-provisioned BuildKit config.
# Workflows check for this file to decide whether to pass --config to buildx.
[registry."docker.io"]
  mirrors = ["mirror.gcr.io"]
EOF

# ─────────────────────────────────────────────────────────────
# 5. Go
# ─────────────────────────────────────────────────────────────
log "5/14  Go ${GO_VERSION}"

curl -fsSL "https://go.dev/dl/go${GO_VERSION}.linux-amd64.tar.gz" \
  | tar -C /usr/local -xz
ln -sf /usr/local/go/bin/go   /usr/local/bin/go
ln -sf /usr/local/go/bin/gofmt /usr/local/bin/gofmt

go version

# ─────────────────────────────────────────────────────────────
# 6. Node.js (via NodeSource)
# ─────────────────────────────────────────────────────────────
log "6/14  Node.js ${NODE_VERSION}"

curl -fsSL "https://deb.nodesource.com/setup_${NODE_VERSION}.x" | bash -
apt-get install -y nodejs

node --version
npm --version

# ─────────────────────────────────────────────────────────────
# 7. uv (fast Python package/project manager)
# ─────────────────────────────────────────────────────────────
log "7/14  uv (Astral)"

# Install system-wide so all users can use it
curl -LsSf https://astral.sh/uv/install.sh | env UV_INSTALL_DIR="/usr/local/bin" sh

uv --version

# ─────────────────────────────────────────────────────────────
# 8. Python versions via uv (3.10 – 3.13)
# ─────────────────────────────────────────────────────────────
log "8/14  Python 3.10 – 3.13 via uv"

for pyver in 3.10 3.11 3.12 3.13; do
  uv python install "${pyver}"
done

# Also install tox globally (used by py-libp2p workflows)
uv tool install tox

# ─────────────────────────────────────────────────────────────
# 9. Rust (rustup, stable toolchain)
# ─────────────────────────────────────────────────────────────
log "9/14  Rust (${RUST_TOOLCHAIN})"

# Install rustup for the runner user (and root) in a shared location
export RUSTUP_HOME=/usr/local/rustup
export CARGO_HOME=/usr/local/cargo
curl -fsSL https://sh.rustup.rs \
  | sh -s -- -y --no-modify-path --default-toolchain "${RUST_TOOLCHAIN}" \
      --profile minimal

# Make cargo/rustc available system-wide
ln -sf /usr/local/cargo/bin/rustc  /usr/local/bin/rustc
ln -sf /usr/local/cargo/bin/cargo  /usr/local/bin/cargo
ln -sf /usr/local/cargo/bin/rustup /usr/local/bin/rustup

# Persist RUSTUP_HOME + CARGO_HOME for all users (needed so rustup can find the toolchain)
cat > /etc/profile.d/rust.sh << 'EOF'
export RUSTUP_HOME=/usr/local/rustup
export CARGO_HOME=/usr/local/cargo
export PATH="/usr/local/cargo/bin:$PATH"
EOF
chmod 644 /etc/profile.d/rust.sh

# Set for the current shell too (so the smoke-test below works)
export RUSTUP_HOME=/usr/local/rustup
export CARGO_HOME=/usr/local/cargo

rustc --version
cargo --version

# ─────────────────────────────────────────────────────────────
# 10. Nim (via choosenim) – needed for py-libp2p interop tests
# ─────────────────────────────────────────────────────────────
log "10/14  Nim (choosenim, stable)"

# choosenim installs to $HOME/.choosenim and $HOME/.nimble when run as root
curl -fsSL https://nim-lang.org/choosenim/init.sh | sh -s -- -y

# Move to /usr/local for system-wide access by the actions-runner user
mv /root/.choosenim /usr/local/choosenim
mv /root/.nimble    /usr/local/nimble

# Symlink binaries into /usr/local/bin
NIM_STABLE_BIN=$(find /usr/local/choosenim/toolchains -name nim -type f | sort | tail -1)
NIM_STABLE_DIR=$(dirname "${NIM_STABLE_BIN}")

ln -sf "${NIM_STABLE_DIR}/nim"       /usr/local/bin/nim
ln -sf "${NIM_STABLE_DIR}/nimble"    /usr/local/bin/nimble
ln -sf /usr/local/nimble/bin/choosenim /usr/local/bin/choosenim

# Patch choosenim's stored path so it still works from /usr/local
sed -i 's|/root/.nimble|/usr/local/nimble|g; s|/root/.choosenim|/usr/local/choosenim|g' \
  /usr/local/nimble/bin/choosenim 2>/dev/null || true

chmod -R a+rX /usr/local/choosenim /usr/local/nimble

nim --version | head -1

# ─────────────────────────────────────────────────────────────
# 11. Terraform (latest 1.x)
# ─────────────────────────────────────────────────────────────
log "11/14  Terraform"

TERRAFORM_VERSION=$(curl -fsSL https://checkpoint-api.hashicorp.com/v1/check/terraform \
  | jq -r '.current_version')

curl -fsSL \
  "https://releases.hashicorp.com/terraform/${TERRAFORM_VERSION}/terraform_${TERRAFORM_VERSION}_linux_amd64.zip" \
  -o /tmp/terraform.zip
unzip -q /tmp/terraform.zip -d /usr/local/bin
rm /tmp/terraform.zip
chmod +x /usr/local/bin/terraform

terraform --version | head -1

# ─────────────────────────────────────────────────────────────
# 12. Shadow simulator build dependencies (gossipsub-interop)
#     The actual Shadow build happens at CI time from source,
#     but all compile-time deps are pre-installed here.
# ─────────────────────────────────────────────────────────────
log "12/14  Shadow simulator compile-time deps"

# All system packages already installed in step 1.
# Verify key ones:
cmake --version | head -1
pkg-config --version

# ─────────────────────────────────────────────────────────────
# 13. Runner user + permissions  (created BEFORE runner download
#     so the runner dir is owned correctly from the start)
# ─────────────────────────────────────────────────────────────
log "13/15  Runner user '${RUNNER_USER}'"

useradd -m -s /bin/bash "${RUNNER_USER}" || true

# Passwordless sudo (workflow steps like apt-get need this)
echo "${RUNNER_USER} ALL=(ALL) NOPASSWD:ALL" > "/etc/sudoers.d/${RUNNER_USER}"
chmod 440 "/etc/sudoers.d/${RUNNER_USER}"

# Docker group membership
usermod -aG docker "${RUNNER_USER}"

# Give runner user access to shared tool dirs
for dir in /usr/local/rustup /usr/local/cargo /usr/local/choosenim /usr/local/nimble; do
  if [[ -d "$dir" ]]; then
    chmod -R a+rX "$dir"
  fi
done

# ─────────────────────────────────────────────────────────────
# 14. GitHub Actions Runner binary + OS deps
# ─────────────────────────────────────────────────────────────
log "14/15  GitHub Actions Runner binary"

RUNNER_VERSION=$(curl -fsSL https://api.github.com/repos/actions/runner/releases/latest \
  | jq -r '.tag_name' | sed 's/v//')
echo "Runner version: ${RUNNER_VERSION}"

RUNNER_DIR=/actions-runner
mkdir -p "${RUNNER_DIR}"

curl -fsSL \
  "https://github.com/actions/runner/releases/download/v${RUNNER_VERSION}/actions-runner-linux-x64-${RUNNER_VERSION}.tar.gz" \
  -o /tmp/runner.tar.gz
tar -xzf /tmp/runner.tar.gz -C "${RUNNER_DIR}"
rm /tmp/runner.tar.gz

# Install runner OS dependencies (liblttng-ust, libssl, etc.)
"${RUNNER_DIR}/bin/installdependencies.sh"

# Ownership of runner directory
chown -R "${RUNNER_USER}:${RUNNER_USER}" "${RUNNER_DIR}"

# ─────────────────────────────────────────────────────────────
# 15. Pre-bake runner wrapper, entrypoint + systemd unit
#
#     These scripts are STATIC — they never change between boots.
#     Only config.sh (registration) and the systemd env block
#     (ACCESS_TOKEN, RUNNER_NAME, LABELS…) are written at boot
#     time by user_data.sh.tpl, saving ~60 s per cold-start.
# ─────────────────────────────────────────────────────────────
log "15/15  Pre-baking runner scripts + systemd unit"

# ── entrypoint: runs config.sh then the runner ──────────────
cat > /usr/local/bin/github-runner-entrypoint.sh << 'EOF'
#!/bin/bash
# Registers the runner with GitHub (ephemeral, one-shot) then starts it.
# Called by github-runner-wrapper.sh.
# All required env vars are injected by the systemd unit at boot time.
set -euo pipefail

cd /actions-runner

# Obtain a fresh registration token from GitHub
if [[ "${RUNNER_SCOPE:-}" == "org" && -n "${ORG_NAME:-}" ]]; then
  REG_TOKEN=$(curl -fsSL \
    -X POST \
    -H "Authorization: Bearer ${ACCESS_TOKEN}" \
    -H "Accept: application/vnd.github+json" \
    "https://api.github.com/orgs/${ORG_NAME}/actions/runners/registration-token" \
    | jq -r '.token')
  TARGET_URL="https://github.com/${ORG_NAME}"
else
  REPO_PATH=$(echo "${REPO_URL}" | sed 's|https://github.com/||')
  REG_TOKEN=$(curl -fsSL \
    -X POST \
    -H "Authorization: Bearer ${ACCESS_TOKEN}" \
    -H "Accept: application/vnd.github+json" \
    "https://api.github.com/repos/${REPO_PATH}/actions/runners/registration-token" \
    | jq -r '.token')
  TARGET_URL="${REPO_URL}"
fi

if [[ -z "$REG_TOKEN" || "$REG_TOKEN" == "null" ]]; then
  echo "[entrypoint] ERROR: Failed to obtain registration token"
  exit 1
fi

echo "[entrypoint] Configuring runner '${RUNNER_NAME}' → ${TARGET_URL}"
./config.sh \
  --url      "${TARGET_URL}" \
  --token    "${REG_TOKEN}" \
  --name     "${RUNNER_NAME}" \
  --labels   "${LABELS}" \
  --runnergroup "Default" \
  --work     "_work" \
  --ephemeral \
  --unattended

echo "[entrypoint] Starting runner..."
./run.sh
EOF
chmod +x /usr/local/bin/github-runner-entrypoint.sh

# ── wrapper: pre-flight job-status check + self-terminate ───
cat > /usr/local/bin/github-runner-wrapper.sh << 'EOF'
#!/bin/bash
# 1. Check if the queued GitHub job is still active (avoids running a
#    cancelled job on a slow-starting instance).
# 2. Run the entrypoint (config + run).
# 3. Terminate this EC2 instance regardless of exit code.
set -euo pipefail

INSTANCE_ID=$(curl -fsSL http://169.254.169.254/latest/meta-data/instance-id)
REGION=$(curl -fsSL http://169.254.169.254/latest/meta-data/placement/region)

echo "[wrapper] Starting runner on instance ${INSTANCE_ID}"

# Fetch job_id from EC2 instance tag (set by the Lambda at dispatch time)
JOB_ID=$(aws ec2 describe-tags \
  --region "${REGION}" \
  --filters "Name=resource-id,Values=${INSTANCE_ID}" "Name=key,Values=GitHubJobId" \
  --query 'Tags[0].Value' \
  --output text 2>/dev/null || echo "")

if [[ -z "${JOB_ID}" || "${JOB_ID}" == "None" ]]; then
  echo "[wrapper] WARNING: No GitHubJobId tag found. Proceeding anyway."
else
  echo "[wrapper] Job ID: ${JOB_ID}. Checking status on GitHub..."

  if [[ "${RUNNER_SCOPE:-}" == "org" && -n "${ORG_NAME:-}" ]]; then
    JOB_URL="https://api.github.com/orgs/${ORG_NAME}/actions/jobs/${JOB_ID}"
  else
    REPO_PATH=$(echo "${REPO_URL}" | sed 's|https://github.com/||')
    JOB_URL="https://api.github.com/repos/${REPO_PATH}/actions/jobs/${JOB_ID}"
  fi

  JOB_STATUS=$(curl -fsSL \
    -H "Authorization: Bearer ${ACCESS_TOKEN}" \
    -H "Accept: application/vnd.github+json" \
    "${JOB_URL}" 2>/dev/null | jq -r '.status // "unknown"' || echo "unknown")

  echo "[wrapper] GitHub job status: ${JOB_STATUS}"

  if [[ "${JOB_STATUS}" == "completed" || "${JOB_STATUS}" == "cancelled" ]]; then
    echo "[wrapper] Job already ${JOB_STATUS}. Skipping runner. Terminating..."
    aws ec2 terminate-instances --region "${REGION}" --instance-ids "${INSTANCE_ID}"
    exit 0
  fi
fi

# Run the entrypoint (config.sh + run.sh)
/usr/local/bin/github-runner-entrypoint.sh || true

echo "[wrapper] Runner finished. Terminating instance ${INSTANCE_ID}..."
aws ec2 terminate-instances --region "${REGION}" --instance-ids "${INSTANCE_ID}"
EOF
chmod +x /usr/local/bin/github-runner-wrapper.sh

# ── systemd unit (env block written at boot by user_data) ───
cat > /etc/systemd/system/github-runner.service << 'EOF'
[Unit]
Description=GitHub Actions Runner (ephemeral)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=actions-runner
WorkingDirectory=/actions-runner
# Dynamic env vars (ACCESS_TOKEN, RUNNER_NAME, LABELS, …) are written
# to /etc/github-runner.env by user_data.sh.tpl at first boot.
EnvironmentFile=/etc/github-runner.env
ExecStart=/usr/local/bin/github-runner-wrapper.sh
Restart=no
StandardOutput=journal
StandardError=journal
SyslogIdentifier=github-runner

[Install]
WantedBy=multi-user.target
EOF

# Create a placeholder env file so systemd doesn't complain before first boot
cat > /etc/github-runner.env << 'EOF'
# Populated at instance boot time by user_data.sh.tpl
ACCESS_TOKEN=
RUNNER_SCOPE=
REPO_URL=
ORG_NAME=
LABELS=
RUNNER_NAME=
EOF
chmod 600 /etc/github-runner.env

systemctl daemon-reload
systemctl enable github-runner
echo "Runner service pre-enabled (will start after user_data writes env file)"

# ─────────────────────────────────────────────────────────────
# Final clean-up  (runs before EBS snapshot — keeps AMI lean)
# ─────────────────────────────────────────────────────────────
log "Cleaning up – making AMI lean before snapshot"

# ── apt ──────────────────────────────────────────────────────
apt-get autoremove -y
apt-get clean
rm -rf /var/lib/apt/lists/*

# ── Go build/module cache (populated during go install steps) ─
rm -rf /root/go /root/.cache/go-build /root/.cache/go

# ── Rust registry + git cache (can be 500 MB+) ───────────────
rm -rf /usr/local/cargo/registry \
       /usr/local/cargo/git \
       /usr/local/rustup/tmp \
       /usr/local/rustup/downloads \
       /root/.cargo/registry \
       /root/.cargo/git

# ── Node / npm cache ─────────────────────────────────────────
npm cache clean --force 2>/dev/null || true
rm -rf /root/.npm /tmp/npm-*

# ── uv cache ─────────────────────────────────────────────────
uv cache clean 2>/dev/null || true
rm -rf /root/.cache/uv

# ── pip cache ────────────────────────────────────────────────
pip3 cache purge 2>/dev/null || true
rm -rf /root/.cache/pip

# ── Nim / choosenim download cache ───────────────────────────
rm -rf /usr/local/choosenim/downloads \
       /usr/local/choosenim/tmp \
       /root/.cache/nim

# ── Terraform plugin cache ───────────────────────────────────
rm -rf /root/.terraform.d/plugin-cache 2>/dev/null || true

# ── General tmp + log cleanup ────────────────────────────────
rm -rf /tmp/* /var/tmp/*
find /var/log -type f | xargs truncate -s 0 2>/dev/null || true
rm -rf /var/log/*.gz /var/log/*.old /var/log/*.1

# ── SSH host keys (regenerated on first boot) ────────────────
rm -f /etc/ssh/ssh_host_*

# ── Shell history ────────────────────────────────────────────
rm -f /root/.bash_history /home/ubuntu/.bash_history
history -c 2>/dev/null || true

log "=== Provisioning complete ==="
log "Installed tools summary:"
echo "  git:       $(git --version)"
echo "  docker:    $(docker --version)"
echo "  buildx:    $(docker buildx version)"
echo "  compose:   $(docker compose version)"
echo "  go:        $(go version)"
echo "  node:      $(node --version)"
echo "  npm:       $(npm --version)"
echo "  uv:        $(uv --version)"
echo "  rustc:     $(rustc --version)"
echo "  nim:       $(nim --version | head -1)"
echo "  terraform: $(terraform --version | head -1)"
echo "  aws:       $(aws --version)"
echo "  cmake:     $(cmake --version | head -1)"
echo "  make:      $(make --version | head -1)"
echo "  python3:   $(python3 --version)"
