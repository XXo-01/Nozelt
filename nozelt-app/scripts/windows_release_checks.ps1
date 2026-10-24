# Shared release checks. Read-only for Defender, processes, and network settings.
Set-StrictMode -Version Latest

function Get-NozeltRuntimeFiles([string]$Directory) {
    $root = [IO.Path]::GetFullPath($Directory).TrimEnd('\', '/')
    if (-not (Test-Path -LiteralPath (Join-Path $root 'nozelt.exe') -PathType Leaf)) {
        throw 'Nozelt executable is missing (possibly quarantined).'
    }
    $metadata = @('SHA256SUMS.json', 'update-manifest.json', 'release-verification.json')
    @(Get-ChildItem -LiteralPath $root -File -Recurse -Force | ForEach-Object {
        # Do not follow links out of a bundle or fingerprint private portable data.
        $relative = $_.FullName.Substring($root.Length + 1).Replace('\', '/')
        if ($relative -match '^portable-data/') { return }
        if ($relative -match '/portable-data(/|$)') { throw 'Nested private data directory found in runtime.' }
        if ($relative -in $metadata) { return }
        if (($_.Attributes -band [IO.FileAttributes]::Hidden) -ne 0) {
            throw 'Hidden runtime files are not supported by the ZIP packaging step.'
        }
        $parent = $_
        while ($parent.FullName.Length -gt $root.Length) {
            if (($parent.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
                throw 'Linked files/directories are not allowed in a release bundle.'
            }
            $parent = Get-Item -LiteralPath (Split-Path -Parent $parent.FullName)
        }
        [pscustomobject]@{
            File = $relative
            Bytes = $_.Length
            SHA256 = (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
        }
    } | Sort-Object File)
}

function Get-NozeltRuntimeFingerprint($Files) {
    [string[]]$ordered = @($Files | ForEach-Object {
        $_.File.ToLowerInvariant() + '|' + $_.Bytes.ToString([Globalization.CultureInfo]::InvariantCulture) + '|' + $_.SHA256
    })
    # NLS (Windows PowerShell) and ICU (.NET/PowerShell 7) order punctuation
    # differently. A bundle identity must not depend on either collation.
    [Array]::Sort($ordered, [StringComparer]::Ordinal)
    $lines = $ordered -join "`n"
    $algorithm = [Security.Cryptography.SHA256]::Create()
    try {
        -join ($algorithm.ComputeHash([Text.Encoding]::UTF8.GetBytes($lines)) | ForEach-Object { $_.ToString('x2') })
    } finally { $algorithm.Dispose() }
}

function Get-NozeltDefenderStatus {
    $status = Get-MpComputerStatus -ErrorAction Stop
    if (-not $status.AntivirusEnabled -or -not $status.RealTimeProtectionEnabled) {
        throw 'Release verification requires active Defender antivirus and real-time protection.'
    }
    if (-not $status.AntivirusSignatureLastUpdated -or
        ((Get-Date) - $status.AntivirusSignatureLastUpdated).TotalHours -gt 48) {
        throw 'Defender security intelligence is older than 48 hours; verification is inconclusive.'
    }
    [pscustomobject]@{
        SignatureVersion = $status.AntivirusSignatureVersion
        EngineVersion = $status.AMEngineVersion
        PlatformVersion = $status.AMProductVersion
        SignatureUpdatedUtc = $status.AntivirusSignatureLastUpdated.ToUniversalTime().ToString('o')
        RealTimeProtection = $status.RealTimeProtectionEnabled
    }
}

function Invoke-NozeltDefenderScan([string]$Path) {
    $platform = Join-Path $env:ProgramData 'Microsoft\Windows Defender\Platform'
    $scanner = Get-ChildItem -LiteralPath $platform -Directory -ErrorAction Stop |
        Sort-Object Name -Descending |
        ForEach-Object { Join-Path $_.FullName 'MpCmdRun.exe' } |
        Where-Object { Test-Path -LiteralPath $_ -PathType Leaf } | Select-Object -First 1
    if (-not $scanner) { throw 'Microsoft Defender scanner not found.' }
    # Ignore exclusions, inspect archives, and leave remediation policy unchanged.
    $scanOutput = @(& $scanner -Scan -ScanType 3 -File $Path -DisableRemediation 2>&1)
    $scanExit = $LASTEXITCODE
    $scanOutput | ForEach-Object { Write-Host $_ }
    if ($scanExit -ne 0) { throw "Defender scan failed or detected a threat (exit $scanExit)." }
}

function Get-NozeltDefenderEvents([datetime]$Since, [string]$Directory) {
    $root = [IO.Path]::GetFullPath($Directory).TrimEnd('\', '/') + '\'
    try {
        $events = @(Get-WinEvent -FilterHashtable @{
            LogName = 'Microsoft-Windows-Windows Defender/Operational'
            Id = @(1116, 1117)
            StartTime = $Since
        } -ErrorAction Stop)
    } catch {
        if ($_.FullyQualifiedErrorId -like 'NoMatchingEventsFound*') { return @() }
        throw # An unreadable journal is not a successful test.
    }
    @($events | ForEach-Object {
        $fields = @{}
        ([xml]$_.ToXml()).Event.EventData.Data | ForEach-Object { $fields[$_.Name] = $_.'#text' }
        $related = @($fields.Values | Where-Object { $_ -and $_.IndexOf($root, [StringComparison]::OrdinalIgnoreCase) -ge 0 })
        if ($related.Count -gt 0) {
            [pscustomobject]@{
                RecordId = $_.RecordId
                EventId = $_.Id
                TimeUtc = $_.TimeCreated.ToUniversalTime().ToString('o')
                Threat = $fields['Threat Name']
            }
        }
    })
}

function Get-NozeltProcessImage([int]$ProcessId) {
    if (-not ('Nozelt.ReleaseProcessImage' -as [type])) {
        Add-Type -TypeDefinition @'
using System;
using System.Text;
using System.Runtime.InteropServices;
namespace Nozelt {
 public static class ReleaseProcessImage {
  [DllImport("kernel32.dll", SetLastError=true)] static extern IntPtr OpenProcess(uint access, bool inherit, int pid);
  [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)] static extern bool QueryFullProcessImageName(IntPtr process, uint flags, StringBuilder path, ref uint size);
  [DllImport("kernel32.dll")] static extern bool CloseHandle(IntPtr handle);
  public static string Read(int pid) {
   var handle=OpenProcess(0x1000,false,pid);
   if(handle==IntPtr.Zero) throw new System.ComponentModel.Win32Exception();
   try {
    uint size=32768; var path=new StringBuilder((int)size);
    if(!QueryFullProcessImageName(handle,0,path,ref size)) throw new System.ComponentModel.Win32Exception();
    return path.ToString();
   } finally {CloseHandle(handle);}
  }
 }
}
'@
    }
    [Nozelt.ReleaseProcessImage]::Read($ProcessId)
}

function Assert-NozeltReleaseReceipt([string]$Directory, [switch]$RequireSignature) {
    $receiptPath = Join-Path $Directory 'release-verification.json'
    if (-not (Test-Path -LiteralPath $receiptPath -PathType Leaf)) {
        throw 'Release has no post-launch verification receipt. Run test_windows_release.ps1 with the running Nozelt process ID.'
    }
    $receipt = Get-Content -LiteralPath $receiptPath -Raw | ConvertFrom-Json
    if ($receipt.Schema -ne 1 -or $receipt.Result -ne 'passed' -or
        $receipt.ObservationSeconds -lt 180 -or -not $receipt.WindowObserved -or
        -not $receipt.StaticScanPassed -or @($receipt.Detections).Count -ne 0) {
        throw 'Release verification is missing, incomplete, or failed.'
    }
    # PowerShell 7 can deserialize ISO timestamps directly to DateTime;
    # converting that object back through locale-dependent text swaps day/month.
    if ($receipt.VerifiedUtc -is [datetime]) {
        $verified = [DateTimeOffset]::new($receipt.VerifiedUtc)
    } else {
        $verified = [DateTimeOffset]::Parse([string]$receipt.VerifiedUtc,
            [Globalization.CultureInfo]::InvariantCulture,
            [Globalization.DateTimeStyles]::RoundtripKind)
    }
    $age = [DateTimeOffset]::UtcNow - $verified
    if ($age.TotalHours -gt 24 -or $age.TotalSeconds -lt -60) {
        throw 'Release receipt is expired or has an invalid timestamp.'
    }
    $status = Get-NozeltDefenderStatus
    if ($status.SignatureVersion -ne $receipt.Defender.SignatureVersion -or
        $status.EngineVersion -ne $receipt.Defender.EngineVersion -or
        $status.PlatformVersion -ne $receipt.Defender.PlatformVersion) {
        throw 'Defender has changed since runtime verification. Verify the unchanged release again.'
    }
    $files = Get-NozeltRuntimeFiles $Directory
    if ((Get-NozeltRuntimeFingerprint $files) -ne $receipt.RuntimeFingerprint) {
        throw 'Release files changed after verification; this receipt cannot approve them.'
    }
    $signature = Get-AuthenticodeSignature -LiteralPath (Join-Path $Directory 'nozelt.exe')
    if ($RequireSignature -and $signature.Status -ne 'Valid') {
        throw 'A valid trusted Authenticode signature is required for this release.'
    }
    $receipt
}

function Assert-NozeltUpdateManifest([string]$Directory, $Manifest) {
    $files = @(Get-NozeltRuntimeFiles $Directory)
    $entries = @($Manifest)
    if ($entries.Count -ne $files.Count) { throw 'Update manifest does not cover the complete verified runtime.' }
    $indexed = @{}
    foreach ($entry in $entries) {
        $key = $entry.path.Replace('\', '/').ToLowerInvariant()
        if ($indexed.ContainsKey($key)) { throw 'Duplicate update manifest entry.' }
        $indexed[$key] = $entry.sha256
    }
    foreach ($file in $files) {
        $key = $file.File.ToLowerInvariant()
        if (-not $indexed.ContainsKey($key) -or $indexed[$key] -ne $file.SHA256) {
            throw 'Update manifest does not cover the complete verified runtime.'
        }
    }
}
