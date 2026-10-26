import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show ProviderListenable;
import 'package:http/http.dart' as http;

import '../core/app_metadata.dart';
import '../core/app_update.dart';
import '../core/app_update_installer.dart';
import '../core/models.dart';
import '../core/windows_shell_bridge.dart';
import 'app_lifecycle_provider.dart';
import 'engine_provider.dart';
import 'settings_provider.dart';

enum UpdatePhase { idle, downloading, installing, awaitingPermission, failed }

@immutable
class AppUpdateState {
  const AppUpdateState({
    this.offerUpdates = true,
    this.dismissedVersion,
    this.release,
    this.phase = UpdatePhase.idle,
    this.progress,
    this.errorKey,
  });

  /// Setting "Offer new updates": shows the banner on the main screen.
  final bool offerUpdates;

  /// Version whose main-screen banner was closed with X.
  final String? dismissedVersion;

  /// Newer release found on GitHub, or null.
  final AppRelease? release;

  final UpdatePhase phase;

  /// Download progress 0..1, null when the size is unknown.
  final double? progress;

  final String? errorKey;

  bool get available => release != null;

  bool get busy =>
      phase == UpdatePhase.downloading || phase == UpdatePhase.installing;

  /// The closable banner on the main screen.
  bool get showMainBanner =>
      release != null &&
      offerUpdates &&
      (busy || dismissedVersion != release!.version.toString());

  AppUpdateState copyWith({
    bool? offerUpdates,
    String? dismissedVersion,
    AppRelease? release,
    UpdatePhase? phase,
    double? progress,
    bool clearProgress = false,
    String? errorKey,
    bool clearError = false,
  }) => AppUpdateState(
    offerUpdates: offerUpdates ?? this.offerUpdates,
    dismissedVersion: dismissedVersion ?? this.dismissedVersion,
    release: release ?? this.release,
    phase: phase ?? this.phase,
    progress: clearProgress ? null : (progress ?? this.progress),
    errorKey: clearError ? null : (errorKey ?? this.errorKey),
  );
}

/// Network side of the updater, replaceable in tests.
class AppUpdateClient {
  AppUpdateClient([http.Client? client]) : _client = client ?? http.Client();

  final http.Client _client;

  static const _headers = {
    'Accept': 'application/vnd.github+json',
    'User-Agent': 'Nozelt/${AppMetadata.version}',
  };

  Future<AppRelease?> latest() async {
    final response = await _client
        .get(Uri.parse(latestReleaseApi), headers: _headers)
        .timeout(const Duration(seconds: 20));
    if (response.statusCode != 200) return null;
    return AppRelease.fromGitHubJson(jsonDecode(response.body));
  }

  Future<String> text(String url) async {
    final response = await _client
        .get(Uri.parse(url), headers: {'User-Agent': _headers['User-Agent']!})
        .timeout(const Duration(seconds: 30));
    if (response.statusCode != 200) {
      throw HttpException('HTTP ${response.statusCode}');
    }
    return utf8.decode(response.bodyBytes, allowMalformed: true);
  }

  /// Streams [url] into [file] and returns its SHA-256 (lower-case hex).
  Future<String> download(
    String url,
    File file, {
    required int expectedSize,
    required void Function(double? progress) onProgress,
  }) async {
    final request = http.Request('GET', Uri.parse(url))
      ..headers['User-Agent'] = _headers['User-Agent']!;
    final response = await _client
        .send(request)
        .timeout(const Duration(seconds: 30));
    if (response.statusCode != 200) {
      throw HttpException('HTTP ${response.statusCode}');
    }
    final total = response.contentLength ?? expectedSize;
    final digest = _DigestSink();
    final hasher = sha256.startChunkedConversion(digest);
    final sink = file.openWrite();
    var received = 0;
    try {
      await for (final chunk in response.stream.timeout(
        const Duration(seconds: 60),
      )) {
        sink.add(chunk);
        hasher.add(chunk);
        received += chunk.length;
        onProgress(total > 0 ? (received / total).clamp(0.0, 1.0) : null);
      }
    } finally {
      await sink.close();
    }
    hasher.close();
    if (expectedSize > 0 && received != expectedSize) {
      throw const FileSystemException('Incomplete download.');
    }
    return digest.value.toString();
  }
}

class _DigestSink implements Sink<Digest> {
  late Digest value;

  @override
  void add(Digest data) => value = data;

  @override
  void close() {}
}

final appUpdateClientProvider = Provider<AppUpdateClient>(
  (ref) => AppUpdateClient(),
);

final updatePlatformProvider = Provider<UpdatePlatform?>(
  (ref) => UpdatePlatform.current(),
);

/// Background checks run only in the real app, never in widget tests.
final updateAutoCheckProvider = Provider<bool>(
  (ref) =>
      !kIsWeb &&
      (Platform.isAndroid || Platform.isWindows) &&
      !Platform.environment.containsKey('FLUTTER_TEST'),
);

const _prefsKey = 'app_update_v1';

/// Checks GitHub Releases for a newer Nozelt and installs it on request.
class AppUpdateNotifier extends Notifier<AppUpdateState> {
  Timer? _timer;
  File? _verifiedFile;
  UpdateTarget? _verifiedTarget;

  static const checkInterval = Duration(hours: 6);

  @override
  AppUpdateState build() {
    ref.onDispose(() => _timer?.cancel());
    // Back from the "install unknown apps" setting: continue installing.
    ref.listen<bool>(appResumedProvider, (previous, resumed) {
      if (resumed && state.phase == UpdatePhase.awaitingPermission) {
        unawaited(update());
      }
    });
    final stored = _readPrefs();
    if (ref.watch(updateAutoCheckProvider)) {
      // Startup work comes first; the check is not urgent.
      _timer = Timer(const Duration(seconds: 8), () {
        unawaited(check());
        _timer = Timer.periodic(checkInterval, (_) => unawaited(check()));
      });
    }
    return stored;
  }

  AppUpdateState _readPrefs() {
    final raw = ref.read(sharedPreferencesProvider).getString(_prefsKey);
    if (raw == null) return const AppUpdateState();
    try {
      final json = jsonDecode(raw) as Map;
      return AppUpdateState(
        offerUpdates: json['offerUpdates'] as bool? ?? true,
        dismissedVersion: json['dismissedVersion'] as String?,
      );
    } catch (_) {
      return const AppUpdateState();
    }
  }

  Future<void> _writePrefs() async {
    try {
      await ref
          .read(sharedPreferencesProvider)
          .setString(
            _prefsKey,
            jsonEncode({
              'offerUpdates': state.offerUpdates,
              'dismissedVersion': state.dismissedVersion,
            }),
          );
    } catch (_) {
      // A lost preference only means the banner may show once more.
    }
  }

  /// Looks for a newer release; offline or API errors are silent.
  Future<void> check() async {
    if (state.busy) return;
    try {
      final latest = await ref.read(appUpdateClientProvider).latest();
      if (!ref.mounted) return;
      if (latest != null && latest.isNewerThan(AppMetadata.version)) {
        if (state.release?.version != latest.version) {
          _verifiedFile = null;
          state = AppUpdateState(
            offerUpdates: state.offerUpdates,
            dismissedVersion: state.dismissedVersion,
            release: latest,
          );
        }
      }
    } catch (_) {
      // Offline: try again at the next interval.
    }
  }

  Future<void> setOfferUpdates(bool value) async {
    state = state.copyWith(offerUpdates: value);
    await _writePrefs();
  }

  /// X on the main banner: hidden until an even newer version appears.
  Future<void> dismiss() async {
    final release = state.release;
    if (release == null) return;
    state = state.copyWith(dismissedVersion: release.version.toString());
    await _writePrefs();
  }

  /// Downloads, verifies and installs the release.
  Future<void> update() async {
    final release = state.release;
    if (release == null || state.busy) return;
    final platform = ref.read(updatePlatformProvider);
    if (platform == null) {
      await _openReleasePage(release);
      return;
    }
    // Android: the APK is already verified; the user came back from the
    // "install unknown apps" setting.
    if (_verifiedFile case final File file? when await file.exists()) {
      await _install(platform, release, file, _verifiedTarget!);
      return;
    }
    state = state.copyWith(
      phase: UpdatePhase.downloading,
      progress: 0,
      clearError: true,
    );
    try {
      final target = await platform.target();
      final asset = target == null ? null : selectUpdateAsset(release, target);
      final sumsAsset = release.checksums;
      if (target == null || asset == null || sumsAsset == null) {
        throw const _UpdateFailure('updateNoBuild');
      }
      final client = ref.read(appUpdateClientProvider);
      final sums = parseSha256Sums(await client.text(sumsAsset.downloadUrl));
      final expected = sums[asset.name];
      if (expected == null) throw const _UpdateFailure('updateVerifyFailed');
      final directory = await platform.downloadDirectory(release);
      final partial = File(
        '${directory.path}${Platform.pathSeparator}${asset.name}.part',
      );
      final hash = await client.download(
        asset.downloadUrl,
        partial,
        expectedSize: asset.size,
        onProgress: (value) {
          if (ref.mounted) state = state.copyWith(progress: value);
        },
      );
      if (hash != expected) {
        await _deleteQuietly(partial);
        throw const _UpdateFailure('updateVerifyFailed');
      }
      final file = File(
        '${directory.path}${Platform.pathSeparator}${asset.name}',
      );
      await _deleteQuietly(file);
      await partial.rename(file.path);
      if (!ref.mounted) return;
      _verifiedFile = file;
      _verifiedTarget = target;
      await _install(platform, release, file, target);
    } on _UpdateFailure catch (failure) {
      await _fail(release, failure.key);
    } catch (_) {
      await _fail(release, 'updateDownloadFailed');
    }
  }

  Future<void> _install(
    UpdatePlatform platform,
    AppRelease release,
    File file,
    UpdateTarget target,
  ) async {
    state = state.copyWith(phase: UpdatePhase.installing, clearProgress: true);
    try {
      var reconnect = false;
      if (!target.isAndroid) {
        reconnect =
            ref.read(engineStateProvider).connection ==
            EngineConnectionState.connected;
        // The VPN and its WFP network block stop before Nozelt exits.
        await stopVpnForExit(ref.read);
      }
      final result = await platform.install(
        file,
        target,
        reconnect: reconnect,
      );
      if (!ref.mounted) return;
      if (result == UpdateInstallResult.needsPermission) {
        state = state.copyWith(phase: UpdatePhase.awaitingPermission);
        return;
      }
      if (target.isAndroid) {
        // The system installer is on screen. If the user cancels it, the
        // button installs the same verified file again.
        state = state.copyWith(phase: UpdatePhase.idle);
        return;
      }
      await WindowsShellBridge.instance.requestExit();
    } catch (_) {
      await _fail(release, 'updateInstallFailed');
    }
  }

  Future<void> _fail(AppRelease release, String key) async {
    if (!ref.mounted) return;
    state = state.copyWith(
      phase: UpdatePhase.failed,
      errorKey: key,
      clearProgress: true,
    );
    await _openReleasePage(release);
  }

  Future<void> _openReleasePage(AppRelease release) async {
    try {
      await ref.read(nozeltEngineProvider).openExternalUrl(release.pageUrl);
    } catch (_) {}
  }

  static Future<void> _deleteQuietly(File file) async {
    try {
      if (await file.exists()) await file.delete();
    } catch (_) {}
  }
}

class _UpdateFailure implements Exception {
  const _UpdateFailure(this.key);

  final String key;
}

final appUpdateProvider = NotifierProvider<AppUpdateNotifier, AppUpdateState>(
  AppUpdateNotifier.new,
);

/// Disconnects the VPN and stops the core before Nozelt exits. Exit must not
/// hang on a slow core stop: the network block lives in a dynamic WFP session
/// that Windows removes together with the process anyway.
Future<void> stopVpnForExit(T Function<T>(ProviderListenable<T>) read) async {
  try {
    await () async {
      final engine = read(engineStateProvider);
      if (engine.connection != EngineConnectionState.disconnected ||
          engine.status.networkGuard) {
        await read(engineStateProvider.notifier).disconnect();
      }
      await read(nozeltEngineProvider).stop();
    }().timeout(const Duration(seconds: 10));
  } catch (_) {
    // Leave anyway; the process exit closes the TUN and the filters.
  }
}
