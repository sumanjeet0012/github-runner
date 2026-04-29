# GitHub Actions self-hosted runner bootstrap for Windows Server.
# Template variables injected by Terraform templatefile().
# NOTE: <powershell> wrapper tags are added by main.tf around this content.

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$LogFile = "C:\ProgramData\github-runner-init.log"
function Write-Log {
    param([string]$Message)
    $ts   = (Get-Date -Format "yyyy-MM-dd HH:mm:ss")
    $line = "$ts  $Message"
    Write-Host $line
    Add-Content -Path $LogFile -Value $line
}

Write-Log "=== GitHub Actions Runner Bootstrap - Windows Server ==="

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

Write-Log "=== Installing core dependencies (git, jq, awscli) ==="
# NOTE: Most tools are pre-installed in the AMI by Packer (provision-windows.ps1).
# Only install what's strictly needed if somehow missing (fallback safety net).
foreach ($pkg in @("git", "jq", "awscli")) {
    if (-not (Get-Command ($pkg -replace "awscli","aws") -ErrorAction SilentlyContinue)) {
        Write-Log "  Installing $pkg ..."
        choco install $pkg -y --no-progress | Out-Null
    } else {
        Write-Log "  $pkg already present - skipping."
    }
}

$machinePath = [System.Environment]::GetEnvironmentVariable("PATH", "Machine")
$userPath    = [System.Environment]::GetEnvironmentVariable("PATH", "User")
$env:PATH    = $machinePath + ";" + $userPath
foreach ($p in @("C:\Program Files\Amazon\AWSCLIV2", "C:\ProgramData\chocolatey\bin")) {
    if (Test-Path $p) { $env:PATH = $p + ";" + $env:PATH }
}
Write-Log "Core dependencies installed."

Write-Log "=== Fetching GitHub PAT from Secrets Manager ==="
$AwsRegion           = "${aws_region}"
$GithubPatSecretName = "${github_pat_secret_name}"

if (-not (Get-Command aws -ErrorAction SilentlyContinue)) {
    foreach ($c in @("C:\Program Files\Amazon\AWSCLIV2\aws.exe","C:\ProgramData\chocolatey\bin\aws.exe")) {
        if (Test-Path $c) { Set-Alias -Name aws -Value $c -Scope Global; break }
    }
}

$iamOut = & aws sts get-caller-identity --region $AwsRegion 2>&1
Write-Log "IAM identity: $iamOut"
if ($LASTEXITCODE -ne 0) { Write-Log "ERROR: IAM check failed"; exit 1 }

$SecretRaw = aws secretsmanager get-secret-value `
    --region $AwsRegion --secret-id $GithubPatSecretName `
    --query SecretString --output text 2>&1
if ($LASTEXITCODE -ne 0) { Write-Log "ERROR: Secrets Manager failed: $SecretRaw"; exit 1 }
try { $ACCESS_TOKEN = ($SecretRaw | ConvertFrom-Json).token }
catch { $ACCESS_TOKEN = $SecretRaw.Trim() }
if ([string]::IsNullOrWhiteSpace($ACCESS_TOKEN)) { Write-Log "ERROR: PAT is empty."; exit 1 }
Write-Log "PAT fetched successfully."

Write-Log "=== Resolving runner name ==="
$INSTANCE_ID = Get-IMDSValue "instance-id"
$REGION      = Get-IMDSValue "placement/region"
try {
    $TagValue = aws ec2 describe-tags --region $REGION `
        --filters "Name=resource-id,Values=$INSTANCE_ID" "Name=key,Values=RunnerName" `
        --query "Tags[0].Value" --output text 2>&1
    $RUNNER_NAME = $TagValue.Trim()
} catch { $RUNNER_NAME = "" }
if ([string]::IsNullOrWhiteSpace($RUNNER_NAME) -or $RUNNER_NAME -eq "None" -or $RUNNER_NAME -eq "__FROM_TAG__") {
    $RUNNER_NAME = "win-" + $INSTANCE_ID
}
Write-Log "Runner name: $RUNNER_NAME"

Write-Log "=== Downloading GitHub Actions Runner ==="
$RunnerDir = "C:\actions-runner"
if (-not (Test-Path "$RunnerDir\run.cmd")) {
    # Runner not pre-baked — download it now (fallback for non-Packer AMIs)
    New-Item -ItemType Directory -Force -Path $RunnerDir | Out-Null
    $ReleasesJson  = Invoke-RestMethod -Uri "https://api.github.com/repos/actions/runner/releases/latest" `
                                       -Headers @{ "User-Agent" = "github-runner-bootstrap" }
    $RunnerVersion = $ReleasesJson.tag_name.TrimStart("v")
    $RunnerUrl     = "https://github.com/actions/runner/releases/download/v$RunnerVersion/actions-runner-win-x64-$RunnerVersion.zip"
    $RunnerZip     = Join-Path $env:TEMP "runner.zip"
    Write-Log "Downloading runner $RunnerVersion ..."
    Invoke-WebRequest -Uri $RunnerUrl -OutFile $RunnerZip -UseBasicParsing
    Expand-Archive -Path $RunnerZip -DestinationPath $RunnerDir -Force
    Remove-Item $RunnerZip
    Write-Log "Runner extracted to $RunnerDir."
} else {
    Write-Log "Runner already pre-baked in AMI at $RunnerDir - skipping download."
}

Write-Log "=== Obtaining runner registration token ==="
$RunnerScope = "${runner_scope}"
$OrgName     = "${org_name}"
$RepoUrl     = "${repo_url}"
$Labels      = "${runner_labels}"

$AuthHeaders = @{
    Authorization          = "Bearer $ACCESS_TOKEN"
    Accept                 = "application/vnd.github+json"
    "X-GitHub-Api-Version" = "2022-11-28"
}
if ($RunnerScope -eq "org") {
    $TokenApiUrl = "https://api.github.com/orgs/$OrgName/actions/runners/registration-token"
} else {
    $UriParts    = ([System.Uri]$RepoUrl).AbsolutePath.Trim("/").Split("/")
    $TokenApiUrl = "https://api.github.com/repos/$($UriParts[0])/$($UriParts[1])/actions/runners/registration-token"
}
$RegResponse = Invoke-RestMethod -Uri $TokenApiUrl -Method POST -Headers $AuthHeaders
$REG_TOKEN   = $RegResponse.token
if ([string]::IsNullOrWhiteSpace($REG_TOKEN)) { Write-Log "ERROR: No registration token."; exit 1 }
Write-Log "Registration token obtained."

Write-Log "=== Configuring runner ==="
$ConfigUrl = if ($RunnerScope -eq "org") { "https://github.com/$OrgName" } else { $RepoUrl }
Push-Location $RunnerDir
& .\config.cmd --url $ConfigUrl --token $REG_TOKEN --name $RUNNER_NAME `
               --labels $Labels --runnergroup "Default" --work "_work" `
               --ephemeral --unattended --replace
Pop-Location
Write-Log "Runner configured."

Write-Log "=== Checking if job is still active ==="
# Fetch job_id from EC2 instance tag
$JobIdResponse = & aws ec2 describe-tags --region $REGION --filters "Name=resource-id,Values=$INSTANCE_ID" "Name=key,Values=GitHubJobId" --query 'Tags[0].Value' --output text 2>$null
$JobId = if ($null -eq $JobIdResponse -or $JobIdResponse -eq "None") { "" } else { $JobIdResponse }

if ([string]::IsNullOrWhiteSpace($JobId)) {
    Write-Log "WARNING: Could not fetch job_id from EC2 tags. Proceeding anyway."
} else {
    Write-Log "Job ID: $JobId. Checking job status on GitHub..."
    
    # Build GitHub API URL based on runner scope
    if ($RunnerScope -eq "org" -and -not [string]::IsNullOrWhiteSpace($OrgName)) {
        $JobUrl = "https://api.github.com/repos/$OrgName/universal-connectivity/actions/jobs/$JobId"
    } else {
        $UriParts = ([System.Uri]$RepoUrl).AbsolutePath.Trim("/").Split("/")
        $JobUrl = "https://api.github.com/repos/$($UriParts[0])/$($UriParts[1])/actions/jobs/$JobId"
    }
    
    # Query GitHub API for job status
    try {
        $JobResponse = Invoke-RestMethod -Uri $JobUrl -Method GET -Headers $AuthHeaders -ErrorAction Stop
        $JobStatus = $JobResponse.status
        Write-Log "Job status from GitHub: $JobStatus"
        
        # If job is cancelled or completed, don't run it
        if ($JobStatus -eq "completed" -or $JobStatus -eq "cancelled") {
            Write-Log "Job $JobId was $JobStatus. Skipping runner execution."
            Write-Log "Terminating instance $INSTANCE_ID ..."
            & aws ec2 terminate-instances --region $REGION --instance-ids $INSTANCE_ID
            Write-Log "=== Done ==="
            exit 0
        } elseif ($JobStatus -eq "in_progress" -or $JobStatus -eq "queued") {
            Write-Log "Job is $JobStatus. Safe to proceed."
        } else {
            Write-Log "WARNING: Unexpected job status '$JobStatus'. Proceeding anyway."
        }
    } catch {
        Write-Log "WARNING: Could not query job status: $_. Proceeding anyway."
    }
}

Write-Log "=== Starting runner ==="
Push-Location $RunnerDir
& .\run.cmd
$runnerExit = $LASTEXITCODE
Pop-Location
Write-Log "Runner exited with code $runnerExit."

Write-Log "=== Terminating instance ==="
& aws ec2 terminate-instances --region $REGION --instance-ids $INSTANCE_ID
Write-Log "=== Done ==="
