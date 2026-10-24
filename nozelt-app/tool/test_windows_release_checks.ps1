# Synthetic fixtures only: never launch an EXE, modify Defender, or touch a VPN.
$ErrorActionPreference = 'Stop'
$scripts = Join-Path (Split-Path -Parent $PSScriptRoot) 'scripts'
. (Join-Path $scripts 'windows_release_checks.ps1')
function Get-NozeltDefenderStatus {
    [pscustomobject]@{SignatureVersion='fixture-v1';EngineVersion='fixture-engine';PlatformVersion='fixture-platform'}
}
$fixtures = Join-Path ([IO.Path]::GetTempPath()) ('nozelt-release-checks-' + [guid]::NewGuid().ToString('N'))
$bundle = Join-Path $fixtures 'bundle'
New-Item -ItemType Directory -Path $bundle -Force | Out-Null
[IO.File]::WriteAllText((Join-Path $bundle 'nozelt.exe'), 'Synthetic test fixture; this is not executable code.')
[IO.File]::WriteAllText((Join-Path $bundle 'nozelt_core.dll'), 'Synthetic library fixture.')
$script:passed = 0
function Expect-Rejection([string]$Name, [scriptblock]$Action, [string]$Message) {
    $rejected = $false
    try { & $Action | Out-Null } catch {
        if ($_.Exception.Message -notlike ('*' + $Message + '*')) { throw "Wrong rejection in ${Name}: $($_.Exception.Message)" }
        $rejected = $true
    }
    if (-not $rejected) { throw "Unsafe acceptance: $Name" }
    $script:passed++
}
function New-FixtureReceipt {
    [pscustomobject]@{
        Schema=1; Result='passed'; ObservationSeconds=180; WindowObserved=$true
        StaticScanPassed=$true; Detections=@(); VerifiedUtc=[DateTime]::UtcNow.ToString('o')
        Defender=(Get-NozeltDefenderStatus)
        RuntimeFingerprint=(Get-NozeltRuntimeFingerprint (Get-NozeltRuntimeFiles $bundle))
    }
}
function Write-FixtureReceipt($Value) {
    $Value | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $bundle 'release-verification.json') -Encoding UTF8
}
Expect-Rejection 'missing receipt' { Assert-NozeltReleaseReceipt $bundle } 'no post-launch'
$receipt = New-FixtureReceipt
Write-FixtureReceipt $receipt
$null = Assert-NozeltReleaseReceipt $bundle
$script:passed++
$orderedFiles=@(Get-NozeltRuntimeFiles $bundle)
$expectedFingerprint=Get-NozeltRuntimeFingerprint $orderedFiles
[Array]::Reverse($orderedFiles)
if ((Get-NozeltRuntimeFingerprint $orderedFiles) -ne $expectedFingerprint) { throw 'Fingerprint depends on input sorting/collation' }
$script:passed++
# The updater must not install just an EXE while retaining an incompatible DLL.
$completeManifest=@(Get-NozeltRuntimeFiles $bundle | ForEach-Object { [pscustomobject]@{path=$_.File;sha256=$_.SHA256} })
Assert-NozeltUpdateManifest $bundle $completeManifest
$script:passed++
Expect-Rejection 'partial runtime manifest' { Assert-NozeltUpdateManifest $bundle @($completeManifest[0]) } 'complete verified runtime'
Expect-Rejection 'duplicate manifest entry' { Assert-NozeltUpdateManifest $bundle @($completeManifest[0],$completeManifest[0]) } 'Duplicate'
$receipt.Result='static-only'; Write-FixtureReceipt $receipt
Expect-Rejection 'static-only receipt' { Assert-NozeltReleaseReceipt $bundle } 'incomplete'
$receipt=New-FixtureReceipt; $receipt.ObservationSeconds=10; Write-FixtureReceipt $receipt
Expect-Rejection 'short observation' { Assert-NozeltReleaseReceipt $bundle } 'incomplete'
$receipt=New-FixtureReceipt; $receipt.WindowObserved=$false; Write-FixtureReceipt $receipt
Expect-Rejection 'no visible working UI' { Assert-NozeltReleaseReceipt $bundle } 'incomplete'
$receipt=New-FixtureReceipt; $receipt.Detections=@('fixture threat'); Write-FixtureReceipt $receipt
Expect-Rejection 'Defender detection' { Assert-NozeltReleaseReceipt $bundle } 'incomplete'
$receipt=New-FixtureReceipt; $receipt.VerifiedUtc=[DateTime]::UtcNow.AddHours(-25).ToString('o'); Write-FixtureReceipt $receipt
Expect-Rejection 'expired receipt' { Assert-NozeltReleaseReceipt $bundle } 'expired'
$receipt=New-FixtureReceipt; $receipt.VerifiedUtc=[DateTime]::UtcNow.AddMinutes(5).ToString('o'); Write-FixtureReceipt $receipt
Expect-Rejection 'future receipt' { Assert-NozeltReleaseReceipt $bundle } 'invalid timestamp'
foreach ($key in @('SignatureVersion','EngineVersion','PlatformVersion')) {
    $receipt=New-FixtureReceipt; $receipt.Defender.$key='different-version'; Write-FixtureReceipt $receipt
    Expect-Rejection "changed $key" { Assert-NozeltReleaseReceipt $bundle } 'Defender has changed'
}
$receipt=New-FixtureReceipt; Write-FixtureReceipt $receipt
[IO.File]::AppendAllText((Join-Path $bundle 'nozelt_core.dll'), 'tampered')
Expect-Rejection 'changed DLL' { Assert-NozeltReleaseReceipt $bundle } 'files changed'
$receipt=New-FixtureReceipt; Write-FixtureReceipt $receipt
Expect-Rejection 'unsigned public build' { Assert-NozeltReleaseReceipt $bundle -RequireSignature } 'signature is required'
# Private settings must not affect runtime fingerprint and must never be packaged.
$before=Get-NozeltRuntimeFingerprint (Get-NozeltRuntimeFiles $bundle)
New-Item -ItemType Directory -Path (Join-Path $bundle 'portable-data') | Out-Null
[IO.File]::WriteAllText((Join-Path $bundle 'portable-data\preferences.dpapi'), 'Not actual private data')
if ((Get-NozeltRuntimeFingerprint (Get-NozeltRuntimeFiles $bundle)) -ne $before) { throw 'Private data entered runtime fingerprint' }
$script:passed++
$archive=Join-Path $fixtures 'must-not-be-published.zip'
Expect-Rejection 'publishing private data' { & (Join-Path $scripts 'publish_windows_portable.ps1') -BundleDirectory $bundle -ArchivePath $archive } 'user data'
if (Test-Path -LiteralPath $archive) { throw 'Rejected publication still created a final archive' }
$script:passed++
# Both updater variants must reject traversal before querying/stopping any process.
$unsafe=Join-Path $fixtures 'unsafe-payload'
New-Item -ItemType Directory -Path $unsafe | Out-Null
@([pscustomobject]@{path='nozelt.exe';sha256=(Get-FileHash -LiteralPath (Join-Path $bundle 'nozelt.exe')).Hash},
  [pscustomobject]@{path='..\private.dpapi';sha256='invalid'}) |
    ConvertTo-Json | Set-Content -LiteralPath (Join-Path $unsafe 'update-manifest.json')
Copy-Item -LiteralPath (Join-Path $bundle 'nozelt.exe') -Destination $unsafe
foreach ($updater in @('update_windows_portable.ps1','update_windows_portable_auto.ps1')) {
    Expect-Rejection "$updater traversal" { & (Join-Path $scripts $updater) -Payload $unsafe -Destination $bundle -ValidateOnly } 'Unsafe update path'
}
[pscustomobject]@{Passed=$script:passed;Fixtures=$fixtures;ExecutablesLaunched=0;DefenderSettingsChanged=$false;VpnTouched=$false} | ConvertTo-Json
