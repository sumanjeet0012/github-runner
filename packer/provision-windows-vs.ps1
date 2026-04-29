# =============================================================================
# provision-windows-vs.ps1 - Step 9 only: Visual Studio Build Tools
# Run in a SEPARATE Packer provisioner block to avoid WinRM EOF.
# The VS installer spawns background processes that drop the WinRM session,
# so it must run in its own provisioner to get a fresh connection afterward.
# =============================================================================
Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
Set-ExecutionPolicy Bypass -Scope Process -Force

function Log { param([string]$Msg); Write-Host ""; Write-Host ">>> $Msg"; Write-Host "" }

Log "9/14  Visual Studio Build Tools (C++ workload for Rust MSVC)"

choco install -y --no-progress visualstudio2022buildtools `
    --package-parameters "--add Microsoft.VisualStudio.Workload.VCTools --add Microsoft.VisualStudio.Component.Windows11SDK.22621 --add Microsoft.VisualStudio.Component.VC.Tools.x86.x64 --includeRecommended --quiet --norestart"

Write-Host "VS Build Tools installed."
