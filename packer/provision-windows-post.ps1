# =============================================================================
# provision-windows-post.ps1 – Steps 10-14: Rust, msys2, runner, tweaks
# Run AFTER provision-windows-vs.ps1 (VS Build Tools) in a fresh WinRM session.
# =============================================================================
Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
Set-ExecutionPolicy Bypass -Scope Process -Force

Remove-Item Alias:curl -ErrorAction SilentlyContinue
Remove-Item Alias:wget -ErrorAction SilentlyContinue

$RUST_TOOLCHAIN = if ($env:RUST_TOOLCHAIN) { $env:RUST_TOOLCHAIN } else { "stable" }
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
# 10. Rust (MSVC toolchain) – rust-libp2p Windows target
# ─────────────────────────────────────────────────────────────
Log "10/14  Rust ($RUST_TOOLCHAIN + MSVC target)"

$rustupInit = "$env:TEMP\rustup-init.exe"
Invoke-WebRequest -Uri "https://win.rustup.rs/x86_64" `
    -OutFile $rustupInit -UseBasicParsing

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

$cargoBin = "C:\ProgramData\cargo\bin"
[System.Environment]::SetEnvironmentVariable(
    "PATH",
    "$cargoBin;" + [System.Environment]::GetEnvironmentVariable("PATH", "Machine"),
    "Machine"
)
$env:PATH = "$cargoBin;$env:PATH"

rustc --version
cargo --version

rustup toolchain install "1.88.0" --profile minimal
rustup toolchain install beta    --profile minimal
rustup toolchain install nightly --profile minimal
rustup target add wasm32-unknown-unknown
rustup target add wasm32-wasip1

Write-Host "Rust toolchains installed."

# ─────────────────────────────────────────────────────────────
# 11. msys2 – go-libp2p uses `shell: bash` on Windows
# ─────────────────────────────────────────────────────────────
Log "11/14  msys2 (bash for go-libp2p Windows jobs)"

choco install -y --no-progress msys2

$msys2Bin = "C:\msys64\usr\bin"
if (Test-Path $msys2Bin) {
    [System.Environment]::SetEnvironmentVariable(
        "PATH",
        "$msys2Bin;" + [System.Environment]::GetEnvironmentVariable("PATH", "Machine"),
        "Machine"
    )
    Write-Host "msys2 added to PATH."
}

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

# installdependencies.ps1 was removed in newer runner versions - skip if not present
if (Test-Path "$RUNNER_DIR\bin\installdependencies.ps1") {
    & "$RUNNER_DIR\bin\installdependencies.ps1" 2>&1 | Write-Host
} else {
    Write-Host "installdependencies.ps1 not present (runner v2.334.0+), skipping."
}

# ─────────────────────────────────────────────────────────────
# 13. Pre-bake runner entrypoint + local runner user
# ─────────────────────────────────────────────────────────────
Log "13/14  Pre-baking runner entrypoint + runner user"

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

Add-LocalGroupMember -Group "Administrators" -Member $RUNNER_USER -ErrorAction SilentlyContinue

$acl = Get-Acl $RUNNER_DIR
$rule = New-Object System.Security.AccessControl.FileSystemAccessRule(
    $RUNNER_USER, "FullControl", "ContainerInherit,ObjectInherit", "None", "Allow"
)
$acl.SetAccessRule($rule)
Set-Acl -Path $RUNNER_DIR -AclObject $acl

@'
# github-runner-entrypoint.ps1
Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
Get-Content "C:\github-runner.env" | ForEach-Object {
    if ($_ -match '^\s*([^#][^=]+)=(.*)$') {
        [System.Environment]::SetEnvironmentVariable($Matches[1].Trim(), $Matches[2].Trim(), "Process")
    }
}
$ACCESS_TOKEN = $env:ACCESS_TOKEN
$RUNNER_SCOPE = $env:RUNNER_SCOPE
$ORG_NAME     = $env:ORG_NAME
$REPO_URL     = $env:REPO_URL
$LABELS       = $env:LABELS
$RUNNER_NAME  = $env:RUNNER_NAME
$AuthHeaders = @{ Authorization = "Bearer $ACCESS_TOKEN"; Accept = "application/vnd.github+json"; "X-GitHub-Api-Version" = "2022-11-28" }
if ($RUNNER_SCOPE -eq "org" -and -not [string]::IsNullOrWhiteSpace($ORG_NAME)) {
    $TokenUrl = "https://api.github.com/orgs/$ORG_NAME/actions/runners/registration-token"
    $TargetUrl = "https://github.com/$ORG_NAME"
} else {
    $RepoPath = ([System.Uri]$REPO_URL).AbsolutePath.Trim("/")
    $TokenUrl = "https://api.github.com/repos/$RepoPath/actions/runners/registration-token"
    $TargetUrl = $REPO_URL
}
$REG_TOKEN = (Invoke-RestMethod -Uri $TokenUrl -Method POST -Headers $AuthHeaders).token
if ([string]::IsNullOrWhiteSpace($REG_TOKEN)) { Write-Host "[entrypoint] ERROR: No token"; exit 1 }
Write-Host "[entrypoint] Configuring runner '$RUNNER_NAME' -> $TargetUrl"
Set-Location "C:\actions-runner"
& .\config.cmd --url $TargetUrl --token $REG_TOKEN --name $RUNNER_NAME --labels $LABELS --runnergroup "Default" --work "_work" --ephemeral --unattended --replace
Write-Host "[entrypoint] Starting runner..."
& .\run.cmd
'@ | Set-Content -Path "C:\github-runner-entrypoint.ps1" -Encoding UTF8

@'
# github-runner-wrapper.ps1
Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
Get-Content "C:\github-runner.env" | ForEach-Object {
    if ($_ -match '^\s*([^#][^=]+)=(.*)$') {
        [System.Environment]::SetEnvironmentVariable($Matches[1].Trim(), $Matches[2].Trim(), "Process")
    }
}
$ACCESS_TOKEN = $env:ACCESS_TOKEN; $RUNNER_SCOPE = $env:RUNNER_SCOPE
$ORG_NAME = $env:ORG_NAME; $REPO_URL = $env:REPO_URL
$imdsToken = Invoke-RestMethod -Uri "http://169.254.169.254/latest/api/token" -Method PUT -Headers @{ "X-aws-ec2-metadata-token-ttl-seconds" = "60" } -TimeoutSec 5
$INSTANCE_ID = Invoke-RestMethod -Uri "http://169.254.169.254/latest/meta-data/instance-id" -Headers @{ "X-aws-ec2-metadata-token" = $imdsToken } -TimeoutSec 5
$REGION = Invoke-RestMethod -Uri "http://169.254.169.254/latest/meta-data/placement/region" -Headers @{ "X-aws-ec2-metadata-token" = $imdsToken } -TimeoutSec 5
Write-Host "[wrapper] Starting runner on instance $INSTANCE_ID"
$JobId = (aws ec2 describe-tags --region $REGION --filters "Name=resource-id,Values=$INSTANCE_ID" "Name=key,Values=GitHubJobId" --query "Tags[0].Value" --output text 2>$null).Trim()
if (-not [string]::IsNullOrWhiteSpace($JobId) -and $JobId -ne "None") {
    $AuthHeaders = @{ Authorization = "Bearer $ACCESS_TOKEN"; Accept = "application/vnd.github+json"; "X-GitHub-Api-Version" = "2022-11-28" }
    $JobUrl = if ($RUNNER_SCOPE -eq "org") { "https://api.github.com/orgs/$ORG_NAME/actions/jobs/$JobId" } else { "https://api.github.com/repos/$(([System.Uri]$REPO_URL).AbsolutePath.Trim('/'))/actions/jobs/$JobId" }
    try {
        $JobStatus = (Invoke-RestMethod -Uri $JobUrl -Headers $AuthHeaders).status
        if ($JobStatus -eq "completed" -or $JobStatus -eq "cancelled") {
            Write-Host "[wrapper] Job $JobStatus. Terminating..."; aws ec2 terminate-instances --region $REGION --instance-ids $INSTANCE_ID; exit 0
        }
    } catch { Write-Host "[wrapper] WARNING: $_" }
}
& "C:\github-runner-entrypoint.ps1"
Write-Host "[wrapper] Runner finished. Terminating $INSTANCE_ID..."
aws ec2 terminate-instances --region $REGION --instance-ids $INSTANCE_ID
'@ | Set-Content -Path "C:\github-runner-wrapper.ps1" -Encoding UTF8

@'
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

Set-MpPreference -DisableRealtimeMonitoring $true -ErrorAction SilentlyContinue
Add-MpPreference -ExclusionPath @("C:\actions-runner","C:\ProgramData\cargo","C:\ProgramData\rustup","C:\tools","C:\Program Files\Go") -ErrorAction SilentlyContinue
reg add "HKLM\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU" /v NoAutoRebootWithLoggedOnUsers /t REG_DWORD /d 1 /f | Out-Null
reg add "HKLM\SYSTEM\CurrentControlSet\Control\FileSystem" /v LongPathsEnabled /t REG_DWORD /d 1 /f | Out-Null
Set-TimeZone -Id "UTC"
Refresh-Path
Write-Host "Windows tweaks applied."

Log "=== Post-provisioning complete ==="
Write-Host "  rustc:  $(rustc --version)"
Write-Host "  cargo:  $(cargo --version)"
Write-Host "  aws:    $(aws --version)"
