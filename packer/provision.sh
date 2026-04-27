#!/usr/bin/env bash
# =============================================================================
# provision.sh – Pre-bake a GitHub Actions self-hosted runner AMI
#
# Installs everything needed to run:
#   • py-libp2p workflows  (tox matrix: core, demos, interop, lint, utils, wheel, docs)
#   • go-libp2p workflows  (go test, interop)
#   • js-libp2p workflows  (node test, browser tests)
#   • rust-libp2p workflows (cargo test, wasm, interop)
#   • jvm-libp2p workflows  (gradle build)
#   • cpp-libp2p workflows  (cmake build)
#   • test-plans workflows  (transport-interop, gossipsub-interop, hole-punch, perf)
#   • unified-testing workflows (transport, hole-punch, perf – self-hosted)
#
# Expected environment variables (set by Packer):
#   GO_VERSION      – e.g. "1.25.7"
#   NODE_VERSION    – major version, e.g. "22"
#   RUST_TOOLCHAIN  – e.g. "stable"
#
# Run as root.
# =============================================================================
set -euo pipefail

GO_VERSION="${GO_VERSION:-1.25.7}"
NODE_VERSION="${NODE_VERSION:-22}"
RUST_TOOLCHAIN="${RUST_TOOLCHAIN:-stable}"
# Rust MSRV required by rust-libp2p (Cargo.toml: rust-version = "1.88.0")
RUST_MSRV="${RUST_MSRV:-1.88.0}"
# Java version required by jvm-libp2p
JAVA_VERSION="${JAVA_VERSION:-11}"

RUNNER_USER="actions-runner"
HOME_DIR="/home/${RUNNER_USER}"

log() { echo ""; echo ">>> $*"; echo ""; }

# ─────────────────────────────────────────────────────────────
# 1. System packages
# ─────────────────────────────────────────────────────────────
log "1/16  System packages"

export DEBIAN_FRONTEND=noninteractive
# Never prompt for config file conflicts — always keep the new (maintainer) version
export DPKG_OPTIONS="--force-confnew --force-confdef"

apt-get update -y --allow-releaseinfo-change

# Upgrade all previously installed packages to latest versions (non-interactive)
apt-get upgrade -y -o Dpkg::Options::="--force-confnew" -o Dpkg::Options::="--force-confdef"

# Core utilities
apt-get install -y -o Dpkg::Options::="--force-confnew" -o Dpkg::Options::="--force-confdef" \
  curl wget git unzip zip tar xz-utils \
  ca-certificates gnupg lsb-release \
  software-properties-common apt-transport-https \
  jq

# Build essentials + Shadow simulator deps (gossipsub-interop) + Python + misc
apt-get install -y -o Dpkg::Options::="--force-confnew" -o Dpkg::Options::="--force-confdef" \
  build-essential make cmake pkg-config \
  findutils libclang-dev libc-dbg \
  libglib2.0-0 libglib2.0-dev netbase \
  python3-networkx \
  python3 python3-pip python3-setuptools python3-venv \
  libgmp-dev \
  acl sudo

# cpp-libp2p: needs ninja-build
# rust-libp2p wasm tests: needs chromium + chromedriver
# py-libp2p Makefile: needs protoc (protobuf-compiler) for .proto → _pb2.py generation
# jvm-libp2p: needs JDK 11 (temurin installed below, but openjdk is the apt fallback)
# general TLS / crypto builds: libssl-dev
# wasm-pack build deps: libssl-dev, pkg-config (already above)
apt-get install -y -o Dpkg::Options::="--force-confnew" -o Dpkg::Options::="--force-confdef" \
  ninja-build \
  protobuf-compiler \
  libssl-dev \
  chromium-browser \
  chromium-chromedriver \
  openjdk-11-jdk

# ─────────────────────────────────────────────────────────────
# 2. AWS CLI v2
# ─────────────────────────────────────────────────────────────
log "2/16  AWS CLI v2"

curl -fsSL "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o /tmp/awscliv2.zip
unzip -q /tmp/awscliv2.zip -d /tmp/awscli

# Install with --update flag to replace existing installation if present
/tmp/awscli/aws/install --update || /tmp/awscli/aws/install

rm -rf /tmp/awscliv2.zip /tmp/awscli

aws --version

# ─────────────────────────────────────────────────────────────
# 3. Docker CE + Buildx plugin + Compose plugin
# ─────────────────────────────────────────────────────────────
log "3/16  Docker CE + Buildx + Compose"

install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
  | gpg --batch --yes --dearmor -o /etc/apt/keyrings/docker.gpg
chmod a+r /etc/apt/keyrings/docker.gpg

echo \
  "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
  https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" \
  | tee /etc/apt/sources.list.d/docker.list > /dev/null

apt-get update -y
apt-get install -y -o Dpkg::Options::="--force-confnew" -o Dpkg::Options::="--force-confdef" \
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
log "4/16  BuildKit config"

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
log "5/16  Go ${GO_VERSION}"

# Remove any existing Go installation to avoid conflicts
rm -rf /usr/local/go
curl -fsSL "https://go.dev/dl/go${GO_VERSION}.linux-amd64.tar.gz" \
  | tar -C /usr/local -xz
ln -sf /usr/local/go/bin/go   /usr/local/bin/go
ln -sf /usr/local/go/bin/gofmt /usr/local/bin/gofmt

go version

# ─────────────────────────────────────────────────────────────
# 6. Node.js (via NodeSource)
# ─────────────────────────────────────────────────────────────
log "6/16  Node.js ${NODE_VERSION}"

curl -fsSL "https://deb.nodesource.com/setup_${NODE_VERSION}.x" | bash -s -- -y
apt-get install -y -o Dpkg::Options::="--force-confnew" nodejs

node --version
npm --version

# ─────────────────────────────────────────────────────────────
# 7. uv (fast Python package/project manager)
# ─────────────────────────────────────────────────────────────
log "7/16  uv (Astral)"

# Install system-wide so all users can use it (non-interactive via env vars)
curl -LsSf https://astral.sh/uv/install.sh \
  | env UV_INSTALL_DIR="/usr/local/bin" \
        UV_UNMANAGED_INSTALL="1" \
        INSTALLER_NO_MODIFY_PATH="1" \
        sh

uv --version

# ─────────────────────────────────────────────────────────────
# 8. Python versions via uv (3.10 – 3.13)
# ─────────────────────────────────────────────────────────────
log "8/16  Python 3.10 – 3.13 via uv"

for pyver in 3.10 3.11 3.12 3.13; do
  uv python install "${pyver}"
done

# Install tox system-wide so it's on PATH for all users (including actions-runner).
# UV_TOOL_BIN_DIR forces the binary into /usr/local/bin instead of ~/.local/bin.
UV_TOOL_BIN_DIR=/usr/local/bin uv tool install tox --reinstall

# ─────────────────────────────────────────────────────────────
# 9. Rust (rustup, stable toolchain)
# ─────────────────────────────────────────────────────────────
log "9/16  Rust (${RUST_TOOLCHAIN} + MSRV ${RUST_MSRV})"

# Install rustup for the runner user (and root) in a shared location
export RUSTUP_HOME=/usr/local/rustup
export CARGO_HOME=/usr/local/cargo
# RUSTUP_INIT_SKIP_PATH_CHECK=yes suppresses the PATH warning message
curl -fsSL https://sh.rustup.rs \
  | RUSTUP_INIT_SKIP_PATH_CHECK=yes sh -s -- -y --no-modify-path \
      --default-toolchain "${RUST_TOOLCHAIN}" \
      --profile minimal

# Source cargo env immediately so PATH is updated for the rest of this script
# shellcheck source=/dev/null
. "/usr/local/cargo/env"

# Make cargo/rustc available system-wide
ln -sf /usr/local/cargo/bin/rustc  /usr/local/bin/rustc
ln -sf /usr/local/cargo/bin/cargo  /usr/local/bin/cargo
ln -sf /usr/local/cargo/bin/rustup /usr/local/bin/rustup

# Persist RUSTUP_HOME + CARGO_HOME for all users (needed so rustup can find the toolchain)
# Both /etc/profile.d (login shells) and /etc/environment (all shells)
cat > /etc/profile.d/rust.sh << 'EOF'
export RUSTUP_HOME=/usr/local/rustup
export CARGO_HOME=/usr/local/cargo
export PATH="/usr/local/cargo/bin:$PATH"
EOF
chmod 644 /etc/profile.d/rust.sh

# Also add to /etc/environment for non-login shells (GitHub Actions runner)
grep -q "RUSTUP_HOME" /etc/environment || echo "RUSTUP_HOME=/usr/local/rustup" >> /etc/environment
grep -q "CARGO_HOME" /etc/environment || echo "CARGO_HOME=/usr/local/cargo" >> /etc/environment
if ! grep -q "/usr/local/cargo/bin" /etc/environment; then
  sed -i 's|PATH="|PATH="/usr/local/cargo/bin:|' /etc/environment
fi

# Set for the current shell too (so the smoke-test below works)
export RUSTUP_HOME=/usr/local/rustup
export CARGO_HOME=/usr/local/cargo

rustc --version
cargo --version

# Install MSRV toolchain (rust-libp2p requires 1.88.0)
rustup toolchain install "${RUST_MSRV}" --profile minimal
rustup toolchain install beta --profile minimal
rustup toolchain install nightly --profile minimal

# Add wasm32 targets (rust-libp2p wasm tests + cross-compilation)
rustup target add wasm32-unknown-unknown
rustup target add wasm32-wasip1

# Install wasm-pack (rust-libp2p wasm_tests job uses wasm-pack@0.12.0)
cargo install wasm-pack --version 0.12.0 --locked

# Install cargo tools used by rust-libp2p CI
# tomlq – used to read version fields from Cargo.toml in CI scripts
cargo install tomlq --locked
# cargo-deny – dependency auditing / license checks
cargo install cargo-deny --locked
# cargo-audit – security audit of Cargo.lock
cargo install cargo-audit --locked

# ─────────────────────────────────────────────────────────────
# 10. Nim – needed for py-libp2p interop tests
#     Install directly from the official nim-lang.org binary tarball.
#     No choosenim required — just download, extract, symlink.
# ─────────────────────────────────────────────────────────────
log "10/16  Nim (binary tarball, stable)"

NIM_VERSION=$(curl -fsSL https://nim-lang.org/channels/stable \
  | tr -d '[:space:]')
echo "[Nim] stable version: ${NIM_VERSION}"

curl -fsSL \
  "https://nim-lang.org/download/nim-${NIM_VERSION}-linux_x64.tar.xz" \
  -o /tmp/nim.tar.xz

tar -xJf /tmp/nim.tar.xz -C /usr/local/
rm /tmp/nim.tar.xz

# Rename the extracted dir to a fixed path for easy symlinking
mv /usr/local/nim-${NIM_VERSION} /usr/local/nim

ln -sf /usr/local/nim/bin/nim     /usr/local/bin/nim
ln -sf /usr/local/nim/bin/nimble  /usr/local/bin/nimble
ln -sf /usr/local/nim/bin/nimgrep /usr/local/bin/nimgrep

nim --version | head -1

# ─────────────────────────────────────────────────────────────
# 11. Terraform (latest 1.x)
# ─────────────────────────────────────────────────────────────
log "11/16  Terraform"

TERRAFORM_VERSION=$(curl -fsSL https://checkpoint-api.hashicorp.com/v1/check/terraform \
  | jq -r '.current_version')

curl -fsSL \
  "https://releases.hashicorp.com/terraform/${TERRAFORM_VERSION}/terraform_${TERRAFORM_VERSION}_linux_amd64.zip" \
  -o /tmp/terraform.zip
# -o overwrites existing terraform binary without prompting
unzip -q -o /tmp/terraform.zip -d /usr/local/bin
rm /tmp/terraform.zip
chmod +x /usr/local/bin/terraform

terraform --version | head -1

# ─────────────────────────────────────────────────────────────
# 12. Shadow simulator build dependencies (gossipsub-interop)
#     The actual Shadow build happens at CI time from source,
#     but all compile-time deps are pre-installed here.
# ─────────────────────────────────────────────────────────────
log "12/16  Shadow simulator compile-time deps"

# All system packages already installed in step 1.
# Verify key ones:
cmake --version | head -1
pkg-config --version

# ─────────────────────────────────────────────────────────────
# 13. Java (Temurin JDK 11) – required by jvm-libp2p
#     jvm-libp2p CI: actions/setup-java distribution=temurin java-version=11
# ─────────────────────────────────────────────────────────────
log "13/16  Java (Temurin JDK ${JAVA_VERSION})"

# Install Eclipse Temurin JDK via Adoptium APT repo (same distro as setup-java@temurin)
install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://packages.adoptium.net/artifactory/api/gpg/key/public \
  | gpg --batch --yes --dearmor -o /etc/apt/keyrings/adoptium.gpg
chmod a+r /etc/apt/keyrings/adoptium.gpg

echo \
  "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/adoptium.gpg] \
  https://packages.adoptium.net/artifactory/deb $(lsb_release -cs) main" \
  | tee /etc/apt/sources.list.d/adoptium.list > /dev/null

apt-get update -y
apt-get install -y -o Dpkg::Options::="--force-confnew" -o Dpkg::Options::="--force-confdef" \
  temurin-${JAVA_VERSION}-jdk

java -version

# Set JAVA_HOME for all users
JAVA_HOME_PATH=$(dirname $(dirname $(readlink -f $(which java))))
cat > /etc/profile.d/java.sh << JAVAEOF
export JAVA_HOME=${JAVA_HOME_PATH}
export PATH="\$JAVA_HOME/bin:\$PATH"
JAVAEOF
chmod 644 /etc/profile.d/java.sh
grep -q "JAVA_HOME" /etc/environment || echo "JAVA_HOME=${JAVA_HOME_PATH}" >> /etc/environment

# ─────────────────────────────────────────────────────────────
# 14. Runner user + permissions  (created BEFORE runner download
#     so the runner dir is owned correctly from the start)
# ─────────────────────────────────────────────────────────────
log "14/16  Runner user '${RUNNER_USER}'"

useradd -m -s /bin/bash "${RUNNER_USER}" || true

# Passwordless sudo (workflow steps like apt-get need this)
echo "${RUNNER_USER} ALL=(ALL) NOPASSWD:ALL" > "/etc/sudoers.d/${RUNNER_USER}"
chmod 440 "/etc/sudoers.d/${RUNNER_USER}"

# Docker group membership
usermod -aG docker "${RUNNER_USER}"

# Give runner user access to shared tool dirs
for dir in /usr/local/rustup /usr/local/cargo /usr/local/nim; do
  if [[ -d "$dir" ]]; then
    chmod -R a+rX "$dir"
  fi
done

# ─────────────────────────────────────────────────────────────
# 15. GitHub Actions Runner binary + OS deps
# ─────────────────────────────────────────────────────────────
log "15/16  GitHub Actions Runner binary"

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

# Install runner OS dependencies (liblttng-ust, libssl, etc.) non-interactively
DEBIAN_FRONTEND=noninteractive "${RUNNER_DIR}/bin/installdependencies.sh"

# Ownership of runner directory
chown -R "${RUNNER_USER}:${RUNNER_USER}" "${RUNNER_DIR}"

# ─────────────────────────────────────────────────────────────
# 16. Pre-bake runner wrapper, entrypoint + systemd unit
#
#     These scripts are STATIC — they never change between boots.
#     Only config.sh (registration) and the systemd env block
#     (ACCESS_TOKEN, RUNNER_NAME, LABELS…) are written at boot
#     time by user_data.sh.tpl, saving ~60 s per cold-start.
# ─────────────────────────────────────────────────────────────
log "16/16  Pre-baking runner scripts + systemd unit"

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
# NOTE: keep installed cargo binaries (wasm-pack, tomlq, cargo-deny, cargo-audit)
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

# ── Nim build cache ─────────────────────────────────────────
rm -rf /root/.cache/nim /tmp/nim*

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
echo "  git:          $(git --version)"
echo "  docker:       $(docker --version)"
echo "  buildx:       $(docker buildx version)"
echo "  compose:      $(docker compose version)"
echo "  go:           $(go version)"
echo "  node:         $(node --version)"
echo "  npm:          $(npm --version)"
echo "  uv:           $(uv --version)"
echo "  rustc:        $(rustc --version)"
echo "  cargo:        $(cargo --version)"
echo "  wasm-pack:    $(wasm-pack --version 2>/dev/null || echo 'not in PATH yet')"
echo "  nim:          $(nim --version | head -1)"
echo "  terraform:    $(terraform --version | head -1)"
echo "  aws:          $(aws --version)"
echo "  cmake:        $(cmake --version | head -1)"
echo "  ninja:        $(ninja --version)"
echo "  make:         $(make --version | head -1)"
echo "  protoc:       $(protoc --version)"
echo "  python3:      $(python3 --version)"
echo "  java:         $(java -version 2>&1 | head -1)"
echo "  chromium:     $(chromium-browser --version 2>/dev/null || chromium --version 2>/dev/null || echo 'not found')"
echo "  chromedriver: $(chromedriver --version 2>/dev/null || echo 'not found')"
