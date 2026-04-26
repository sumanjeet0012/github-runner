#Requires -RunAsAdministrator
# GitHub Actions self-hosted runner bootstrap for Windows Server.
# Mirrors the Linux github-runner-init.sh:
#   - installs dependencies via Chocolatey
#   - fetches PAT from AWS Secrets Manager
#   - registers an ephemeral runner
#   - self-terminates the EC2 instance after one job
#
# Template variables (${...}) are interpolated by Terraform before this
# script runs on the instance.

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------
$LogFile = "C:\ProgramData\github-runner-init.log"
function Write-Log {
    param([string]$Message)
    $ts   = (Get-Date -Format "yyyy-MM-dd HH:mm:ss")
    $line = "$ts  $Message"
    Write-Host $line
    Add-Content -Path $LogFile -Value $line
}

Write-Log "=== GitHub Actions Runner Bootstrap - Windows Server ==="

# ---------------------------------------------------------------------------
# Helper: IMDSv2 metadata fetch
# ---------------------------------------------------------------------------
function Get-IMDSToken {
    $headers = @{ "X-aws-ec2-metadata-token-ttl-seconds" = "21600" }
    Invoke-RestMethod -Uri "http://169.254.169.254/latest/api/token" `
                      -Method PUT -Headers $headers -TimeoutSec 5
}

function Get-IMDSValue {
    param([string]$Path)
    $token = Get-IMDSToken
    Invoke-RestMethod -Uri "http://169.254.169.254/latest/meta-data/$Path" `
                      -Headers @{ "X-aws-ec2-metadata-token" = $token } `
                      -TimeoutSec 5
}

# ---------------------------------------------------------------------------
# 1. Install Chocolatey
# ---------------------------------------------------------------------------
Write-Log "=== Installing Chocolatey ==="
if (-not (Get-Command choco -ErrorAction SilentlyContinue)) {
    [System.Net.ServicePointManager]::SecurityProtocol = `
        [System.Net.ServicePointManager]::SecurityProtocol -bor 3072
    Invoke-Expression ((New-Object System.Net.WebClient).DownloadString(
        'https://community.chocolatey.org/install.ps1'))

    $chocoPath = Join-Path $env:ALLUSERSPROFILE "chocolatey\bin"
    $env:PATH  = $env:PATH + ";" + $chocoPath
    Write-Log "Chocolatey installed."
} else {
    Write-Log "Chocolatey already present - skipping."
}

# ---------------------------------------------------------------------------
# 2. Install core dependencies
# ---------------------------------------------------------------------------
Write-Log "=== Installing core dependencies (git, jq, awscli) ==="
$packages = @("git", "jq", "awscli")
foreach ($pkg in $packages) {
    Write-Log "  Installing $pkg ..."
    choco install $pkg -y --no-progress | Out-Null
}

# Refresh PATH so aws / git / jq are visible in this session
$machinePath = [System.Environment]::GetEnvironmentVariable("PATH", "Machine")
$userPath    = [System.Environment]::GetEnvironmentVariable("PATH", "User")
$env:PATH    = $machinePath + ";" + $userPath

# Also explicitly add known AWS CLI install locations
$awsCliPaths = @(
    "C:\Program Files\Amazon\AWSCLIV2",
    "C:\ProgramData\chocolatey\bin"
)
foreach ($p in $awsCliPaths) {
    if (Test-Path $p) {
        $env:PATH = $p + ";" + $env:PATH
        Write-Log "Added to PATH: $p"
    }
}

Write-Log "Core dependencies installed."
Write-Log "PATH is now: $env:PATH"

# ---------------------------------------------------------------------------
# 3. Fetch GitHub PAT from AWS Secrets Manager
# ---------------------------------------------------------------------------
Write-Log "=== Fetching GitHub PAT from Secrets Manager ==="
$AwsRegion           = "eu-north-1"
$GithubPatSecretName = "/test/1/github_pat"

# Diagnose aws availability
$awsExe = Get-Command aws -ErrorAction SilentlyContinue
if ($awsExe) {
    Write-Log "aws found at: $($awsExe.Source)"
} else {
    # Try to find it manually
    $candidates = @(
        "C:\Program Files\Amazon\AWSCLIV2\aws.exe",
        "C:\ProgramData\chocolatey\bin\aws.exe",
        "C:\ProgramData\chocolatey\bin\aws"
    )
    $awsPath = $null
    foreach ($c in $candidates) {
        if (Test-Path $c) { $awsPath = $c; break }
    }
    if ($awsPath) {
        Write-Log "aws found manually at: $awsPath"
        Set-Alias -Name aws -Value $awsPath -Scope Global
    } else {
        Write-Log "ERROR: aws not found anywhere. Listing C:\Program Files\Amazon:"
        Get-ChildItem "C:\Program Files\Amazon" -ErrorAction SilentlyContinue | ForEach-Object { Write-Log "  $_" }
        Write-Log "Listing choco bin:"
        Get-ChildItem "C:\ProgramData\chocolatey\bin" -Filter "aws*" -ErrorAction SilentlyContinue | ForEach-Object { Write-Log "  $_" }
        exit 1
    }
}

# Diagnose IAM identity
Write-Log "Checking IAM identity..."
$iamOut = & aws sts get-caller-identity --region $AwsRegion 2>&1
Write-Log "IAM identity result: $iamOut"
if ($LASTEXITCODE -ne 0) {
    Write-Log "ERROR: IAM identity check failed - instance may not have an IAM role attached"
    exit 1
}

try {
    $SecretRaw = aws secretsmanager get-secret-value `
        --region $AwsRegion `
        --secret-id $GithubPatSecretName `
        --query SecretString `
        --output text 2>&1

    Write-Log "Raw secret output: $SecretRaw"

    if ($LASTEXITCODE -ne 0) {
        Write-Log "ERROR: aws secretsmanager exited with code $LASTEXITCODE"
        exit 1
    }

    # Secret may be a raw token or JSON like {"token":"ghp_..."}
    try {
        $ACCESS_TOKEN = ($SecretRaw | ConvertFrom-Json).token
    } catch {
        $ACCESS_TOKEN = $SecretRaw.Trim()
    }
} catch {
    Write-Log "ERROR: Failed to fetch PAT from Secrets Manager: $_"
    exit 1
}

if ([string]::IsNullOrWhiteSpace($ACCESS_TOKEN)) {
    Write-Log "ERROR: PAT is empty after fetching."
    exit 1
}
Write-Log "PAT fetched successfully."

# ---------------------------------------------------------------------------
# 4. Resolve runner name from EC2 instance tag
# ---------------------------------------------------------------------------
Write-Log "=== Resolving runner name from instance tag ==="
$INSTANCE_ID = Get-IMDSValue "instance-id"
$REGION      = Get-IMDSValue "placement/region"

try {
    $TagValue = aws ec2 describe-tags `
        --region $REGION `
        --filters "Name=resource-id,Values=$INSTANCE_ID" "Name=key,Values=RunnerName" `
        --query "Tags[0].Value" `
        --output text 2>&1
    $RUNNER_NAME = $TagValue.Trim()
} catch {
    $RUNNER_NAME = ""
}

$FallbackName = "win"
if ([string]::IsNullOrWhiteSpace($RUNNER_NAME) -or
    $RUNNER_NAME -eq "None" -or
    $RUNNER_NAME -eq "__FROM_TAG__") {
    $RUNNER_NAME = $FallbackName + "-" + $INSTANCE_ID
}
Write-Log "Runner name: $RUNNER_NAME"

# ---------------------------------------------------------------------------
# 5. Download the latest GitHub Actions runner
# ---------------------------------------------------------------------------
Write-Log "=== Downloading GitHub Actions Runner ==="
$RunnerDir = "C:\actions-runner"
New-Item -ItemType Directory -Force -Path $RunnerDir | Out-Null

$ReleasesJson = Invoke-RestMethod `
    -Uri "https://api.github.com/repos/actions/runner/releases/latest" `
    -Headers @{ "User-Agent" = "github-runner-bootstrap" }
$RunnerVersion = $ReleasesJson.tag_name.TrimStart("v")
Write-Log "Runner version: $RunnerVersion"

$RunnerUrl = "https://github.com/actions/runner/releases/download/" +
             "v$RunnerVersion/actions-runner-win-x64-$RunnerVersion.zip"
$RunnerZip = Join-Path $env:TEMP "runner.zip"

Write-Log "Downloading $RunnerUrl ..."
Invoke-WebRequest -Uri $RunnerUrl -OutFile $RunnerZip -UseBasicParsing
Expand-Archive -Path $RunnerZip -DestinationPath $RunnerDir -Force
Remove-Item $RunnerZip
Write-Log "Runner extracted to $RunnerDir."

# ---------------------------------------------------------------------------
# 6. Obtain a runner registration token via GitHub API
# ---------------------------------------------------------------------------
Write-Log "=== Obtaining runner registration token ==="
$RunnerScope = "org"
$OrgName     = "py-libp2p-runners"
$RepoUrl     = ""
$Labels      = "self-hosted,windows,x64"

$AuthHeaders = @{
    Authorization          = "Bearer $ACCESS_TOKEN"
    Accept                 = "application/vnd.github+json"
    "X-GitHub-Api-Version" = "2022-11-28"
}

if ($RunnerScope -eq "org") {
    $TokenApiUrl = "https://api.github.com/orgs/$OrgName/actions/runners/registration-token"
} else {
    $UriParts    = ([System.Uri]$RepoUrl).AbsolutePath.Trim("/").Split("/")
    $Owner       = $UriParts[0]
    $Repo        = $UriParts[1]
    $TokenApiUrl = "https://api.github.com/repos/$Owner/$Repo/actions/runners/registration-token"
}

$RegResponse = Invoke-RestMethod -Uri $TokenApiUrl -Method POST -Headers $AuthHeaders
$REG_TOKEN   = $RegResponse.token

if ([string]::IsNullOrWhiteSpace($REG_TOKEN)) {
    Write-Log "ERROR: Failed to obtain registration token."
    exit 1
}
Write-Log "Registration token obtained."

# ---------------------------------------------------------------------------
# 7. Configure the runner (ephemeral, unattended)
# ---------------------------------------------------------------------------
Write-Log "=== Configuring runner ==="
if ($RunnerScope -eq "org") {
    $ConfigUrl = "https://github.com/$OrgName"
} else {
    $ConfigUrl = $RepoUrl
}

Push-Location $RunnerDir
& .\config.cmd `
    --url         $ConfigUrl `
    --token       $REG_TOKEN `
    --name        $RUNNER_NAME `
    --labels      $Labels `
    --runnergroup "Default" `
    --work        "_work" `
    --ephemeral `
    --unattended `
    --replace
Pop-Location
Write-Log "Runner configured (ephemeral)."

# ---------------------------------------------------------------------------
# 8. Write the wrapper script (runs runner then self-terminates instance)
# ---------------------------------------------------------------------------
Write-Log "=== Writing wrapper script ==="
$WrapperPath = "C:\ProgramData\github-runner-wrapper.ps1"
$WrapperContent = @'
# Runs the GitHub Actions runner then terminates the EC2 instance.
Set-StrictMode -Version Latest

function Get-IMDSToken2 {
    $h = @{ "X-aws-ec2-metadata-token-ttl-seconds" = "21600" }
    Invoke-RestMethod -Uri "http://169.254.169.254/latest/api/token" `
                      -Method PUT -Headers $h -TimeoutSec 5
}
function Get-IMDSValue2 ([string]$Path) {
    $tok = Get-IMDSToken2
    Invoke-RestMethod -Uri "http://169.254.169.254/latest/meta-data/$Path" `
                      -Headers @{ "X-aws-ec2-metadata-token" = $tok } -TimeoutSec 5
}

$INSTANCE_ID = Get-IMDSValue2 "instance-id"
$REGION      = Get-IMDSValue2 "placement/region"

Write-Host "[wrapper] Starting runner on instance $INSTANCE_ID"

$RunnerDir = "C:\actions-runner"
Push-Location $RunnerDir
try {
    & .\run.cmd
    $RunnerExit = $LASTEXITCODE
} catch {
    $RunnerExit = 1
} finally {
    Pop-Location
}

Write-Host "[wrapper] Runner exited with code $RunnerExit. Terminating instance $INSTANCE_ID ..."
aws ec2 terminate-instances --region $REGION --instance-ids $INSTANCE_ID
'@
Set-Content -Path $WrapperPath -Value $WrapperContent -Encoding UTF8
Write-Log "Wrapper script written to $WrapperPath."

# ---------------------------------------------------------------------------
# 9. Start the runner directly (ephemeral - runs one job then exits)
# ---------------------------------------------------------------------------
Write-Log "=== Starting runner (ephemeral mode) ==="
Push-Location $RunnerDir
& .\run.cmd
$runnerExit = $LASTEXITCODE
Pop-Location
Write-Log "Runner exited with code $runnerExit."

# ---------------------------------------------------------------------------
# 10. Self-terminate the EC2 instance after job completes
# ---------------------------------------------------------------------------
Write-Log "=== Runner finished. Terminating instance ==="
$INSTANCE_ID = Get-IMDSValue "instance-id"
$REGION      = Get-IMDSValue "placement/region"
Write-Log "Terminating instance $INSTANCE_ID in $REGION..."
& aws ec2 terminate-instances --region $REGION --instance-ids $INSTANCE_ID
Write-Log "=== Done ==="