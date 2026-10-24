[CmdletBinding()]
param(
    [string]$XrayVersion = '26.9.30',
    [string]$XraySourceDirectory = '',
    [string]$XrayGoToolchain = 'go1.27.1',
    [string]$SingBoxGoToolchain = 'go1.26.8',
    [switch]$SkipTests
)

$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot
$output = Join-Path $root 'build\windows'
$runner = Join-Path $root 'singbox-runner'
$wintunVersion = '0.14.1'
$wintunHash = '07c256185d6ee3652e09fa55c0b673e2624b565e02c4b9091c79ca7d2f24ef51'
$previousToolchain = $env:GOTOOLCHAIN
$previousCgo = $env:CGO_ENABLED

try {

New-Item -ItemType Directory -Force -Path $output | Out-Null

Push-Location $runner
try {
    $env:GOTOOLCHAIN = $SingBoxGoToolchain
    if (-not $SkipTests) {
        go test ./...
        if ($LASTEXITCODE -ne 0) { throw 'sing-box runner tests failed.' }
    }
    $env:CGO_ENABLED = '0'
    # Keep protocol and TUN capabilities aligned with the Android runner.
    # Omitting these tags produces a binary that parses common Hysteria2,
    # WireGuard, uTLS and gVisor profiles but fails when creating the core.
    go build -trimpath `
        -tags 'with_gvisor,with_quic,with_wireguard,with_utls,with_clash_api' `
        -ldflags='-s -w' `
        -o (Join-Path $output 'singbox-runner.exe') .
    if ($LASTEXITCODE -ne 0) { throw 'sing-box runner build failed.' }
}
finally {
    Pop-Location
}

if ([string]::IsNullOrWhiteSpace($XraySourceDirectory)) {
    # Xray uses date tags (v26.*), which are incompatible with Go's semantic
    # module-major rules. Fetch the official tagged source archive instead.
    $sourceArchive = Join-Path $env:TEMP "nozelt-xray-$XrayVersion.zip"
    $sourceRoot = Join-Path $env:TEMP "nozelt-xray-source-$XrayVersion"
    $XraySourceDirectory = Join-Path $sourceRoot "Xray-core-$XrayVersion"
    if (-not (Test-Path (Join-Path $XraySourceDirectory 'go.mod'))) {
        & curl.exe --fail --http1.1 --retry 2 --connect-timeout 15 --max-time 120 -L `
            "https://codeload.github.com/XTLS/Xray-core/zip/refs/tags/v$XrayVersion" -o $sourceArchive
        if ($LASTEXITCODE -ne 0) { throw 'Xray tagged source download failed.' }
        Expand-Archive -LiteralPath $sourceArchive -DestinationPath $sourceRoot -Force
    }
}
if (-not (Test-Path (Join-Path $XraySourceDirectory 'go.mod'))) {
    git clone --depth 1 --branch "v$XrayVersion" `
        https://github.com/XTLS/Xray-core.git $XraySourceDirectory
    if ($LASTEXITCODE -ne 0) { throw 'Xray source checkout failed.' }
}
Push-Location $XraySourceDirectory
try {
    $env:GOTOOLCHAIN = $XrayGoToolchain
    $env:CGO_ENABLED = '0'
    # Security patch overlay on the tagged source; checksum verification is
    # provided by Go's module sum database. Keep these versions reproducible.
    go get google.golang.org/grpc@v1.85.0-dev.0.20260825072537-93e31b48545e github.com/klauspost/compress@v1.18.7
    if ($LASTEXITCODE -ne 0) { throw 'Xray security dependency update failed.' }
    go build -trimpath -buildvcs=false -ldflags='-s -w -buildid=' `
        -o (Join-Path $output 'xray.exe') .\main
    if ($LASTEXITCODE -ne 0) { throw 'Xray build failed.' }
}
finally {
    Pop-Location
}

$archive = Join-Path $env:TEMP "wintun-$wintunVersion.zip"
Invoke-WebRequest `
    -Uri "https://www.wintun.net/builds/wintun-$wintunVersion.zip" `
    -OutFile $archive
$actualHash = (Get-FileHash -Algorithm SHA256 $archive).Hash.ToLowerInvariant()
if ($actualHash -ne $wintunHash) {
    throw "Wintun archive checksum mismatch: $actualHash"
}
$extract = Join-Path $env:TEMP ("nozelt-wintun-" + [guid]::NewGuid().ToString('N'))
Expand-Archive -LiteralPath $archive -DestinationPath $extract
Copy-Item -LiteralPath (Join-Path $extract 'wintun\bin\amd64\wintun.dll') `
    -Destination (Join-Path $output 'wintun.dll') -Force

Write-Host "Built Windows native cores in $output"
}
finally {
    $env:GOTOOLCHAIN = $previousToolchain
    $env:CGO_ENABLED = $previousCgo
}
