[CmdletBinding()]
param(
    [string]$Payload = '',
    [string]$Destination = 'C:\Nozelt Windows Portable',
    [switch]$ValidateOnly
)
$ErrorActionPreference = 'Stop'
if ([string]::IsNullOrWhiteSpace($Payload)) { $Payload = Join-Path $PSScriptRoot 'payload' }
$taskPayload = [IO.Path]::GetFullPath($Payload)
$taskDestination = [IO.Path]::GetFullPath($Destination)
$taskManifest = Get-Content -LiteralPath (Join-Path $taskPayload 'update-manifest.json') -Raw | ConvertFrom-Json
foreach ($entry in $taskManifest) {
    $source = [IO.Path]::GetFullPath((Join-Path $taskPayload $entry.path))
    $target = [IO.Path]::GetFullPath((Join-Path $taskDestination $entry.path))
    if (-not $source.StartsWith($taskPayload + '\', [StringComparison]::OrdinalIgnoreCase) -or
        -not $target.StartsWith($taskDestination + '\', [StringComparison]::OrdinalIgnoreCase) -or
        $entry.path -match '(^|[\\/])portable-data([\\/]|$)') { throw 'Unsafe update path' }
    if ((Get-FileHash -LiteralPath $source -Algorithm SHA256).Hash -ne $entry.sha256) {
        throw "Update checksum mismatch: $($entry.path)"
    }
}
if (-not (Test-Path -LiteralPath (Join-Path $taskDestination 'portable-data\profiles.dpapi'))) {
    throw 'Existing portable profiles were not found; update cancelled before stopping VPN.'
}
. (Join-Path $PSScriptRoot 'windows_release_checks.ps1')
if (Test-Path -LiteralPath (Join-Path $taskPayload 'portable-data')) { throw 'Update payload must not contain user data.' }
Assert-NozeltUpdateManifest $taskPayload $taskManifest
$null = Assert-NozeltReleaseReceipt $taskPayload
if (-not $ValidateOnly) { Invoke-NozeltDefenderScan $taskPayload }
if ($ValidateOnly) { Write-Output 'Update paths, profiles and payload hashes verified. No running process changed.'; exit 0 }
$taskPrincipal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $taskPrincipal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    # This is an interactive update console: the user needs its exit instruction.
    Start-Process powershell.exe -Verb RunAs -WindowStyle Normal -ArgumentList @(
        '-NoProfile', '-ExecutionPolicy', 'RemoteSigned', '-File', ('"' + $PSCommandPath + '"'),
        '-Payload', ('"' + $taskPayload + '"'), '-Destination', ('"' + $taskDestination + '"')
    )
    exit 0
}
$taskProcesses = @(Get-Process nozelt -ErrorAction SilentlyContinue | Where-Object {
    $_.Path -eq (Join-Path $taskDestination 'nozelt.exe')
})
Write-Host 'Update is ready. Choose Exit application in the Nozelt tray menu.'
Write-Host 'This console will wait. It does not disconnect TUN on its own.'
foreach ($process in $taskProcesses) { $process.WaitForExit() }
if (Get-Process nozelt -ErrorAction SilentlyContinue | Where-Object {
    $_.Path -eq (Join-Path $taskDestination 'nozelt.exe')
}) { throw 'Nozelt restarted while waiting; close it through Exit application before updating.' }
$taskBackup = Join-Path $PSScriptRoot ('rollback-' + (Get-Date -Format 'yyyyMMdd-HHmmss'))
New-Item -ItemType Directory -Path $taskBackup -Force | Out-Null
$taskSaved = @()
try {
    foreach ($entry in $taskManifest) {
        $target = Join-Path $taskDestination $entry.path
        if (Test-Path -LiteralPath $target) {
            $saved = Join-Path $taskBackup $entry.path
            New-Item -ItemType Directory -Path (Split-Path -Parent $saved) -Force | Out-Null
            Copy-Item -LiteralPath $target -Destination $saved -Force
            $taskSaved += $entry.path
        }
        New-Item -ItemType Directory -Path (Split-Path -Parent $target) -Force | Out-Null
        Copy-Item -LiteralPath (Join-Path $taskPayload $entry.path) -Destination $target -Force
    }
    $taskPreviousConnect = $env:NOZELT_CONNECT_ON_START
    try {
        $env:NOZELT_CONNECT_ON_START = '1'
        Start-Process -FilePath (Join-Path $taskDestination 'nozelt.exe') -WorkingDirectory $taskDestination
    } finally { $env:NOZELT_CONNECT_ON_START = $taskPreviousConnect }
    $taskDeadline = (Get-Date).AddSeconds(60)
    do {
        Start-Sleep -Milliseconds 500
        $taskTun = Get-NetAdapter -ErrorAction SilentlyContinue | Where-Object {
            $_.Name -like 'Nozelt*' -and $_.Status -eq 'Up'
        }
    } while (-not $taskTun -and (Get-Date) -lt $taskDeadline)
    if ($taskTun) { Write-Host 'New Nozelt started; TUN adapter is up. Check the connection in the app.' }
    else { Write-Warning 'Automatic TUN startup was not confirmed. Open Nozelt and check Logs; do not close this console yet.' }
} catch {
    foreach ($relative in $taskSaved) {
        Copy-Item -LiteralPath (Join-Path $taskBackup $relative) -Destination (Join-Path $taskDestination $relative) -Force
    }
    Start-Process -FilePath (Join-Path $taskDestination 'nozelt.exe') -WorkingDirectory $taskDestination
    Write-Warning 'Update failed. Previous files restored and application reopened; enable TUN in the app.'
    Write-Warning $_.Exception.Message
}
Read-Host 'Press Enter to close this console'
