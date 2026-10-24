[CmdletBinding()]
param(
    [switch]$SkipTests,
    [switch]$SkipCore
)

$ErrorActionPreference = 'Stop'
$appRoot = Split-Path -Parent $PSScriptRoot
$workspaceRoot = Split-Path -Parent $appRoot
$coreScript = Join-Path $workspaceRoot 'nozelt-core\scripts\build_windows_dll.ps1'
$portableRoot = Join-Path $appRoot 'build\portable'
$portableDirectory = Join-Path $portableRoot 'Nozelt'
$archive = Join-Path $portableRoot 'Nozelt-windows-x64-portable.zip'
$portableRootFull = [IO.Path]::GetFullPath($portableRoot)
$portableDirectoryFull = [IO.Path]::GetFullPath($portableDirectory)
if (-not $portableDirectoryFull.StartsWith(
        $portableRootFull + [IO.Path]::DirectorySeparatorChar,
        [StringComparison]::OrdinalIgnoreCase
    ) -or (Split-Path -Leaf $portableDirectoryFull) -ne 'Nozelt') {
    throw 'Unsafe portable output path.'
}

Push-Location $appRoot
try {
    if (-not $SkipCore) {
        & (Join-Path $workspaceRoot 'native-cores\build_windows.ps1')
        if ($LASTEXITCODE -ne 0) { throw 'Native core build failed.' }
        & $coreScript -SkipTests:$SkipTests
        if ($LASTEXITCODE -ne 0) { throw 'Core build failed.' }
    }
    if (-not $SkipTests) {
        flutter analyze
        if ($LASTEXITCODE -ne 0) { throw 'Flutter analysis failed.' }
        flutter test
        if ($LASTEXITCODE -ne 0) { throw 'Flutter tests failed.' }
    }

    flutter build windows --release
    if ($LASTEXITCODE -ne 0) { throw 'Flutter Windows build failed.' }

    $releaseDirectory = Join-Path $appRoot 'build\windows\x64\runner\Release'
    if (-not (Test-Path (Join-Path $releaseDirectory 'nozelt.exe'))) {
        throw "Windows release output was not found at $releaseDirectory"
    }

    New-Item -ItemType Directory -Force -Path $portableRoot | Out-Null
    if (Test-Path $portableDirectory) {
        Remove-Item -LiteralPath $portableDirectory -Recurse -Force
    }
    New-Item -ItemType Directory -Path $portableDirectory -Force | Out-Null
    # Never distribute the encrypted profiles/settings of a previous local run.
    Get-ChildItem -LiteralPath $releaseDirectory |
        Where-Object { $_.Name -ne 'portable-data' } |
        ForEach-Object { Copy-Item -LiteralPath $_.FullName -Destination $portableDirectory -Recurse }
    # App-local Microsoft redistributables keep the bundle usable on a fresh PC.
    $vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
    $vsRoot = & $vswhere -latest -products '*' -property installationPath
    if (-not $vsRoot) { throw 'Visual Studio redist directory not found.' }
    $crt = Get-ChildItem -LiteralPath (Join-Path $vsRoot 'VC\Redist\MSVC') -Directory |
        Sort-Object Name -Descending |
        ForEach-Object { Join-Path $_.FullName 'x64\Microsoft.VC143.CRT' } |
        Where-Object { Test-Path (Join-Path $_ 'vcruntime140_1.dll') } |
        Select-Object -First 1
    if (-not $crt) { throw 'x64 Microsoft Visual C++ redistributables not found.' }
    Copy-Item -Path (Join-Path $crt '*.dll') -Destination $portableDirectory
    Copy-Item -LiteralPath (Join-Path $appRoot 'WINDOWS_PORTABLE.md') -Destination $portableDirectory
    Copy-Item -LiteralPath (Join-Path $appRoot 'WINDOWS_UI_AUDIT.md') -Destination $portableDirectory
    Copy-Item -LiteralPath (Join-Path $appRoot 'WINDOWS_SECURITY_AUDIT.md') -Destination $portableDirectory
    Copy-Item -LiteralPath (Join-Path $appRoot 'WINDOWS_DEFENDER.md') -Destination $portableDirectory
    Copy-Item -LiteralPath (Join-Path $appRoot 'WINDOWS_DNS_TUN.md') -Destination $portableDirectory
    # A prior successful ZIP must not masquerade as the output of this build.
    if (Test-Path -LiteralPath $archive) {
        Move-Item -LiteralPath $archive -Destination ($archive + '.previous-' + [guid]::NewGuid().ToString('N'))
    }
    & (Join-Path $PSScriptRoot 'test_windows_release.ps1') `
        -BundleDirectory $portableDirectory `
        -ReportPath (Join-Path $portableRoot 'candidate-static-check.json')
    Write-Host "Candidate bundle: $portableDirectory"
    Write-Host 'No distributable ZIP was published. Open this candidate without TUN, then run test_windows_release.ps1 with its process ID.'
    Write-Host 'After post-launch verification, run publish_windows_portable.ps1. See WINDOWS_DEFENDER.md.'
}
finally {
    Pop-Location
}
