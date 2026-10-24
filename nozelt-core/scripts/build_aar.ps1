# Builds nozelt.aar from the .\binding package via gomobile.
#
# Usage:
#   .\scripts\build_aar.ps1              # release build
#   .\scripts\build_aar.ps1 -DebugBuild  # unoptimized build with symbols

param(
    [switch]$DebugBuild
)

$ErrorActionPreference = 'Stop'

# -------- environment checks --------

$goCmd = Get-Command go -ErrorAction SilentlyContinue
if (-not $goCmd) {
    Write-Error "'go' not found in PATH. Install Go 1.22+."
    exit 1
}

$goVersionOutput = (& go version)
if ($goVersionOutput -notmatch 'go(\d+)\.(\d+)') {
    Write-Error "could not parse 'go version' output: $goVersionOutput"
    exit 1
}
$goMajor = [int]$Matches[1]
$goMinor = [int]$Matches[2]
if (($goMajor -lt 1) -or (($goMajor -eq 1) -and ($goMinor -lt 22))) {
    Write-Error "Go $goMajor.$goMinor detected; need >= 1.22."
    exit 1
}

$gomobileCmd = Get-Command gomobile -ErrorAction SilentlyContinue
if (-not $gomobileCmd) {
    Write-Error @"
'gomobile' not found in PATH.
install:
    go install golang.org/x/mobile/cmd/gomobile@latest
    go install golang.org/x/mobile/cmd/gobind@latest
    gomobile init
"@
    exit 1
}

if (-not ($env:ANDROID_NDK_HOME -or $env:ANDROID_NDK_ROOT -or $env:NDK_HOME)) {
    Write-Warning "ANDROID_NDK_HOME / ANDROID_NDK_ROOT / NDK_HOME not set. gomobile may fail if it cannot locate the NDK."
}

# -------- build --------

$projectRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$buildDir    = Join-Path $projectRoot 'build'
$output      = Join-Path $buildDir 'nozelt.aar'

if (-not (Test-Path $buildDir)) {
    New-Item -ItemType Directory -Path $buildDir | Out-Null
}

$gomobileArgs = @(
    'bind',
    '-target=android/arm64,android/arm',
    '-androidapi=24',
    # Android app embedding mode. Without this tag mihomo tries to read
    # /data/system/packages.xml, which is forbidden to ordinary VpnService
    # apps. Nozelt owns per-app routing through VpnService.Builder instead.
    '-tags=cmfa,with_gvisor',
    '-o', $output
)

if ($DebugBuild) {
    # Leave symbol table in; disable inlining/optimizations for readable stack
    # traces in logcat.
    $gomobileArgs += @('-ldflags=', '-gcflags=all=-N -l')
    Write-Host 'building DEBUG nozelt.aar ...'
} else {
    # -s -w strips symbol/debug tables; -trimpath gives reproducible builds.
    $gomobileArgs += @('-ldflags=-s -w', '-trimpath')
    Write-Host 'building RELEASE nozelt.aar ...'
}

$gomobileArgs += '.\binding'

Push-Location $projectRoot
try {
    & gomobile @gomobileArgs
    if ($LASTEXITCODE -ne 0) {
        Write-Error "gomobile bind failed with exit code $LASTEXITCODE"
        exit $LASTEXITCODE
    }
} finally {
    Pop-Location
}

# -------- report --------

if (-not (Test-Path $output)) {
    Write-Error "build reported success but $output is missing."
    exit 1
}

$sizeBytes = (Get-Item $output).Length
$sizeMb    = [math]::Round($sizeBytes / 1MB, 2)
Write-Host "built: $output ($sizeMb MB)"
