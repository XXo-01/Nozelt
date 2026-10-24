param(
    [ValidateSet("debug", "release")]
    [string]$Mode = "debug"
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$appRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$outputDir = Join-Path $appRoot "build\app\outputs\flutter-apk"

# Flutter/Gradle do not remove outputs from earlier ABI/build-mode variants.
# Delete only APK artifacts for the requested mode so nobody accidentally
# installs or publishes a stale universal/x86 package after a successful ARM
# split build. The path is fixed underneath this script's own app workspace.
if (Test-Path -LiteralPath $outputDir) {
    $modePattern = if ($Mode -eq "release") {
        '^app-(?:.+-)?release(?:-unsigned)?\.apk(?:\.sha1)?$'
    } else {
        '^app-(?:.+-)?debug\.apk(?:\.sha1)?$'
    }
    Get-ChildItem -LiteralPath $outputDir -File |
        Where-Object { $_.Name -match $modePattern } |
        ForEach-Object { Remove-Item -LiteralPath $_.FullName -Force }
}

Push-Location $appRoot
try {
    & flutter build apk "--$Mode" --split-per-abi `
        --target-platform android-arm,android-arm64
    if ($LASTEXITCODE -ne 0) {
        throw "Flutter Android APK build failed with exit code $LASTEXITCODE"
    }
} finally {
    Pop-Location
}
