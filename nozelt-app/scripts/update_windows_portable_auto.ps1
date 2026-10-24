[CmdletBinding()]
param(
    [string]$Payload = '',
    [string]$Destination = 'C:\Nozelt Windows Portable',
    [switch]$ValidateOnly,
    [switch]$CloseRunning,
    [switch]$NonInteractive
)
$ErrorActionPreference = 'Stop'
if ([string]::IsNullOrWhiteSpace($Payload)) { $Payload = Join-Path $PSScriptRoot 'payload' }
$taskPayload = [IO.Path]::GetFullPath($Payload)
$taskDestination = [IO.Path]::GetFullPath($Destination)
$taskExecutable = Join-Path $taskDestination 'nozelt.exe'
$taskStatusFile = Join-Path $PSScriptRoot 'update-status.json'
$taskLogFile = Join-Path $PSScriptRoot 'update.log'
$taskSaved = @()
$taskBackup = $null
$taskStopped = $false
$taskNewProcess = $null
$taskOwnMutex = $false

function Write-UpdateStatus([string]$Phase, [string]$Message, [hashtable]$Extra = @{}) {
    $taskRecord = @{phase=$Phase; message=$Message; time=(Get-Date).ToString('o'); updaterPid=$PID}
    foreach ($key in $Extra.Keys) { $taskRecord[$key] = $Extra[$key] }
    $taskRecord | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $taskStatusFile -Encoding utf8
    Add-Content -LiteralPath $taskLogFile -Value ((Get-Date).ToString('o') + ' ' + $Phase + ': ' + $Message) -Encoding utf8
    Write-Host $Message
}
function Get-TargetProcesses {
    @(Get-Process nozelt -ErrorAction SilentlyContinue | Where-Object {
        $_.Path -and [string]::Equals($_.Path, $taskExecutable, [StringComparison]::OrdinalIgnoreCase)
    })
}
function Start-NozeltConnected {
    $taskPreviousConnect = $env:NOZELT_CONNECT_ON_START
    try {
        $env:NOZELT_CONNECT_ON_START = '1'
        Start-Process -FilePath $taskExecutable -WorkingDirectory $taskDestination -PassThru
    } finally { $env:NOZELT_CONNECT_ON_START = $taskPreviousConnect }
}
function Wait-NozeltConnection($StartedProcess) {
    $taskDeadline = (Get-Date).AddSeconds(90)
    do {
        Start-Sleep -Milliseconds 750
        $StartedProcess.Refresh()
        if ($StartedProcess.HasExited) { throw 'The newly started Nozelt process exited.' }
        $taskTun = @(Get-NetAdapter -ErrorAction SilentlyContinue | Where-Object {
            $_.Name -like 'Nozelt*' -and $_.Status -eq 'Up'
        })
        if ($taskTun.Count -gt 0) { return $true }
    } while ((Get-Date) -lt $taskDeadline)
    return $false
}

# Validate all paths/hashes before elevation or interruption of the VPN.
$taskManifest = Get-Content -LiteralPath (Join-Path $taskPayload 'update-manifest.json') -Raw | ConvertFrom-Json
if ($taskManifest.Count -eq 0 -or -not ($taskManifest | Where-Object {$_.path -eq 'nozelt.exe'})) {
    throw 'The update manifest is empty or has no executable.'
}
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
    Write-UpdateStatus 'elevation_requested' 'Requesting Windows administrator access for the update.'
    $taskArguments = @('-NoProfile', '-ExecutionPolicy', 'RemoteSigned', '-File', ('"' + $PSCommandPath + '"'),
        '-Payload', ('"' + $taskPayload + '"'), '-Destination', ('"' + $taskDestination + '"'))
    if ($CloseRunning) { $taskArguments += '-CloseRunning' }
    if ($NonInteractive) { $taskArguments += '-NonInteractive' }
    try {
        # Elevation is interactive: keep the update console visible so the user
        # can see the request and any launch failure.
        Start-Process powershell.exe -Verb RunAs -WindowStyle Normal -ArgumentList $taskArguments
    } catch {
        Write-UpdateStatus 'elevation_failed' ('Windows administrator request failed: ' + $_.Exception.Message)
        throw
    }
    exit 0
}

$taskMutex = New-Object Threading.Mutex($false, 'Local\Nozelt.PortableUpdater.7A6C1E32')
try {
    try { $taskOwnMutex = $taskMutex.WaitOne(0) } catch [Threading.AbandonedMutexException] { $taskOwnMutex = $true }
    if (-not $taskOwnMutex) { throw 'Another Nozelt updater is already running.' }
    Write-UpdateStatus 'preparing' 'Checksums verified. Saving existing application files before stopping TUN.'
    $taskBackup = Join-Path $PSScriptRoot ('rollback-' + (Get-Date -Format 'yyyyMMdd-HHmmss'))
    New-Item -ItemType Directory -Path $taskBackup -Force | Out-Null
    foreach ($entry in $taskManifest) {
        $target = Join-Path $taskDestination $entry.path
        if (Test-Path -LiteralPath $target) {
            $saved = Join-Path $taskBackup $entry.path
            New-Item -ItemType Directory -Path (Split-Path -Parent $saved) -Force | Out-Null
            Copy-Item -LiteralPath $target -Destination $saved -Force
            $taskSaved += $entry.path
        }
    }
    $taskProcesses = @(Get-TargetProcesses)
    if ($CloseRunning) {
        Write-UpdateStatus 'stopping' 'Closing the verified portable Nozelt processes; TUN will restart automatically.' @{oldProcessIds=@($taskProcesses | ForEach-Object {$_.Id})}
        # WM_CLOSE merely hides this app. Process exit unlocks the core DLL;
        # its native child processes use kill-on-close Windows jobs.
        $taskStopped = $true
        foreach ($process in $taskProcesses) {
            $null = $process.Handle
            Stop-Process -Id $process.Id -Force -ErrorAction Stop
            if (-not $process.WaitForExit(10000)) { throw 'Nozelt did not terminate in time.' }
        }
    } else {
        Write-UpdateStatus 'waiting_for_exit' 'Choose Exit application in the Nozelt tray menu. This update is waiting.'
        foreach ($process in $taskProcesses) { $process.WaitForExit() }
        $taskStopped = $true
    }
    if (@(Get-TargetProcesses).Count -gt 0) { throw 'Nozelt started again while preparing the update.' }
    # Hash encrypted data after exit; never decrypt it or print its contents.
    $taskUserHashes = @{}
    Get-ChildItem -LiteralPath (Join-Path $taskDestination 'portable-data') -File -Recurse | ForEach-Object {
        $taskUserHashes[$_.FullName] = (Get-FileHash -LiteralPath $_.FullName).Hash
    }
    Write-UpdateStatus 'copying' 'Replacing application files; encrypted portable settings are preserved.'
    foreach ($entry in $taskManifest) {
        $target = Join-Path $taskDestination $entry.path
        New-Item -ItemType Directory -Path (Split-Path -Parent $target) -Force | Out-Null
        Copy-Item -LiteralPath (Join-Path $taskPayload $entry.path) -Destination $target -Force
        if ((Get-FileHash -LiteralPath $target).Hash -ne $entry.sha256) { throw 'Installed file checksum verification failed.' }
    }
    foreach ($path in $taskUserHashes.Keys) {
        if ((Get-FileHash -LiteralPath $path).Hash -ne $taskUserHashes[$path]) { throw 'Portable user data changed during replacement.' }
    }
    Write-UpdateStatus 'starting' 'Starting the updated Nozelt with one-time automatic connection.'
    $taskNewProcess = Start-NozeltConnected
    $taskConnected = Wait-NozeltConnection $taskNewProcess
    if (-not $taskConnected) { throw 'TUN startup was not confirmed within 90 seconds.' }
    Start-Sleep -Seconds 3
    $taskNewProcess.Refresh()
    if ($taskNewProcess.HasExited) { throw 'Nozelt exited after connection startup.' }
    $taskHttpStatuses = @()
    for ($taskProbe = 0; $taskProbe -lt 3; $taskProbe++) {
        try {
            $taskResponse = Invoke-WebRequest -Uri 'https://www.gstatic.com/generate_204' -UseBasicParsing -TimeoutSec 10
            $taskHttpStatuses += [int]$taskResponse.StatusCode
        } catch { $taskHttpStatuses += 0 }
    }
    Write-UpdateStatus 'complete' 'Updated Nozelt is running, TUN is up, and portable data was preserved.' @{
        newProcessId=$taskNewProcess.Id; tunUp=$true; httpsStatuses=$taskHttpStatuses;
        installedExeHash=(Get-FileHash -LiteralPath $taskExecutable).Hash; backup=$taskBackup
    }
} catch {
    $taskFailure = $_.Exception.Message
    if ($taskStopped -and $taskBackup) {
        Write-UpdateStatus 'rolling_back' ('Update failed; restoring saved files. ' + $taskFailure)
        try {
            if ($taskNewProcess -and -not $taskNewProcess.HasExited) {
                Stop-Process -Id $taskNewProcess.Id -Force
                $null = $taskNewProcess.WaitForExit(10000)
            }
            foreach ($relative in $taskSaved) {
                Copy-Item -LiteralPath (Join-Path $taskBackup $relative) -Destination (Join-Path $taskDestination $relative) -Force
            }
            $taskRestored = Start-NozeltConnected
            $taskRestoredTun = Wait-NozeltConnection $taskRestored
            Write-UpdateStatus 'rolled_back' ('Previous version restored and restarted. ' + $taskFailure) @{newProcessId=$taskRestored.Id; tunUp=$taskRestoredTun}
        } catch { Write-UpdateStatus 'failed' ('Rollback needs attention: ' + $_.Exception.Message) }
    } else { Write-UpdateStatus 'failed' $taskFailure }
    if (-not $NonInteractive) { $null = Read-Host 'Press Enter to close' }
    exit 1
} finally {
    if ($taskOwnMutex) { $taskMutex.ReleaseMutex() }
    $taskMutex.Dispose()
}
if (-not $NonInteractive) { $null = Read-Host 'Press Enter to close' }
