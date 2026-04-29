# =============================================================================
# provision-windows-vs.ps1 - Step 9 only: Visual Studio Build Tools
# Run in a SEPARATE Packer provisioner block to avoid WinRM EOF.
# The VS installer spawns background processes that drop the WinRM session,
# so it must run in its own provisioner to get a fresh connection afterward.
# =============================================================================
Set-StrictMode -Version Latest
$ErrorActionPreference = "Continue"
Set-ExecutionPolicy Bypass -Scope Process -Force

function Log { param([string]$Msg); Write-Host ""; Write-Host ">>> $Msg"; Write-Host "" }

# Ensure Chocolatey is on PATH (installed by provision-windows.ps1)
$env:ChocolateyInstall = 'C:\ProgramData\chocolatey'
$env:PATH = "C:\ProgramData\chocolatey\bin;$env:PATH"

Log "9/14  Visual Studio Build Tools (C++ workload for Rust MSVC)"

# Download vs_BuildTools.exe directly (bypass Chocolatey wrapper which detaches the process)
$vsExe = "$env:TEMP\vs_BuildTools.exe"
Write-Host "Downloading vs_BuildTools.exe..."
Invoke-WebRequest `
    -Uri "https://aka.ms/vs/17/release/vs_BuildTools.exe" `
    -OutFile $vsExe -UseBasicParsing
Write-Host "Download complete. Starting installation..."

# Run synchronously with Start-Process -Wait so WinRM session stays alive
$proc = Start-Process -FilePath $vsExe -ArgumentList @(
    "--quiet", "--norestart", "--wait",
    "--add", "Microsoft.VisualStudio.Workload.VCTools",
    "--add", "Microsoft.VisualStudio.Component.Windows11SDK.22621",
    "--add", "Microsoft.VisualStudio.Component.VC.Tools.x86.x64",
    "--includeRecommended"
) -Wait -PassThru

$exitCode = $proc.ExitCode
Write-Host "vs_BuildTools.exe exit code: $exitCode"
Remove-Item $vsExe -ErrorAction SilentlyContinue

if ($exitCode -ne 0 -and $exitCode -ne 3010) {
    Write-Error "VS Build Tools installation failed with exit code $exitCode"
    exit $exitCode
}
Write-Host "VS Build Tools installed successfully (exit code $exitCode)."
