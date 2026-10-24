[CmdletBinding()]
param(
    [string]$BundleDirectory = '',
    [string]$ArchivePath = '',
    [switch]$RequireSignature
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'windows_release_checks.ps1')
$appRoot = Split-Path -Parent $PSScriptRoot
if (-not $BundleDirectory) { $BundleDirectory = Join-Path $appRoot 'build\portable\Nozelt' }
if (-not $ArchivePath) { $ArchivePath = Join-Path $appRoot 'build\portable\Nozelt-windows-x64-portable.zip' }
$root = [IO.Path]::GetFullPath($BundleDirectory).TrimEnd('\', '/')
$archive = [IO.Path]::GetFullPath($ArchivePath)
if ($archive.StartsWith($root + '\', [StringComparison]::OrdinalIgnoreCase)) { throw 'Archive cannot be inside the bundle.' }
if (Test-Path -LiteralPath (Join-Path $root 'portable-data')) { throw 'Never publish a bundle containing user data, even if encrypted.' }
if (Test-Path -LiteralPath $archive) { throw 'Archive already exists; select a new output name.' }
$null = Assert-NozeltReleaseReceipt $root -RequireSignature:$RequireSignature
$files = Get-NozeltRuntimeFiles $root
$files | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath (Join-Path $root 'SHA256SUMS.json') -Encoding UTF8
@($files | ForEach-Object { [pscustomobject]@{path=$_.File;sha256=$_.SHA256} }) |
    ConvertTo-Json -Depth 4 | Set-Content -LiteralPath (Join-Path $root 'update-manifest.json') -Encoding UTF8
$candidateArchive = $archive + '.candidate-' + [guid]::NewGuid().ToString('N') + '.zip'
Compress-Archive -Path (Join-Path $root '*') -DestinationPath $candidateArchive -CompressionLevel Optimal
Invoke-NozeltDefenderScan $candidateArchive
$null = Assert-NozeltReleaseReceipt $root -RequireSignature:$RequireSignature
Move-Item -LiteralPath $candidateArchive -Destination $archive
Write-Host "Verified archive: $archive"
Get-FileHash -LiteralPath $archive -Algorithm SHA256
