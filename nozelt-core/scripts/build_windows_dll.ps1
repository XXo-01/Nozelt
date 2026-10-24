[CmdletBinding()]
param(
    [ValidateSet('amd64')]
    [string]$Architecture = 'amd64',
    [switch]$SkipTests
)

$ErrorActionPreference = 'Stop'
$coreRoot = Split-Path -Parent $PSScriptRoot
$outputDirectory = Join-Path $coreRoot 'build\windows'
$output = Join-Path $outputDirectory 'nozelt_core.dll'
$previousPath = $env:Path
$previousGoos = $env:GOOS
$previousGoarch = $env:GOARCH
$previousCgo = $env:CGO_ENABLED

Push-Location $coreRoot
try {
    if (-not (Get-Command gcc -ErrorAction SilentlyContinue)) {
        $mingw = 'C:\msys64\mingw64\bin'
        if (-not (Test-Path (Join-Path $mingw 'gcc.exe'))) {
            throw 'MinGW-w64 gcc was not found.'
        }
        $env:Path = "$mingw;$env:Path"
    }

    New-Item -ItemType Directory -Force -Path $outputDirectory | Out-Null
    $env:GOOS = 'windows'
    $env:GOARCH = $Architecture
    $env:CGO_ENABLED = '1'
    if (-not $SkipTests) {
        go test -tags=with_gvisor ./...
        if ($LASTEXITCODE -ne 0) { throw 'Go tests failed.' }
    }
    go build -tags=with_gvisor -trimpath -buildmode=c-shared -ldflags='-s -w' `
        -o $output ./windowsdll
    if ($LASTEXITCODE -ne 0) { throw 'Windows core build failed.' }
    go build -trimpath -ldflags='-s -w' -o (Join-Path $outputDirectory 'nozelt-network-recovery.exe') ./cmd/network-recovery
    if ($LASTEXITCODE -ne 0) { throw 'Windows network recovery tool build failed.' }
    Write-Host "Built $output"
}
finally {
    $env:Path = $previousPath
    $env:GOOS = $previousGoos
    $env:GOARCH = $previousGoarch
    $env:CGO_ENABLED = $previousCgo
    Pop-Location
}
