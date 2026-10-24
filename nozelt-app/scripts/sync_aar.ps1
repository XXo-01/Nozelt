#requires -Version 5.1
<#
.SYNOPSIS
    Copies the nozelt-core .aar artifact into the Flutter Android module.

.DESCRIPTION
    Run this after rebuilding nozelt-core. The .aar is intentionally not
    committed to VCS; this script is the supported way to refresh it.
#>

$ErrorActionPreference = 'Stop'

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$AppRoot   = Resolve-Path (Join-Path $ScriptDir '..')
$Src       = Join-Path $AppRoot '..\nozelt-core\build\nozelt.aar'
$DestDir   = Join-Path $AppRoot 'android\app\libs'
$Dest      = Join-Path $DestDir 'nozelt.aar'

if (-not (Test-Path $Src)) {
    Write-Error @"
$Src not found.

Build the core library first:
  cd ..\nozelt-core
  .\scripts\build_aar.ps1
"@
    exit 1
}

if (-not (Test-Path $DestDir)) {
    New-Item -ItemType Directory -Path $DestDir | Out-Null
}

Copy-Item -Path $Src -Destination $Dest -Force

$size = (Get-Item $Dest).Length
Write-Host "synced $Src -> $Dest ($size bytes)"
