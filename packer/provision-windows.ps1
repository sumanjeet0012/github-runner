# =============================================================================
# provision-windows.ps1 – Pre-bake a GitHub Actions self-hosted runner AMI
#                         for Windows Server 2022
#
# Installs everything needed to run:
#   • go-libp2p workflows      (go test, msys2 bash)
#   • rust-libp2p workflows    (cargo check, x86_64-pc-windows-msvc target)
#   • jvm-libp2p workflows     (gradle build, Java 11 Temurin)
#   • py-libp2p workflows      (tox matrix: core, demos, utils, wheel)
#   • js-libp2p workflows      (node test)
#
# Expected environment variables (set by Packer):
#   GO_VERSION      – e.g. "1.25.7"
#   NODE_VERSION    – major version, e.g. "22"
#   RUST_TOOLCHAIN  – e.g. "stable"
#   JAVA_VERSION    – e.g. "11"
#
# Run as Administrator.
# =============================================================================

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
Set-ExecutionPolicy Bypass -Scope Process -Force

# Remove PowerShell's built-in curl/wget aliases so the real executables are used
Remove-Item Alias:curl -ErrorAction SilentlyContinue
Remove-Item Alias:wget -ErrorAction SilentlyContinue

$GO_VERSION     = if ($env:GO_VERSION)     { $env:GO_VERSION }     else { "1.25.7" }
$NODE_VERSION   = if ($env:NODE_VERSION)   { $env:NODE_VERSION }   else { "22" }
$RUST_TOOLCHAIN = if ($env:RUST_TOOLCHAIN) { $env:RUST_TOOLCHAIN } else { "stable" }
$JAVA_VERSION   = if ($env:JAVA_VERSION)   { $env:JAVA_VERSION }   else { "11" }

$RUNNER_USER = "actions-runner"
$RUNNER_DIR  = "C:\actions-runner"

function Log {
    param([string]$Msg)
    Write-Host ""
    Write-Host ">>> $Msg"
    Write-Host ""
}

function Refresh-Path {
    $env:PATH = [System.Environment]::GetEnvironmentVariable("PATH", "Machine") + ";" +
                [System.Environment]::GetEnvironmentVariable("PATH", "User")
}

# ─────────────────────────────────────────────────────────────
# 1. Chocolatey
# ─────────────────────────────────────────────────────────────
Log "1/14  Chocolatey"

[System.Net.ServicePointManager]::SecurityProtocol = `
    [System.Net.ServicePointManager]::SecurityProtocol -bor 3072
Set-ExecutionPolicy Bypass -Scope Process -Force

if (-not (Get-Command choco -ErrorAction SilentlyContinue)) {
    # Retry up to 5 times to handle transient 504 errors from Chocolatey CDN
    $maxRetries = 5
    $attempt = 0
    $installed = $false
    while (-not $installed -and $attempt -lt $maxRetries) {
        $attempt++
        Write-Host "Chocolatey install attempt $attempt of $maxRetries..."
        try {
            $installScript = (New-Object System.Net.WebClient).DownloadString(
                'https://community.chocolatey.org/install.ps1')
            Invoke-Expression $installScript
            $installed = $true
        } catch {
            Write-Host "Attempt $attempt failed: $_"
            if ($attempt -lt $maxRetries) {
                Write-Host "Waiting 30 seconds before retry..."
                Start-Sleep -Seconds 30
            }
        }
    }
    if (-not $installed) {
        Write-Host "ERROR: Chocolatey installation failed after $maxRetries attempts"
        exit 1
    }
    Refresh-Path
    Write-Host "Chocolatey installed."
} else {
    Write-Host "Chocolatey already present."
}

choco feature enable -n allowGlobalConfirmation

# ─────────────────────────────────────────────────────────────
# 2. Core utilities: git, jq, curl, 7zip
# ─────────────────────────────────────────────────────────────
Log "2/14  Core utilities"

choco install -y --no-progress git jq curl 7zip
Refresh-Path

git --version
# Use curl.exe explicitly to avoid PowerShell's built-in Invoke-WebRequest alias
curl.exe --version | Select-Object -First 1

# ─────────────────────────────────────────────────────────────
# 3. AWS CLI v2
# ─────────────────────────────────────────────────────────────
Log "3/14  AWS CLI v2"

# Use Chocolatey to avoid MSI installer dropping the WinRM session
choco install -y --no-progress awscli
Refresh-Path

$_prev = $ErrorActionPreference; $ErrorActionPreference = 'SilentlyContinue'
aws --version
$ErrorActionPreference = $_prev

# ─────────────────────────────────────────────────────────────
# 4. GitHub CLI (gh)
# ─────────────────────────────────────────────────────────────
Log "4/14  GitHub CLI (gh)"

choco install -y --no-progress gh
Refresh-Path
gh --version

# ─────────────────────────────────────────────────────────────
# 5. Go
# ─────────────────────────────────────────────────────────────
Log "5/14  Go $GO_VERSION"

# Use Chocolatey for Go to avoid MSI installer dropping the WinRM session
choco install -y --no-progress golang --version="$GO_VERSION"
Refresh-Path

# Add Go to PATH for this session
$goPath = "C:\Program Files\Go\bin"
if (Test-Path $goPath) {
    $env:PATH = "$goPath;$env:PATH"
    [System.Environment]::SetEnvironmentVariable(
        "PATH",
        "$goPath;" + [System.Environment]::GetEnvironmentVariable("PATH", "Machine"),
        "Machine"
    )
}

go version

# ─────────────────────────────────────────────────────────────
# 6. Node.js LTS
# ─────────────────────────────────────────────────────────────
Log "6/14  Node.js $NODE_VERSION"

choco install -y --no-progress nodejs --version="$NODE_VERSION"
Refresh-Path

node --version
npm --version

# ─────────────────────────────────────────────────────────────
# 7. Python 3.11, 3.12, 3.13 + uv + tox
#    py-libp2p tox matrix: core, demos, utils, wheel
# ─────────────────────────────────────────────────────────────
Log "7/14  Python 3.11 / 3.12 / 3.13 + uv + tox"

# Install all three Python versions via Chocolatey
foreach ($pyver in @("3.11", "3.12", "3.13")) {
    Write-Host "Installing Python $pyver ..."
    choco install -y --no-progress "python$($pyver.Replace('.',''))"
}
Refresh-Path

# Install uv system-wide (fast Python package manager)
$uvInstaller = "$env:TEMP\uv-installer.ps1"
Invoke-WebRequest -Uri "https://astral.sh/uv/install.ps1" `
    -OutFile $uvInstaller -UseBasicParsing
# Install to a system-wide location
$env:UV_INSTALL_DIR = "C:\tools\uv"
$env:INSTALLER_NO_MODIFY_PATH = "0"
powershell -ExecutionPolicy Bypass -File $uvInstaller
Remove-Item $uvInstaller

# Add uv to system PATH
$uvBin = "C:\tools\uv"
[System.Environment]::SetEnvironmentVariable(
    "PATH",
    "$uvBin;" + [System.Environment]::GetEnvironmentVariable("PATH", "Machine"),
    "Machine"
)
$env:PATH = "$uvBin;$env:PATH"

uv --version

# Install tox via uv (system-wide)
$env:UV_TOOL_BIN_DIR = "C:\tools\uv"
uv tool install tox --reinstall
tox --version

# ─────────────────────────────────────────────────────────────
# 8. Java 11 (Temurin) – required by jvm-libp2p
# ─────────────────────────────────────────────────────────────
Log "8/14  Java $JAVA_VERSION (Temurin)"

# Use Chocolatey to avoid MSI installer dropping WinRM session
choco install -y --no-progress temurin$JAVA_VERSION
Refresh-Path

$_prev = $ErrorActionPreference; $ErrorActionPreference = 'SilentlyContinue'
java -version
$ErrorActionPreference = $_prev

# Set JAVA_HOME
$javaHome = (Get-ChildItem "C:\Program Files\Eclipse Adoptium" -Directory -ErrorAction SilentlyContinue |
    Where-Object { $_.Name -match "jdk-$JAVA_VERSION" } |
    Select-Object -First 1).FullName
if (-not $javaHome) {
    $javaHome = (Get-Command java -ErrorAction SilentlyContinue).Source |
        Split-Path | Split-Path
}
if ($javaHome) {
    [System.Environment]::SetEnvironmentVariable("JAVA_HOME", $javaHome, "Machine")
    $env:JAVA_HOME = $javaHome
    Write-Host "JAVA_HOME set to: $javaHome"
}

Log "=== Phase 1 complete (steps 1-8) - VS Build Tools run in provision-windows-vs.ps1 ==="
Write-Host "  git:    $(git --version)"
Write-Host "  go:     $(go version)"
Write-Host "  node:   $(node --version)"
Write-Host "  python: $(python --version)"
Write-Host "  uv:     $(uv --version)"
$_prev = $ErrorActionPreference; $ErrorActionPreference = 'SilentlyContinue'
$javaVer = (java -version 2>&1 | Out-String).Trim() -split "`n" | Select-Object -First 1
$ErrorActionPreference = $_prev
Write-Host "  java:   $javaVer"
$_prev = $ErrorActionPreference; $ErrorActionPreference = 'SilentlyContinue'
$awsVer = (aws --version 2>&1 | Out-String).Trim()
$ErrorActionPreference = $_prev
Write-Host "  aws:    $awsVer"
Write-Host "  gh:     $(gh --version | Select-Object -First 1)"

Write-Host ""
Write-Host "Phase 1 done. Steps 9-14 run in separate provisioner scripts."


