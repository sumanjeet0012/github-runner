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

Log "=== Phase 1 complete (steps 1-8) ==="
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
#    Target: x86_64-pc-windows-msvc
# ─────────────────────────────────────────────────────────────
Log "9/14  Visual Studio Build Tools (C++ workload for Rust MSVC)"

# Use Chocolatey to install VS Build Tools — avoids MSI dropping the WinRM session
# --wait ensures choco blocks until the installer fully exits (prevents WinRM EOF)
# --passive instead of --quiet keeps the installer visible but non-interactive
choco install -y --no-progress visualstudio2022buildtools `
    --package-parameters "--add Microsoft.VisualStudio.Workload.VCTools --add Microsoft.VisualStudio.Component.Windows11SDK.22621 --add Microsoft.VisualStudio.Component.VC.Tools.x86.x64 --includeRecommended --wait --norestart --passive"
Write-Host "VS Build Tools installed."

Log "10/14  Rust ($RUST_TOOLCHAIN + MSVC target)"

$rustupInit = "$env:TEMP\rustup-init.exe"
Invoke-WebRequest -Uri "https://win.rustup.rs/x86_64" `
    -OutFile $rustupInit -UseBasicParsing

# Install Rust system-wide (RUSTUP_HOME + CARGO_HOME in ProgramData)
$env:RUSTUP_HOME = "C:\ProgramData\rustup"
$env:CARGO_HOME  = "C:\ProgramData\cargo"
[System.Environment]::SetEnvironmentVariable("RUSTUP_HOME", "C:\ProgramData\rustup", "Machine")
[System.Environment]::SetEnvironmentVariable("CARGO_HOME",  "C:\ProgramData\cargo",  "Machine")

Start-Process $rustupInit -ArgumentList `
    "-y", "--no-modify-path",
    "--default-toolchain", $RUST_TOOLCHAIN,
    "--default-host",      "x86_64-pc-windows-msvc",
    "--profile",           "minimal" `
    -Wait
Remove-Item $rustupInit

# Add cargo bin to system PATH
$cargoBin = "C:\ProgramData\cargo\bin"
[System.Environment]::SetEnvironmentVariable(
    "PATH",
    "$cargoBin;" + [System.Environment]::GetEnvironmentVariable("PATH", "Machine"),
    "Machine"
)
$env:PATH = "$cargoBin;$env:PATH"

rustc --version
cargo --version

# Install MSRV (1.88.0 for rust-libp2p) and beta/nightly
rustup toolchain install "1.88.0" --profile minimal
rustup toolchain install beta    --profile minimal
rustup toolchain install nightly --profile minimal

# Add wasm32 targets
rustup target add wasm32-unknown-unknown
rustup target add wasm32-wasip1

Write-Host "Rust toolchains installed."

# ─────────────────────────────────────────────────────────────
# 11. msys2 – go-libp2p uses `shell: bash` on Windows
# ─────────────────────────────────────────────────────────────
Log "11/14  msys2 (bash for go-libp2p Windows jobs)"

choco install -y --no-progress msys2

# Add msys2 usr/bin to system PATH (go-libp2p workflow prepends C:/msys64/usr/bin)
$msys2Bin = "C:\msys64\usr\bin"
if (Test-Path $msys2Bin) {
    [System.Environment]::SetEnvironmentVariable(
        "PATH",
        "$msys2Bin;" + [System.Environment]::GetEnvironmentVariable("PATH", "Machine"),
        "Machine"
    )
    Write-Host "msys2 added to PATH."
}

# Update msys2 packages
$msys2Bash = "C:\msys64\usr\bin\bash.exe"
if (Test-Path $msys2Bash) {
    & $msys2Bash -lc "pacman -Syu --noconfirm" 2>&1 | Write-Host
    & $msys2Bash -lc "pacman -S --noconfirm git curl make" 2>&1 | Write-Host
}

# ─────────────────────────────────────────────────────────────
# 12. GitHub Actions Runner binary
# ─────────────────────────────────────────────────────────────
Log "12/14  GitHub Actions Runner binary"

$releaseJson   = Invoke-RestMethod `
    -Uri "https://api.github.com/repos/actions/runner/releases/latest" `
    -Headers @{ "User-Agent" = "packer-provision" }
$runnerVersion = $releaseJson.tag_name.TrimStart("v")
Write-Host "Runner version: $runnerVersion"

New-Item -ItemType Directory -Force -Path $RUNNER_DIR | Out-Null
$runnerZip = "$env:TEMP\runner.zip"
Invoke-WebRequest `
    -Uri "https://github.com/actions/runner/releases/download/v${runnerVersion}/actions-runner-win-x64-${runnerVersion}.zip" `
    -OutFile $runnerZip -UseBasicParsing
Expand-Archive -Path $runnerZip -DestinationPath $RUNNER_DIR -Force
Remove-Item $runnerZip
Write-Host "Runner extracted to $RUNNER_DIR."

# Install runner dependencies
& "$RUNNER_DIR\bin\installdependencies.ps1" 2>&1 | Write-Host

# ─────────────────────────────────────────────────────────────
# 13. Pre-bake runner entrypoint + local runner user
# ─────────────────────────────────────────────────────────────
Log "13/14  Pre-baking runner entrypoint + runner user"

# Create the actions-runner local user
$runnerPassword = [System.Web.Security.Membership]::GeneratePassword(20, 4)
$securePassword = ConvertTo-SecureString $runnerPassword -AsPlainText -Force
try {
    New-LocalUser -Name $RUNNER_USER -Password $securePassword `
        -FullName "GitHub Actions Runner" -Description "Self-hosted runner service account" `
        -PasswordNeverExpires -UserMayNotChangePassword
    Write-Host "Created local user: $RUNNER_USER"
} catch {
    Write-Host "User $RUNNER_USER may already exist: $_"
}

# Add to Administrators group (needed for Docker, VS Build Tools, etc.)
Add-LocalGroupMember -Group "Administrators" -Member $RUNNER_USER -ErrorAction SilentlyContinue

# Give runner user full control over the runner directory
$acl = Get-Acl $RUNNER_DIR
$rule = New-Object System.Security.AccessControl.FileSystemAccessRule(
    $RUNNER_USER, "FullControl", "ContainerInherit,ObjectInherit", "None", "Allow"
)
$acl.SetAccessRule($rule)
Set-Acl -Path $RUNNER_DIR -AclObject $acl

# ── Entrypoint script (equivalent of linux github-runner-entrypoint.sh) ──
@'
# github-runner-entrypoint.ps1
# Registers the runner with GitHub (ephemeral) then starts it.
# All required env vars are read from C:\github-runner.env at boot time.
Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# Load env file
Get-Content "C:\github-runner.env" | ForEach-Object {
    if ($_ -match '^\s*([^#][^=]+)=(.*)$') {
        [System.Environment]::SetEnvironmentVariable($Matches[1].Trim(), $Matches[2].Trim(), "Process")
    }
}

$ACCESS_TOKEN   = $env:ACCESS_TOKEN
$RUNNER_SCOPE   = $env:RUNNER_SCOPE
$ORG_NAME       = $env:ORG_NAME
$REPO_URL       = $env:REPO_URL
$LABELS         = $env:LABELS
$RUNNER_NAME    = $env:RUNNER_NAME

$AuthHeaders = @{
    Authorization          = "Bearer $ACCESS_TOKEN"
    Accept                 = "application/vnd.github+json"
    "X-GitHub-Api-Version" = "2022-11-28"
}

# Obtain registration token
if ($RUNNER_SCOPE -eq "org" -and -not [string]::IsNullOrWhiteSpace($ORG_NAME)) {
    $TokenUrl  = "https://api.github.com/orgs/$ORG_NAME/actions/runners/registration-token"
    $TargetUrl = "https://github.com/$ORG_NAME"
} else {
    $RepoPath  = ([System.Uri]$REPO_URL).AbsolutePath.Trim("/")
    $TokenUrl  = "https://api.github.com/repos/$RepoPath/actions/runners/registration-token"
    $TargetUrl = $REPO_URL
}

$RegResponse = Invoke-RestMethod -Uri $TokenUrl -Method POST -Headers $AuthHeaders
$REG_TOKEN   = $RegResponse.token
if ([string]::IsNullOrWhiteSpace($REG_TOKEN)) {
    Write-Host "[entrypoint] ERROR: Failed to obtain registration token"; exit 1
}

Write-Host "[entrypoint] Configuring runner '$RUNNER_NAME' → $TargetUrl"
Set-Location "C:\actions-runner"
& .\config.cmd --url $TargetUrl --token $REG_TOKEN --name $RUNNER_NAME `
               --labels $LABELS --runnergroup "Default" --work "_work" `
               --ephemeral --unattended --replace

Write-Host "[entrypoint] Starting runner..."
& .\run.cmd
'@ | Set-Content -Path "C:\github-runner-entrypoint.ps1" -Encoding UTF8

# ── Wrapper script (pre-flight check + self-terminate) ──
@'
# github-runner-wrapper.ps1
# 1. Check if the GitHub job is still active.
# 2. Run the entrypoint.
# 3. Terminate this EC2 instance.
Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# Load env file
Get-Content "C:\github-runner.env" | ForEach-Object {
    if ($_ -match '^\s*([^#][^=]+)=(.*)$') {
        [System.Environment]::SetEnvironmentVariable($Matches[1].Trim(), $Matches[2].Trim(), "Process")
    }
}

$ACCESS_TOKEN = $env:ACCESS_TOKEN
$RUNNER_SCOPE = $env:RUNNER_SCOPE
$ORG_NAME     = $env:ORG_NAME
$REPO_URL     = $env:REPO_URL

# IMDSv2
$imdsToken   = Invoke-RestMethod -Uri "http://169.254.169.254/latest/api/token" `
    -Method PUT -Headers @{ "X-aws-ec2-metadata-token-ttl-seconds" = "60" } -TimeoutSec 5
$INSTANCE_ID = Invoke-RestMethod -Uri "http://169.254.169.254/latest/meta-data/instance-id" `
    -Headers @{ "X-aws-ec2-metadata-token" = $imdsToken } -TimeoutSec 5
$REGION      = Invoke-RestMethod -Uri "http://169.254.169.254/latest/meta-data/placement/region" `
    -Headers @{ "X-aws-ec2-metadata-token" = $imdsToken } -TimeoutSec 5

Write-Host "[wrapper] Starting runner on instance $INSTANCE_ID"

# Check if job is still active
$JobId = (aws ec2 describe-tags --region $REGION `
    --filters "Name=resource-id,Values=$INSTANCE_ID" "Name=key,Values=GitHubJobId" `
    --query "Tags[0].Value" --output text 2>$null).Trim()

if (-not [string]::IsNullOrWhiteSpace($JobId) -and $JobId -ne "None") {
    Write-Host "[wrapper] Job ID: $JobId. Checking status..."
    $AuthHeaders = @{
        Authorization          = "Bearer $ACCESS_TOKEN"
        Accept                 = "application/vnd.github+json"
        "X-GitHub-Api-Version" = "2022-11-28"
    }
    if ($RUNNER_SCOPE -eq "org" -and -not [string]::IsNullOrWhiteSpace($ORG_NAME)) {
        $JobUrl = "https://api.github.com/orgs/$ORG_NAME/actions/jobs/$JobId"
    } else {
        $RepoPath = ([System.Uri]$REPO_URL).AbsolutePath.Trim("/")
        $JobUrl   = "https://api.github.com/repos/$RepoPath/actions/jobs/$JobId"
    }
    try {
        $JobStatus = (Invoke-RestMethod -Uri $JobUrl -Headers $AuthHeaders).status
        Write-Host "[wrapper] GitHub job status: $JobStatus"
        if ($JobStatus -eq "completed" -or $JobStatus -eq "cancelled") {
            Write-Host "[wrapper] Job already $JobStatus. Terminating..."
            aws ec2 terminate-instances --region $REGION --instance-ids $INSTANCE_ID
            exit 0
        }
    } catch {
        Write-Host "[wrapper] WARNING: Could not query job status: $_"
    }
}

# Run the entrypoint
& "C:\github-runner-entrypoint.ps1"

Write-Host "[wrapper] Runner finished. Terminating instance $INSTANCE_ID..."
aws ec2 terminate-instances --region $REGION --instance-ids $INSTANCE_ID
'@ | Set-Content -Path "C:\github-runner-wrapper.ps1" -Encoding UTF8

# Placeholder env file (populated at boot by user_data.ps1.tpl)
@'
# Populated at instance boot time by user_data.ps1.tpl
ACCESS_TOKEN=
RUNNER_SCOPE=
REPO_URL=
ORG_NAME=
LABELS=
RUNNER_NAME=
'@ | Set-Content -Path "C:\github-runner.env" -Encoding UTF8

# ─────────────────────────────────────────────────────────────
# 14. Windows configuration tweaks
# ─────────────────────────────────────────────────────────────
Log "14/14  Windows configuration tweaks"

# Disable Windows Defender real-time monitoring (slows down CI builds significantly)
Set-MpPreference -DisableRealtimeMonitoring $true -ErrorAction SilentlyContinue
# Exclude common build/tool directories from scanning
Add-MpPreference -ExclusionPath @(
    "C:\actions-runner",
    "C:\ProgramData\cargo",
    "C:\ProgramData\rustup",
    "C:\tools",
    "C:\Program Files\Go"
) -ErrorAction SilentlyContinue
Write-Host "Windows Defender exclusions set."

# Disable Windows Update auto-restart during CI
reg add "HKLM\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU" `
    /v NoAutoRebootWithLoggedOnUsers /t REG_DWORD /d 1 /f | Out-Null

# Enable long path support (needed for deep node_modules / cargo paths)
reg add "HKLM\SYSTEM\CurrentControlSet\Control\FileSystem" `
    /v LongPathsEnabled /t REG_DWORD /d 1 /f | Out-Null
Write-Host "Long paths enabled."

# Set timezone to UTC
Set-TimeZone -Id "UTC"
Write-Host "Timezone set to UTC."

# Refresh PATH one final time
Refresh-Path

# ─────────────────────────────────────────────────────────────
# Final summary
# ─────────────────────────────────────────────────────────────
Log "=== Provisioning complete ==="
Write-Host "Installed tools summary:"
Write-Host "  git:     $(git --version)"
Write-Host "  go:      $(go version)"
Write-Host "  node:    $(node --version)"
Write-Host "  npm:     $(npm --version)"
Write-Host "  python:  $(python --version)"
Write-Host "  uv:      $(uv --version)"
Write-Host "  java:    $(java -version 2>&1 | Select-Object -First 1)"
Write-Host "  rustc:   $(rustc --version)"
Write-Host "  cargo:   $(cargo --version)"
Write-Host "  aws:     $(aws --version)"
Write-Host "  gh:      $(gh --version | Select-Object -First 1)"
