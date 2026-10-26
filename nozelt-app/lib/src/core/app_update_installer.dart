import 'dart:io';

import 'package:flutter/services.dart';

import 'app_update.dart';

/// Result of handing a verified build to the platform.
enum UpdateInstallResult {
  /// The installer runs; on Windows Nozelt must exit now.
  started,

  /// Android needs the "install unknown apps" permission first. The system
  /// settings page is open; installing again afterwards continues.
  needsPermission,
}

/// Platform side of the updater: which build fits this copy, where to put
/// the download and how to install it.
abstract class UpdatePlatform {
  Future<UpdateTarget?> target();

  Future<Directory> downloadDirectory(AppRelease release);

  /// Installs [file]. On Windows the caller has already stopped the VPN and
  /// exits right after [UpdateInstallResult.started]; with [reconnect] the
  /// new version connects again on start.
  Future<UpdateInstallResult> install(
    File file,
    UpdateTarget target, {
    bool reconnect = false,
  });

  static UpdatePlatform? current() {
    if (Platform.isAndroid) return AndroidUpdatePlatform();
    if (Platform.isWindows) return WindowsUpdatePlatform();
    return null;
  }
}

class AndroidUpdatePlatform implements UpdatePlatform {
  static const _channel = MethodChannel('dev.nozelt.nozelt/engine');

  Map<String, dynamic>? _environment;

  Future<Map<String, dynamic>> _env() async => _environment ??=
      await _channel.invokeMapMethod<String, dynamic>('getUpdateEnvironment') ??
      const {};

  @override
  Future<UpdateTarget?> target() async {
    final abis = (await _env())['abis'];
    return UpdateTarget.forAndroidAbis(
      abis is List ? abis.map((abi) => abi.toString()) : const [],
    );
  }

  @override
  Future<Directory> downloadDirectory(AppRelease release) async {
    final path = (await _env())['directory']?.toString();
    if (path == null || path.isEmpty) {
      throw const FileSystemException('No update directory.');
    }
    return Directory(path).create(recursive: true);
  }

  @override
  Future<UpdateInstallResult> install(
    File file,
    UpdateTarget target, {
    bool reconnect = false,
  }) async {
    final result = await _channel.invokeMethod<String>('installUpdate', {
      'path': file.path,
    });
    return result == 'permission'
        ? UpdateInstallResult.needsPermission
        : UpdateInstallResult.started;
  }
}

class WindowsUpdatePlatform implements UpdatePlatform {
  Directory get _appDirectory => File(Platform.resolvedExecutable).parent;

  /// Inno Setup leaves its uninstaller next to an installed copy; a portable
  /// copy has none.
  bool get installed => File(
    '${_appDirectory.path}${Platform.pathSeparator}unins000.exe',
  ).existsSync();

  @override
  Future<UpdateTarget?> target() async =>
      installed ? UpdateTarget.windowsInstaller : UpdateTarget.windowsPortable;

  @override
  Future<Directory> downloadDirectory(AppRelease release) => Directory(
    '${Directory.systemTemp.path}${Platform.pathSeparator}nozelt-update-${release.version}',
  ).create(recursive: true);

  @override
  Future<UpdateInstallResult> install(
    File file,
    UpdateTarget target, {
    bool reconnect = false,
  }) async {
    final script = File(
      '${file.parent.path}${Platform.pathSeparator}apply-update.ps1',
    );
    await script.writeAsString(windowsUpdateScript, flush: true);
    final appDirectory = _appDirectory.path;
    final localAppData = Platform.environment['LOCALAPPDATA'] ?? '';
    final perUser =
        localAppData.isNotEmpty &&
        appDirectory.toLowerCase().startsWith(localAppData.toLowerCase());
    await Process.start('powershell.exe', [
      '-NoProfile',
      '-ExecutionPolicy',
      'Bypass',
      '-WindowStyle',
      'Hidden',
      '-File',
      script.path,
      '-Package',
      file.path,
      '-Target',
      appDirectory,
      '-WaitPid',
      '$pid',
      '-Mode',
      target == UpdateTarget.windowsInstaller ? 'installer' : 'portable',
      '-Scope',
      perUser ? 'currentuser' : 'allusers',
      if (reconnect) '-Reconnect',
    ], mode: ProcessStartMode.detached);
    return UpdateInstallResult.started;
  }
}

/// Runs after Nozelt has exited: installs the new build and starts Nozelt
/// again. The portable copy is replaced file by file with `portable-data`
/// left untouched, and the old files come back if copying fails.
const String windowsUpdateScript = r'''
param(
    [Parameter(Mandatory = $true)][string]$Package,
    [Parameter(Mandatory = $true)][string]$Target,
    [Parameter(Mandatory = $true)][int]$WaitPid,
    [Parameter(Mandatory = $true)][ValidateSet('installer', 'portable')][string]$Mode,
    [ValidateSet('currentuser', 'allusers')][string]$Scope = 'currentuser',
    [switch]$Reconnect
)
$ErrorActionPreference = 'Stop'
$work = Split-Path -Parent $Package
$log = Join-Path $work 'update.log'
function Write-Log([string]$Message) {
    Add-Content -LiteralPath $log -Value ('{0:u} {1}' -f (Get-Date), $Message)
}
$exe = Join-Path $Target 'nozelt.exe'
try {
    try { Wait-Process -Id $WaitPid -Timeout 90 -ErrorAction Stop } catch {}
    Get-Process nozelt -ErrorAction SilentlyContinue |
        Where-Object { $_.Path -eq $exe } |
        Stop-Process -Force -ErrorAction SilentlyContinue
    Start-Sleep -Milliseconds 700
    if (-not (Test-Path -LiteralPath $exe)) { throw "Nozelt not found in $Target" }
    if ([IO.Path]::GetPathRoot($Target).TrimEnd('\') -eq $Target.TrimEnd('\')) {
        throw 'Refusing to update a drive root.'
    }
    if ($Mode -eq 'installer') {
        $scopeArg = if ($Scope -eq 'allusers') { '/ALLUSERS' } else { '/CURRENTUSER' }
        $arguments = @('/SILENT', '/SP-', '/SUPPRESSMSGBOXES', '/NORESTART', '/NOCANCEL', $scopeArg, "/DIR=`"$Target`"")
        $process = Start-Process -FilePath $Package -ArgumentList $arguments -Wait -PassThru
        Write-Log "installer exit code $($process.ExitCode)"
    } else {
        $stage = Join-Path $work 'stage'
        $backup = Join-Path $work 'backup'
        foreach ($dir in @($stage, $backup)) {
            if (Test-Path -LiteralPath $dir) { Remove-Item -LiteralPath $dir -Recurse -Force }
        }
        Expand-Archive -LiteralPath $Package -DestinationPath $stage -Force
        $found = Get-ChildItem -LiteralPath $stage -Recurse -Filter 'nozelt.exe' | Select-Object -First 1
        if (-not $found) { throw 'nozelt.exe is missing from the archive.' }
        $source = $found.DirectoryName
        $options = @('/MIR', '/XD', 'portable-data', '/R:5', '/W:1', '/NFL', '/NDL', '/NJH', '/NJS', '/NP')
        robocopy $Target $backup @options | Out-Null
        if ($LASTEXITCODE -ge 8) { throw "backup failed ($LASTEXITCODE)" }
        robocopy $source $Target @options | Out-Null
        if ($LASTEXITCODE -ge 8) {
            Write-Log "copy failed ($LASTEXITCODE), restoring the previous version"
            robocopy $backup $Target @options | Out-Null
            throw 'copy failed'
        }
        Remove-Item -LiteralPath $stage -Recurse -Force -ErrorAction SilentlyContinue
        Write-Log 'portable copy updated'
    }
} catch {
    Write-Log "error: $_"
} finally {
    # Nozelt reads this at start and connects again if it was connected.
    if ($Reconnect) { $env:NOZELT_CONNECT_ON_START = '1' }
    if (Test-Path -LiteralPath $exe) { Start-Process -FilePath $exe -WorkingDirectory $Target }
}
''';
