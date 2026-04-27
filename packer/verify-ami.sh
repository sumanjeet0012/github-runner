#!/usr/bin/env bash
# =============================================================================
# verify-ami.sh – Verify that all required tools are installed in the AMI
#
# Runs a series of checks for every dependency needed by the libp2p repos:
#   • py-libp2p   (tox matrix: core, demos, interop, lint, utils, wheel, docs)
#   • go-libp2p   (go test, interop)
#   • js-libp2p   (node tests, browser tests)
#   • rust-libp2p (cargo test, wasm, MSRV, interop)
#   • jvm-libp2p  (gradle build, JDK 11)
#   • cpp-libp2p  (cmake + ninja build)
#   • test-plans  (transport-interop, gossipsub-interop, hole-punch, perf)
#   • unified-testing (self-hosted runner workflows)
#
# Usage:
#   sudo ./verify-ami.sh          # full check
#   ./verify-ami.sh --no-py-venv  # skip the live py-libp2p venv test
#
# Exit code: 0 = all checks passed, 1 = one or more checks failed
# =============================================================================
set -uo pipefail

# ── colour helpers ──────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'

PASS=0; FAIL=0; WARN=0

ok()   { echo -e "  ${GREEN}✔${RESET}  $*"; ((PASS++)); }
fail() { echo -e "  ${RED}✘${RESET}  $*"; ((FAIL++)); }
warn() { echo -e "  ${YELLOW}⚠${RESET}  $*"; ((WARN++)); }
section() { echo -e "\n${BOLD}${CYAN}▶ $*${RESET}"; }

SKIP_PY_VENV=false
for arg in "$@"; do
  [[ "$arg" == "--no-py-venv" ]] && SKIP_PY_VENV=true
done

# ─────────────────────────────────────────────────────────────
# Helper: check a binary exists and optionally matches a version
# ─────────────────────────────────────────────────────────────
check_bin() {
  local name="$1"
  local bin="${2:-$1}"
  local ver_flag="${3:---version}"
  if command -v "$bin" &>/dev/null; then
    local ver
    ver=$("$bin" $ver_flag 2>&1 | head -1 || true)
    ok "$name: $ver"
  else
    fail "$name: NOT FOUND (command: $bin)"
  fi
}

check_bin_version_contains() {
  # Passes if <binary> <flag> output contains <expected_substr>
  local name="$1" bin="$2" flag="$3" expected="$4"
  if command -v "$bin" &>/dev/null; then
    local ver
    ver=$("$bin" $flag 2>&1 | head -1 || true)
    if echo "$ver" | grep -qF "$expected"; then
      ok "$name: $ver"
    else
      warn "$name: found ($ver) but expected to contain '$expected'"
    fi
  else
    fail "$name: NOT FOUND"
  fi
}

# ─────────────────────────────────────────────────────────────
# 1. Core system utilities
# ─────────────────────────────────────────────────────────────
section "1. Core system utilities"
for b in curl wget git unzip zip tar xz jq make cmake pkg-config; do
  check_bin "$b"
done
check_bin "ninja"  "ninja"  "--version"
check_bin "protoc" "protoc" "--version"

# ─────────────────────────────────────────────────────────────
# 2. AWS CLI
# ─────────────────────────────────────────────────────────────
section "2. AWS CLI v2"
check_bin "aws" "aws" "--version"

# ─────────────────────────────────────────────────────────────
# 3. Docker
# ─────────────────────────────────────────────────────────────
section "3. Docker"
check_bin "docker"         "docker"         "--version"
check_bin "docker buildx"  "docker"         "buildx version"
check_bin "docker compose" "docker"         "compose version"

# Check BuildKit config (used by transport-interop action to detect self-hosted runner)
if [[ -f /etc/buildkit/buildkitd.toml ]]; then
  ok "/etc/buildkit/buildkitd.toml exists (self-hosted runner detection works)"
else
  fail "/etc/buildkit/buildkitd.toml MISSING — transport-interop action won't detect self-hosted runner"
fi

# ─────────────────────────────────────────────────────────────
# 4. Go  (go-libp2p uses go 1.25.x / 1.26.x)
# ─────────────────────────────────────────────────────────────
section "4. Go"
check_bin "go"   "go"    "version"
check_bin "gofmt" "gofmt" "-l /dev/null 2>&1; echo"

# ─────────────────────────────────────────────────────────────
# 5. Node.js + npm  (js-libp2p, transport-interop)
# ─────────────────────────────────────────────────────────────
section "5. Node.js + npm"
check_bin "node" "node" "--version"
check_bin "npm"  "npm"  "--version"

# ─────────────────────────────────────────────────────────────
# 6. uv + Python versions  (py-libp2p tox matrix)
# ─────────────────────────────────────────────────────────────
section "6. uv + Python (3.10–3.13)"
check_bin "uv" "uv" "--version"
# tox may be installed as a uv tool (binary in /usr/local/bin) or invocable via uvx.
# Accept either form.
if command -v tox &>/dev/null; then
  ok "tox: $(tox --version 2>&1 | head -1)"
elif uv tool list 2>/dev/null | grep -q '^tox'; then
  ok "tox (uv tool, not on PATH directly): $(uvx tox --version 2>&1 | head -1)"
  warn "tox binary not in PATH — ensure UV_TOOL_BIN_DIR=/usr/local/bin was set at install time"
else
  fail "tox: NOT FOUND (not in PATH and not in uv tool list)"
fi

for pyver in 3.10 3.11 3.12 3.13; do
  if uv python find "$pyver" &>/dev/null; then
    ok "Python $pyver (via uv): $(uv run --python $pyver python --version 2>&1 || echo 'found')"
  else
    fail "Python $pyver: NOT available via uv"
  fi
done

# System python3
check_bin "python3 (system)" "python3" "--version"

# ─────────────────────────────────────────────────────────────
# 7. Rust toolchains + cargo tools
# ─────────────────────────────────────────────────────────────
section "7. Rust"
check_bin "rustc (stable)"  "rustc"  "--version"
check_bin "cargo (stable)"  "cargo"  "--version"
check_bin "rustup"          "rustup" "--version"

# MSRV toolchain (rust-libp2p: 1.88.0)
MSRV="1.88.0"
if rustup toolchain list 2>/dev/null | grep -q "$MSRV"; then
  ok "Rust MSRV toolchain $MSRV installed"
else
  fail "Rust MSRV toolchain $MSRV NOT installed (rust-libp2p requires it)"
fi

# beta + nightly
for tc in beta nightly; do
  if rustup toolchain list 2>/dev/null | grep -q "$tc"; then
    ok "Rust $tc toolchain installed"
  else
    warn "Rust $tc toolchain not installed (some rust-libp2p CI jobs use it)"
  fi
done

# wasm32 targets
for target in wasm32-unknown-unknown wasm32-wasip1; do
  if rustup target list --installed 2>/dev/null | grep -q "$target"; then
    ok "Rust target $target installed"
  else
    fail "Rust target $target NOT installed (rust-libp2p cross-compilation)"
  fi
done

# Cargo tools
for tool in wasm-pack tomlq cargo-deny cargo-audit; do
  if command -v "$tool" &>/dev/null || cargo install --list 2>/dev/null | grep -q "^${tool} "; then
    ok "cargo tool: $tool"
  else
    fail "cargo tool: $tool NOT installed (rust-libp2p CI)"
  fi
done

# ─────────────────────────────────────────────────────────────
# 8. Nim  (py-libp2p interop tests)
# ─────────────────────────────────────────────────────────────
section "8. Nim (py-libp2p interop)"
check_bin "nim"    "nim"    "--version"
check_bin "nimble" "nimble" "--version"
check_bin "choosenim" "choosenim" "--version"

# ─────────────────────────────────────────────────────────────
# 9. Terraform  (test-plans perf workflow)
# ─────────────────────────────────────────────────────────────
section "9. Terraform"
check_bin "terraform" "terraform" "--version"

# ─────────────────────────────────────────────────────────────
# 10. Java (jvm-libp2p: temurin JDK 11)
# ─────────────────────────────────────────────────────────────
section "10. Java (jvm-libp2p)"
if command -v java &>/dev/null; then
  JAVA_VER=$(java -version 2>&1 | head -1)
  ok "java: $JAVA_VER"
  if echo "$JAVA_VER" | grep -qE "11\.|11 "; then
    ok "Java 11 confirmed"
  else
    warn "Java found but version may not be 11 — jvm-libp2p requires JDK 11"
  fi
else
  fail "java: NOT FOUND (jvm-libp2p requires JDK 11)"
fi

if [[ -n "${JAVA_HOME:-}" ]]; then
  ok "JAVA_HOME=$JAVA_HOME"
else
  warn "JAVA_HOME not set (may cause issues for gradle builds)"
fi

# ─────────────────────────────────────────────────────────────
# 11. Chromium + chromedriver  (rust-libp2p wasm tests)
# ─────────────────────────────────────────────────────────────
section "11. Chromium + chromedriver (rust-libp2p wasm tests)"
if command -v chromium-browser &>/dev/null; then
  ok "chromium-browser: $(chromium-browser --version 2>/dev/null | head -1)"
elif command -v chromium &>/dev/null; then
  ok "chromium: $(chromium --version 2>/dev/null | head -1)"
else
  fail "chromium/chromium-browser: NOT FOUND (rust-libp2p wasm_tests)"
fi

if command -v chromedriver &>/dev/null; then
  ok "chromedriver: $(chromedriver --version 2>/dev/null | head -1)"
else
  fail "chromedriver: NOT FOUND (rust-libp2p wasm_tests)"
fi

# ─────────────────────────────────────────────────────────────
# 12. Shadow simulator deps  (gossipsub-interop)
# ─────────────────────────────────────────────────────────────
section "12. Shadow simulator compile-time deps (gossipsub-interop)"
for lib in libglib2.0-dev libclang-dev; do
  if dpkg -l "$lib" 2>/dev/null | grep -q "^ii"; then
    ok "apt package $lib installed"
  else
    fail "apt package $lib NOT installed (Shadow simulator build)"
  fi
done
check_bin "python3-networkx check" "python3" "-c 'import networkx; print(networkx.__version__)'"

# ─────────────────────────────────────────────────────────────
# 13. GitHub Actions Runner
# ─────────────────────────────────────────────────────────────
section "13. GitHub Actions Runner"
if [[ -f /actions-runner/run.sh ]]; then
  ok "/actions-runner/run.sh exists"
else
  fail "/actions-runner/run.sh NOT FOUND"
fi

if systemctl is-enabled github-runner &>/dev/null; then
  ok "github-runner systemd service is enabled"
else
  warn "github-runner systemd service not enabled (expected on AMI)"
fi

# ─────────────────────────────────────────────────────────────
# 14. LIVE TEST: py-libp2p venv + make pr
#     Creates a venv, installs all deps, runs make pr (clean fix lint typecheck test)
#     This proves all py-libp2p must-have dependencies are present.
# ─────────────────────────────────────────────────────────────
# section "14. LIVE TEST: py-libp2p (venv + make pr)"

# if [[ "$SKIP_PY_VENV" == "true" ]]; then
#   warn "Skipping py-libp2p live test (--no-py-venv passed)"
# else
#   PY_REPO_DIR="${PY_LIBP2P_DIR:-}"

#   # Try to find py-libp2p if not given explicitly
#   if [[ -z "$PY_REPO_DIR" ]]; then
#     # Common locations
#     for candidate in \
#         "$(pwd)/extra/py-libp2p" \
#         "/tmp/py-libp2p" \
#         "${HOME}/py-libp2p"; do
#       if [[ -f "${candidate}/pyproject.toml" ]]; then
#         PY_REPO_DIR="$candidate"
#         break
#       fi
#     done
#   fi

#   if [[ -z "$PY_REPO_DIR" || ! -f "${PY_REPO_DIR}/pyproject.toml" ]]; then
#     warn "py-libp2p repo not found — cloning for live test..."
#     PY_REPO_DIR="/tmp/py-libp2p-verify"
#     rm -rf "$PY_REPO_DIR"
#     git clone --depth 1 https://github.com/libp2p/py-libp2p.git "$PY_REPO_DIR"
#   fi

#   echo -e "\n  ${CYAN}Running: cd $PY_REPO_DIR && make pr${RESET}"
#   echo "  (This runs: clean → fix → lint → typecheck → test)"
#   echo "  Log: /tmp/py-libp2p-verify.log"

#   LIVE_TEST_OK=true
#   (
#     set -euo pipefail
#     cd "$PY_REPO_DIR"

#     # Create isolated venv with uv
#     uv venv /tmp/py-libp2p-venv --python 3.12
#     # shellcheck source=/dev/null
#     source /tmp/py-libp2p-venv/bin/activate

#     # Install all dev + test dependencies
#     uv pip install --upgrade pip
#     uv pip install --group dev -e .

#     # Run make pr (= clean fix lint typecheck test)
#     make pr
#   ) > /tmp/py-libp2p-verify.log 2>&1 || LIVE_TEST_OK=false

#   if [[ "$LIVE_TEST_OK" == "true" ]]; then
#     ok "py-libp2p 'make pr' completed successfully"
#     ok "All py-libp2p must-have dependencies are present in the AMI"
#   else
#     fail "py-libp2p 'make pr' FAILED — check /tmp/py-libp2p-verify.log"
#     echo ""
#     echo "  Last 30 lines of log:"
#     tail -30 /tmp/py-libp2p-verify.log | sed 's/^/    /'
#   fi
# fi

# ─────────────────────────────────────────────────────────────
# 15. LIVE TEST: go-libp2p smoke test
# ─────────────────────────────────────────────────────────────
section "15. LIVE TEST: go-libp2p (go build smoke test)"

GO_REPO_DIR="${GO_LIBP2P_DIR:-}"
if [[ -z "$GO_REPO_DIR" ]]; then
  for candidate in "$(pwd)/extra/go-libp2p" "/tmp/go-libp2p"; do
    if [[ -f "${candidate}/go.mod" ]]; then
      GO_REPO_DIR="$candidate"
      break
    fi
  done
fi

if [[ -z "$GO_REPO_DIR" || ! -f "${GO_REPO_DIR}/go.mod" ]]; then
  warn "go-libp2p repo not found — cloning for smoke test..."
  GO_REPO_DIR="/tmp/go-libp2p-verify"
  rm -rf "$GO_REPO_DIR"
  git clone --depth 1 https://github.com/libp2p/go-libp2p.git "$GO_REPO_DIR"
fi

GO_SMOKE_OK=true
(
  set -euo pipefail
  cd "$GO_REPO_DIR"
  go build ./...
) > /tmp/go-libp2p-verify.log 2>&1 || GO_SMOKE_OK=false

if [[ "$GO_SMOKE_OK" == "true" ]]; then
  ok "go-libp2p 'go build ./...' succeeded"
else
  fail "go-libp2p 'go build ./...' FAILED — check /tmp/go-libp2p-verify.log"
  tail -20 /tmp/go-libp2p-verify.log | sed 's/^/    /'
fi

# ─────────────────────────────────────────────────────────────
# 16. LIVE TEST: rust-libp2p smoke test
# ─────────────────────────────────────────────────────────────
section "16. LIVE TEST: rust-libp2p (cargo check smoke test)"

RUST_REPO_DIR="${RUST_LIBP2P_DIR:-}"
if [[ -z "$RUST_REPO_DIR" ]]; then
  for candidate in "$(pwd)/extra/rust-libp2p" "/tmp/rust-libp2p"; do
    if [[ -f "${candidate}/Cargo.toml" ]]; then
      RUST_REPO_DIR="$candidate"
      break
    fi
  done
fi

if [[ -z "$RUST_REPO_DIR" || ! -f "${RUST_REPO_DIR}/Cargo.toml" ]]; then
  warn "rust-libp2p repo not found — cloning for smoke test (this may take a while)..."
  RUST_REPO_DIR="/tmp/rust-libp2p-verify"
  rm -rf "$RUST_REPO_DIR"
  git clone --depth 1 https://github.com/libp2p/rust-libp2p.git "$RUST_REPO_DIR"
fi

RUST_SMOKE_OK=true
(
  set -euo pipefail
  cd "$RUST_REPO_DIR"
  # Check with stable (quick — no full compile)
  cargo check --package libp2p --all-features
) > /tmp/rust-libp2p-verify.log 2>&1 || RUST_SMOKE_OK=false

if [[ "$RUST_SMOKE_OK" == "true" ]]; then
  ok "rust-libp2p 'cargo check' succeeded"
else
  fail "rust-libp2p 'cargo check' FAILED — check /tmp/rust-libp2p-verify.log"
  tail -20 /tmp/rust-libp2p-verify.log | sed 's/^/    /'
fi

# ─────────────────────────────────────────────────────────────
# Summary
# ─────────────────────────────────────────────────────────────
echo ""
echo -e "${BOLD}═══════════════════════════════════════════${RESET}"
echo -e "${BOLD}  AMI Verification Summary${RESET}"
echo -e "${BOLD}═══════════════════════════════════════════${RESET}"
echo -e "  ${GREEN}PASS${RESET}:    $PASS"
echo -e "  ${YELLOW}WARN${RESET}:    $WARN"
echo -e "  ${RED}FAIL${RESET}:    $FAIL"
echo -e "${BOLD}═══════════════════════════════════════════${RESET}"

if [[ $FAIL -gt 0 ]]; then
  echo -e "\n  ${RED}${BOLD}AMI VERIFICATION FAILED — $FAIL check(s) failed${RESET}"
  exit 1
elif [[ $WARN -gt 0 ]]; then
  echo -e "\n  ${YELLOW}${BOLD}AMI verification passed with $WARN warning(s)${RESET}"
  exit 0
else
  echo -e "\n  ${GREEN}${BOLD}AMI verification PASSED — all checks OK${RESET}"
  exit 0
fi
