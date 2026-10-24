[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$BundleDirectory,
    [int]$ObserveProcessId = 0,
    [ValidateRange(180, 3600)][int]$ObservationSeconds = 300,
    [string]$ReportPath = '',
    [switch]$RequireSignature
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'windows_release_checks.ps1')
$root = [IO.Path]::GetFullPath($BundleDirectory).TrimEnd('\', '/')
$receiptPath = Join-Path $root 'release-verification.json'
if (-not $ReportPath) { $ReportPath = $receiptPath }
# Invalidate an old approval before starting a new check; retain it for diagnosis.
if (Test-Path -LiteralPath $receiptPath) {
    $previous = Join-Path (Split-Path -Parent $root) ('Nozelt-release-check-' + [guid]::NewGuid().ToString('N') + '.json')
    Move-Item -LiteralPath $receiptPath -Destination $previous
}
$started = Get-Date
$report = [ordered]@{
    Schema = 1; Result = 'failed'; StartedUtc = $started.ToUniversalTime().ToString('o')
    VerifiedUtc = $null; RuntimeFingerprint = $null; ExecutableSHA256 = $null
    Defender = $null; SignatureStatus = $null; StaticScanPassed = $false
    ObservationSeconds = 0; WindowObserved = $false; Detections = @()
}
try {
    $report.Defender = Get-NozeltDefenderStatus
    $files = Get-NozeltRuntimeFiles $root
    $report.RuntimeFingerprint = Get-NozeltRuntimeFingerprint $files
    $report.ExecutableSHA256 = ($files | Where-Object { $_.File -eq 'nozelt.exe' }).SHA256
    $signature = Get-AuthenticodeSignature -LiteralPath (Join-Path $root 'nozelt.exe')
    $report.SignatureStatus = $signature.Status.ToString()
    if ($RequireSignature -and $signature.Status -ne 'Valid') { throw 'Trusted Authenticode signature required.' }
    # Scan the exact public runtime files, never private portable-data.
    # A clean stage can be scanned in one pass; installed private data is excluded.
    if (Test-Path -LiteralPath (Join-Path $root 'portable-data')) {
        Get-ChildItem -LiteralPath $root | Where-Object {
            $_.Name -notin @('portable-data', 'SHA256SUMS.json', 'update-manifest.json', 'release-verification.json')
        } | ForEach-Object { Invoke-NozeltDefenderScan $_.FullName }
    } else { Invoke-NozeltDefenderScan $root }
    $report.StaticScanPassed = $true
    if ($ObserveProcessId -eq 0) {
        $report.Result = 'static-only'
        Write-Host 'Static checks passed. This is a candidate, not an approved release; post-launch observation is still required.'
    } else {
        $expectedImage = Join-Path $root 'nozelt.exe'
        if ((Get-NozeltProcessImage $ObserveProcessId) -ne $expectedImage) { throw 'Observed process is not the executable in this bundle.' }
        $process = Get-Process -Id $ObserveProcessId -ErrorAction Stop
        $processStarted = $process.StartTime
        # Include detections between launch and the beginning of this script too.
        $eventStart = $processStarted.AddSeconds(-1)
        $timer = [Diagnostics.Stopwatch]::StartNew()
        $lastResponsive = 0.0
        while ($timer.Elapsed.TotalSeconds -lt $ObservationSeconds) {
            $process.Refresh()
            if ($process.HasExited -or $process.StartTime -ne $processStarted) { throw 'Observed process exited or was replaced.' }
            if ($process.MainWindowHandle -ne 0 -and $process.MainWindowTitle -eq 'Nozelt' -and $process.Responding) {
                $report.WindowObserved = $true
                $lastResponsive = $timer.Elapsed.TotalSeconds
            }
            if ($timer.Elapsed.TotalSeconds - $lastResponsive -gt 30) { throw 'Main window has been missing or unresponsive for over 30 seconds.' }
            if (-not (Test-Path -LiteralPath $expectedImage -PathType Leaf)) { throw 'EXE disappeared during observation (possibly quarantine).' }
            $report.Detections = @(Get-NozeltDefenderEvents $eventStart $root)
            if ($report.Detections.Count -gt 0) { throw 'Defender detected or remediated this runtime after launch.' }
            Start-Sleep -Seconds 5
        }
        $report.ObservationSeconds = [math]::Floor($timer.Elapsed.TotalSeconds)
        if (-not $report.WindowObserved) { throw 'A responsive main window was not observed.' }
        $process.Refresh()
        if ($process.HasExited -or -not $process.Responding) { throw 'The runtime is not healthy at the end of observation.' }
        if ((Get-NozeltRuntimeFingerprint (Get-NozeltRuntimeFiles $root)) -ne $report.RuntimeFingerprint) {
            throw 'Runtime files changed during observation.'
        }
        $latest = Get-NozeltDefenderStatus
        if ($latest.SignatureVersion -ne $report.Defender.SignatureVersion -or
            $latest.EngineVersion -ne $report.Defender.EngineVersion -or
            $latest.PlatformVersion -ne $report.Defender.PlatformVersion) {
            throw 'Defender changed during observation; repeat the check with a consistent version.'
        }
        $report.Result = 'passed'
        Write-Host 'Exact runtime passed static scanning and post-launch observation. No process or VPN was stopped by this check.'
    }
    $report.VerifiedUtc = [DateTime]::UtcNow.ToString('o')
} finally {
    $report | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $ReportPath -Encoding UTF8
}
