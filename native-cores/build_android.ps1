#requires -Version 5.1
param(
    [string]$AndroidApi = '24',
    [string]$NdkVersion = '28.2.13676358',
    [ValidateSet('all', 'xray', 'singbox')]
    [string]$Core = 'all',
    [string]$XrayVersion = 'v26.9.9',
    [string]$XrayGoToolchain = 'go1.27.1',
    [string]$SingBoxGoToolchain = 'go1.25.6'
)

$ErrorActionPreference = 'Stop'

$Root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$AppJni = Join-Path $Root 'nozelt-app\android\app\src\main\jniLibs'
$Runner = Join-Path $PSScriptRoot 'singbox-runner'
$AndroidSdk = if ($env:ANDROID_HOME) {
    $env:ANDROID_HOME
} elseif ($env:ANDROID_SDK_ROOT) {
    $env:ANDROID_SDK_ROOT
} else {
    Join-Path $env:LOCALAPPDATA 'Android\Sdk'
}
$Ndk = if ($env:ANDROID_NDK_HOME) {
    $env:ANDROID_NDK_HOME
} else {
    Join-Path $AndroidSdk "ndk\$NdkVersion"
}
$Toolchain = Join-Path $Ndk 'toolchains\llvm\prebuilt\windows-x86_64\bin'
if (-not (Test-Path $Toolchain)) {
    throw "Android NDK toolchain was not found at $Toolchain"
}

$XraySource = Join-Path $env:TEMP "nozelt-xray-core-$($XrayVersion.TrimStart('v'))"
if ($Core -in @('all', 'xray') -and -not (Test-Path (Join-Path $XraySource '.git'))) {
    if (Test-Path $XraySource) {
        throw "$XraySource exists but is not the expected Git checkout; move it first"
    }
    git clone --depth 1 --branch $XrayVersion https://github.com/XTLS/Xray-core.git $XraySource
    if ($LASTEXITCODE -ne 0) {
        throw "Could not clone Xray-core $XrayVersion"
    }
}

$Targets = @(
    @{
        Abi = 'arm64-v8a'
        GoArch = 'arm64'
        GoArm = ''
        Cc = "aarch64-linux-android$AndroidApi-clang.cmd"
    },
    @{
        Abi = 'armeabi-v7a'
        GoArch = 'arm'
        GoArm = '7'
        Cc = "armv7a-linux-androideabi$AndroidApi-clang.cmd"
    }
)

foreach ($Target in $Targets) {
    $Destination = Join-Path $AppJni $Target.Abi
    New-Item -ItemType Directory -Path $Destination -Force | Out-Null
    $env:GOOS = 'android'
    $env:GOARCH = $Target.GoArch
    $env:GOARM = $Target.GoArm
    $env:CGO_ENABLED = '1'
    $env:CC = Join-Path $Toolchain $Target.Cc
    if ($Core -in @('all', 'xray')) {
        # Xray v26.9.9 requires Go 1.27.
        $env:GOTOOLCHAIN = $XrayGoToolchain
        Push-Location $XraySource
        try {
            # Xray's Android release workflow deliberately permits the
            # anet/net zone-cache linkname used to enumerate interfaces on
            # modern Android. Match that official build contract.
            go build -buildmode=pie -trimpath -buildvcs=false `
                -gcflags 'all=-l=4' `
                -ldflags '-s -w -buildid= -checklinkname=0' `
                -o (Join-Path $Destination 'libxray_exec.so') .\main
            if ($LASTEXITCODE -ne 0) {
                throw "Xray build failed for $($Target.Abi)"
            }
        } finally {
            Pop-Location
        }
    }

    if ($Core -in @('all', 'singbox')) {
        # The pinned gVisor revision bundled by sing-box targets Go
        # 1.25. Go's version build tags are cumulative, so compiling it with
        # Go 1.26 selects incompatible go1.25 and go1.26 runtime files.
        $env:GOTOOLCHAIN = $SingBoxGoToolchain
        Push-Location $Runner
        try {
            go build -buildmode=pie -trimpath `
                -tags 'with_gvisor,with_quic,with_wireguard,with_utls,with_clash_api' `
                -ldflags '-s -w' `
                -o (Join-Path $Destination 'libsingbox_exec.so') .
            if ($LASTEXITCODE -ne 0) {
                throw "sing-box build failed for $($Target.Abi)"
            }
        } finally {
            Pop-Location
        }
    }
}

Remove-Item Env:GOOS, Env:GOARCH, Env:GOARM, Env:CGO_ENABLED, Env:CC, Env:GOTOOLCHAIN `
    -ErrorAction SilentlyContinue
$built = switch ($Core) {
    'xray' { "Xray $XrayVersion" }
    'singbox' { 'sing-box' }
    default { "Xray $XrayVersion and sing-box" }
}
Write-Host "$built Android cores were built successfully."
