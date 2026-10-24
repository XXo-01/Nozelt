import 'dart:async';
import 'dart:convert';
import 'dart:isolate';
import 'dart:io';

import 'package:flutter/services.dart';

import 'app_info.dart';
import 'models.dart';
import 'multi_core_config_builder.dart';
import 'profile.dart';
import 'proxy_node.dart';
import 'runtime_rollback.dart';
import 'vpn_core.dart';
import 'windows_native_bridge.dart';

/// Thin wrapper around the three platform channels exposed by the Android
/// side. Hides the JSON-over-string transport (used because gomobile cannot
/// bind structs) behind typed Dart methods.
///
/// All methods translate `PlatformException` from the channel into a
/// [NozeltEngineException] so the rest of the app does not have to know
/// about Flutter's channel error envelope.
class NozeltEngine {
  NozeltEngine({
    MethodChannel? methodChannel,
    EventChannel? trafficChannel,
    EventChannel? logsChannel,
    WindowsNativeBridge? windowsBridge,
  }) : _methodChannel =
           methodChannel ?? const MethodChannel('dev.nozelt.nozelt/engine'),
       _trafficChannel =
           trafficChannel ?? const EventChannel('dev.nozelt.nozelt/traffic'),
       _logsChannel =
           logsChannel ?? const EventChannel('dev.nozelt.nozelt/logs'),
       _windows =
           windowsBridge ??
           (methodChannel == null && Platform.isWindows
               ? WindowsNativeBridge.open()
               : null) {
    if (_windows == null) {
      _methodChannel.setMethodCallHandler(_handlePlatformMethod);
    }
  }

  final MethodChannel _methodChannel;
  final EventChannel _trafficChannel;
  final EventChannel _logsChannel;
  final WindowsNativeBridge? _windows;
  String? _windowsRuntimeConfig;
  VpnCore _windowsRuntimeCore = VpnCore.mihomo;
  int _windowsGeneration = 0;
  int _delayRequestSequence = 0;
  final Map<String, void Function(String name, int? delay)>
  _delayResultListeners = {};
  final StreamController<String> _routingProfileLinks =
      StreamController<String>.broadcast();
  final StreamController<void> _quickSettingsConnectRequests =
      StreamController<void>.broadcast();

  Future<dynamic> _handlePlatformMethod(MethodCall call) async {
    if (call.method == 'routingProfileLink') {
      final value = call.arguments?.toString();
      if (value != null && value.isNotEmpty) _routingProfileLinks.add(value);
      return null;
    }
    if (call.method == 'quickSettingsConnectRequested') {
      _quickSettingsConnectRequests.add(null);
      return null;
    }
    if (call.method != 'proxyDelayResult') return null;
    final arguments = call.arguments;
    if (arguments is! Map) return null;
    final requestId = arguments['requestId']?.toString();
    final name = arguments['name']?.toString();
    if (requestId == null || name == null) return null;
    final rawDelay = arguments['delay'];
    _delayResultListeners[requestId]?.call(
      name,
      rawDelay is num && rawDelay > 0 ? rawDelay.toInt() : null,
    );
    return null;
  }

  /// Starts the VPN: the foreground service establishes the TUN interface,
  /// hands its fd to the Go engine, then calls `Binding.start(configYaml)`.
  ///
  /// [tunOptionsJson] is a JSON-encoded map of VpnService.Builder parameters
  /// (mtu, address, dns, split-tunnel mode + apps). Passed as a string rather
  /// than a Map so there is no ambiguity marshalling nested lists across the
  /// platform channel. Returns true once the start intent is dispatched;
  /// establish/engine errors surface asynchronously via status polling and
  /// the log stream (the service runs the actual bring-up off-band).
  Future<bool> start(
    String configYaml, {
    String? tunOptionsJson,
    VpnCore core = VpnCore.mihomo,
  }) async {
    final windows = _windows;
    if (windows != null) {
      final result = await Isolate.run(
        () => WindowsNativeBridge.open().startCore(core.wireName, configYaml),
      );
      _requireWindowsOK('start', result);
      _windowsRuntimeConfig = configYaml;
      _windowsRuntimeCore = core;
      _windowsGeneration++;
      return true;
    }
    return _invoke<bool>('start', {
      'core': core.wireName,
      'configYaml': configYaml,
      'tunOptionsJson': ?tunOptionsJson,
    });
  }

  Future<bool> stop() async {
    final windows = _windows;
    if (windows != null) {
      final result = await Isolate.run(() => WindowsNativeBridge.open().stop());
      _requireWindowsOK('stop', result);
      _windowsRuntimeConfig = null;
      return true;
    }
    return _invoke<bool>('stop');
  }

  /// Windows syntax/security preflight. Does not apply the candidate, create a
  /// TUN, install WFP or change the running configuration.
  Future<void> validateWindowsConfiguration(CoreRenderedConfig config) async {
    if (_windows == null) return;
    final coreName = config.core.wireName;
    final document = config.content;
    final result = await Isolate.run(
      () => WindowsNativeBridge.open().validateCoreConfig(coreName, document),
    );
    _requireWindowsOK('validate', result);
  }

  /// Requests a full native TUN/core rebuild using encrypted runtime state.
  Future<bool> prepareWindowsAppRestart() async {
    if (_windows == null) return false;
    final result = await Isolate.run(
      () => WindowsNativeBridge.open().stopForRestart(),
    );
    _requireWindowsOK('prepareWindowsAppRestart', result);
    return true;
  }

  /// Requests a full native TUN/core rebuild using encrypted runtime state.
  Future<bool> restart() async {
    final windows = _windows;
    if (windows != null) {
      final config = _windowsRuntimeConfig;
      if (config == null) return false;
      final coreName = _windowsRuntimeCore.wireName;
      final result = await Isolate.run(() {
        final isolatedBridge = WindowsNativeBridge.open();
        final stopped = isolatedBridge.stopForRestart();
        if (!isolatedBridge.resultOK(stopped)) return stopped;
        return isolatedBridge.startCore(coreName, config);
      });
      _requireWindowsOK('restart', result);
      _windowsGeneration++;
      return true;
    }
    return _invoke<bool>('restart');
  }

  /// Atomically replaces encrypted runtime state and requests a full rebuild.
  /// Resolves with the new successful-start generation only after the native
  /// service has completed the replacement.
  Future<int> restartWithConfig(
    String configYaml, {
    String? tunOptionsJson,
    RuntimeRollbackSnapshot? rollback,
    VpnCore core = VpnCore.mihomo,
  }) async {
    final windows = _windows;
    if (windows != null) {
      final status = await getStatus();
      final result = await Isolate.run(() {
        final isolatedBridge = WindowsNativeBridge.open();
        if (status.running || status.tun.enabled || status.networkGuard) {
          final stopped = isolatedBridge.stopForRestart();
          if (!isolatedBridge.resultOK(stopped)) return stopped;
        }
        return isolatedBridge.startCore(core.wireName, configYaml);
      });
      _requireWindowsOK('restartWithConfig', result);
      _windowsRuntimeConfig = configYaml;
      _windowsRuntimeCore = core;
      return ++_windowsGeneration;
    }
    return _invoke<int>('restartWithConfig', {
      'core': core.wireName,
      'configYaml': configYaml,
      'tunOptionsJson': ?tunOptionsJson,
      if (rollback != null) 'rollbackKind': rollback.kind,
      if (rollback != null) 'rollbackPayload': rollback.payload,
    });
  }

  /// Reads the service's tiny persisted desired-state flag without loading the
  /// Go/mihomo runtime. Used to keep disconnected cold starts fast.
  Future<bool> isVpnRequested() async {
    final windows = _windows;
    if (windows != null) {
      // Desired state survives a crashed core so the poller can recover it.
      // Explicit stop clears this session-local snapshot.
      return _windowsRuntimeConfig != null;
    }
    return _invoke<bool>('isVpnRequested');
  }

  /// True when Android, rather than the in-app button, owns this VPN's
  /// lifecycle. This lightweight service flag does not initialize Go.
  Future<bool> isAlwaysOnVpn() =>
      _windows == null ? _invoke<bool>('isAlwaysOnVpn') : Future.value(false);

  Future<VpnPolicyState> getVpnPolicyState() async {
    if (_windows != null) {
      return const VpnPolicyState(
        alwaysOn: false,
        lockdown: false,
        lockdownKnown: false,
      );
    }
    final value = await _invoke<Map<dynamic, dynamic>>('getVpnPolicyState');
    return VpnPolicyState(
      alwaysOn: value['alwaysOn'] == true,
      lockdown: value['lockdown'] == true,
      lockdownKnown: value['lockdownKnown'] == true,
    );
  }

  /// Opens Android's system page for Always-on VPN and lockdown mode.
  Future<bool> openVpnSettings() =>
      _windows == null ? _invoke<bool>('openVpnSettings') : Future.value(false);

  Future<bool> openExternalUrl(String value) {
    final uri = Uri.tryParse(value);
    if (uri == null ||
        !uri.isScheme('https') ||
        uri.host.isEmpty ||
        value.length > 8192) {
      return Future.value(false);
    }
    if (_windows == null) {
      return _invoke<bool>('openExternalUrl', {'url': uri.toString()});
    }
    return _openWindowsExternalUrl(uri);
  }

  Future<bool> _openWindowsExternalUrl(Uri uri) async {
    try {
      final process = await Process.start('explorer.exe', [
        uri.toString(),
      ], mode: ProcessStartMode.detached);
      return process.pid > 0;
    } catch (_) {
      return false;
    }
  }

  /// Returns a stable, app-scoped device UUID for subscription panels that
  /// implement the standard `x-hwid` device-limit header. The raw Android ID
  /// never crosses the platform boundary.
  Future<String?> getSubscriptionHwid() async {
    if (_windows case final windows?) {
      return windows.getSubscriptionHwid();
    }
    return _invoke<String>('getSubscriptionHwid');
  }

  /// Keeps native foreground-service text aligned with the in-app locale.
  Future<bool> setPreferredLanguage(String code) => _windows == null
      ? _invoke<bool>('setPreferredLanguage', {'code': code})
      : Future.value(true);

  /// Updates the public, non-sensitive server line in Android's VPN notification.
  Future<bool> updateVpnNotification({
    required String flag,
    required String serverName,
    int? pingMs,
    bool updatePing = false,
    DateTime? pingMeasuredAt,
    Duration? pingMaxAge,
  }) => _windows == null
      ? _invoke<bool>('updateVpnNotification', {
          'flag': flag,
          'serverName': serverName,
          if (updatePing) ...{
            'pingMs': pingMs,
            if (pingMeasuredAt != null)
              'pingMeasuredAtMs': pingMeasuredAt.millisecondsSinceEpoch,
            if (pingMaxAge != null) 'pingMaxAgeMs': pingMaxAge.inMilliseconds,
          },
        })
      : Future.value(true);

  /// Cold-start and live requests emitted by the Android Quick Settings tile.
  Stream<void> quickSettingsConnectRequests() =>
      _quickSettingsConnectRequests.stream;

  Future<bool> consumeQuickSettingsConnectRequest() => _windows == null
      ? _invoke<bool>('consumeQuickSettingsConnectRequest')
      : Future.value(false);

  /// Refreshes the native GeoIP/GeoSite assets used by Xray. Mihomo and
  /// sing-box consume their configured update URLs/rule sets on the ensuing
  /// transactional configuration restart.
  Future<bool> updateGeoData() async {
    if (_windows == null) return _invoke<bool>('updateGeoData');
    final result = await Isolate.run(
      () => WindowsNativeBridge.open().updateGeoData(),
    );
    _requireWindowsOK('updateGeoData', result);
    return true;
  }

  Stream<String> routingProfileLinks() => _routingProfileLinks.stream;

  Future<String?> getInitialRoutingProfileLink() => _windows == null
      ? _invoke<String?>('getInitialRoutingProfileLink')
      : Future.value();

  /// Changes the live PROXY selector for new connections without rebuilding
  /// the Android TUN.
  Future<bool> selectProxy(String proxyName) async {
    final windows = _windows;
    if (windows != null) {
      _requireWindowsOK('selectProxy', windows.selectProxy('PROXY', proxyName));
      return true;
    }
    return _invoke<bool>('selectProxy', {
      'groupName': 'PROXY',
      'proxyName': proxyName,
    });
  }

  /// Applies a TUN-compatible config update without recreating VpnService.
  Future<bool> reloadConfig(
    String configYaml, {
    String? tunOptionsJson,
    RuntimeRollbackSnapshot? rollback,
    VpnCore core = VpnCore.mihomo,
  }) async {
    final windows = _windows;
    if (windows != null) {
      final result = await Isolate.run(
        () => WindowsNativeBridge.open().reload(configYaml),
      );
      _requireWindowsOK('reloadConfig', result);
      _windowsRuntimeConfig = configYaml;
      return true;
    }
    return _invoke<bool>('reloadConfig', {
      'core': core.wireName,
      'configYaml': configYaml,
      'tunOptionsJson': ?tunOptionsJson,
      if (rollback != null) 'rollbackKind': rollback.kind,
      if (rollback != null) 'rollbackPayload': rollback.payload,
    });
  }

  Future<Status> getStatus() async {
    final windows = _windows;
    if (windows != null) {
      final raw = await Isolate.run(
        () => WindowsNativeBridge.open().getStatus(),
      ).timeout(const Duration(seconds: 4));
      return Status.fromJson(jsonDecode(raw) as Map<String, dynamic>);
    }
    // A wedged third-party shutdown/recovery must not leave Riverpod's single
    // in-flight poll stuck forever with a stale "connected" UI. The native
    // call normally completes in milliseconds; four seconds still allows a
    // busy lifecycle lock to drain before Dart treats it as unavailable.
    final raw = await _invokeWithTimeout<String>(
      'getStatus',
      const Duration(seconds: 4),
    );
    return Status.fromJson(jsonDecode(raw) as Map<String, dynamic>);
  }

  /// Compares with encrypted native runtime state without exposing that state.
  Future<bool> matchesRuntimeConfig(
    String configYaml, {
    String? tunOptionsJson,
    VpnCore core = VpnCore.mihomo,
  }) async {
    if (_windows != null) {
      final status = await getStatus();
      return status.running && _windowsRuntimeConfig == configYaml;
    }
    return _invoke<bool>('matchesRuntimeConfig', {
      'core': core.wireName,
      'configYaml': configYaml,
      'tunOptionsJson': ?tunOptionsJson,
    });
  }

  Future<EngineVersions> getVersion() async {
    final raw = _windows?.getVersion() ?? await _invoke<String>('getVersion');
    return EngineVersions.fromJson(jsonDecode(raw) as Map<String, dynamic>);
  }

  /// Triggers the system VPN consent dialog if needed. Returns `true` when
  /// permission is granted (either already, or after the user accepted the
  /// dialog), `false` if the user declined.
  Future<bool> prepareVpn() =>
      _windows == null ? _invoke<bool>('prepareVpn') : Future.value(true);

  /// Opens Android's document picker and returns one bounded config document.
  /// Bytes are read by the native content resolver, so no broad storage
  /// permission or third-party file picker is required.
  Future<PickedConfigFile?> pickConfigFile() async {
    if (_windows != null) {
      final path = _windows.pickConfigFile();
      if (path.isEmpty) return null;
      final file = File(path);
      final bytes = await file.readAsBytes();
      if (bytes.length > 16 * 1024 * 1024) {
        throw const NozeltEngineException(
          method: 'pickConfigFile',
          code: 'file_too_large',
          message: '<file exceeds safe size>',
        );
      }
      return PickedConfigFile(
        name: file.uri.pathSegments.isEmpty
            ? 'profile.yaml'
            : file.uri.pathSegments.last,
        bytes: bytes,
      );
    }
    try {
      final value = await _methodChannel.invokeMapMethod<String, dynamic>(
        'pickConfigFile',
      );
      if (value == null) return null;
      final name = value['name'];
      final bytes = value['bytes'];
      if (name is! String || bytes is! Uint8List) {
        throw const FormatException('invalid native file result');
      }
      return PickedConfigFile(name: name, bytes: bytes);
    } on PlatformException catch (error) {
      throw NozeltEngineException(
        method: 'pickConfigFile',
        code: error.code,
        message: error.message ?? '<no message>',
        details: error.details,
      );
    }
  }

  /// Lists installed apps (label + package + system flag) for the split-tunnel
  /// picker. Icons are fetched separately via [getAppIcon] so this call stays
  /// cheap. Our own package is excluded by the platform side.
  Future<List<AppInfo>> getInstalledApps() async {
    final raw = await _invoke<List<dynamic>>('getInstalledApps');
    return raw.map((e) => AppInfo.fromMap(e as Map)).toList(growable: false);
  }

  /// Fetches one app's icon as raw PNG bytes, or null when the package has no
  /// resolvable icon (the UI shows a placeholder). Cached by the caller.
  Future<Uint8List?> getAppIcon(String packageName) async {
    try {
      return await _methodChannel.invokeMethod<Uint8List>('getAppIcon', {
        'packageName': packageName,
      });
    } on PlatformException {
      return null;
    }
  }

  /// Parses a single proxy share link via the Go `convert` engine. Throws
  /// [NozeltEngineException] with the Go-side message when the link is
  /// unsupported or malformed.
  Future<ProxyNode> parseProxyLink(String link) async {
    final raw = _windows != null
        ? await Isolate.run(
            () => WindowsNativeBridge.open().parseProxyLink(link),
          )
        : await _invoke<String>('parseProxyLink', {'link': link});
    final map = jsonDecode(raw) as Map<String, dynamic>;
    if (map['ok'] != true) {
      throw NozeltEngineException(
        method: 'parseProxyLink',
        code: 'parse_failed',
        message: (map['error'] ?? 'could not parse link').toString(),
      );
    }
    final node = ProxyNode.normalizeNames([
      ProxyNode.fromRaw((map['proxy'] as Map).cast<String, dynamic>()),
    ]).single;
    if (!node.isUsableOutbound) {
      throw const NozeltEngineException(
        method: 'parseProxyLink',
        code: 'invalid_proxy',
        message: 'parsed link did not contain a usable remote proxy',
      );
    }
    return node;
  }

  /// Parses already-downloaded subscription content (base64 / plain link list /
  /// Clash YAML) via the Go `convert` engine. Also used for the manual
  /// multi-link textarea and for imported YAML files. Throws on total failure;
  /// a partially-valid subscription returns just the nodes that parsed.
  Future<List<ProxyNode>> parseSubscription(String content) async =>
      (await parseSubscriptionDocument(content)).nodes;

  Future<ParsedSubscription> parseSubscriptionDocument(String content) async {
    final raw = _windows != null
        ? await Isolate.run(
            () => WindowsNativeBridge.open().parseSubscription(content),
          )
        : await _invoke<String>('parseSubscription', {'content': content});
    final decoded = await Isolate.run(() => _decodeSubscription(raw));
    if (!decoded.ok) {
      throw NozeltEngineException(
        method: 'parseSubscription',
        code: 'parse_failed',
        message: decoded.error ?? 'could not parse subscription',
      );
    }
    return ParsedSubscription(
      nodes: decoded.nodes,
      providerRouting: decoded.providerRouting,
      suggestedCore: decoded.suggestedCore,
      metadata: SubscriptionMetadata(
        title: decoded.profileName,
        description: decoded.description,
        webPageUrl: decoded.webPageUrl,
      ),
    );
  }

  /// Runs comparable established-path URL tests for concrete proxy outbounds.
  /// Returns null for failed/timed-out nodes.
  Future<Map<String, int?>> testProxyDelays({
    VpnCore core = VpnCore.mihomo,
    required String configYaml,
    required List<String> names,
    List<NativeCoreProbeTarget> nativeTargets = const [],
    String testUrl = 'http://www.gstatic.com/generate_204',
    Map<String, String> testUrlsByName = const {},
    void Function(String name, int? delay)? onResult,
    // Unified delay performs its warm-up and measured request inside this
    // ceiling. Five seconds keeps slow HY2 handshakes viable while preventing
    // one unreachable endpoint from holding a profile check for a minute.
    int timeoutMs = 5000,
  }) async {
    final namesJson = testUrlsByName.isEmpty
        ? jsonEncode(names)
        : jsonEncode([
            for (final name in names)
              {'name': name, 'url': ?testUrlsByName[name]},
          ]);
    final windows = _windows;
    if (core != VpnCore.mihomo && nativeTargets.length != names.length) {
      throw ArgumentError('Every native delay target requires a core config.');
    }
    final requestId = 'delay-${++_delayRequestSequence}';
    if (windows == null && onResult != null) {
      _delayResultListeners[requestId] = onResult;
    }
    try {
      final windowsOffline = windows != null && core == VpnCore.mihomo
          ? !(await getStatus()).running
          : false;
      final raw = windows != null
          ? await _testWindowsProxyDelays(
              windows,
              core: core,
              configYaml: configYaml,
              namesJson: namesJson,
              nativeTargets: nativeTargets,
              testUrl: testUrl,
              timeoutMs: timeoutMs,
              offline: windowsOffline,
              onResult: onResult,
            )
          : await _invoke<String>('testProxyDelays', {
              'requestId': requestId,
              'core': core.wireName,
              'configYaml': configYaml,
              'namesJson': namesJson,
              if (core != VpnCore.mihomo)
                'nativeTargetsJson': jsonEncode([
                  for (final target in nativeTargets) target.toJson(),
                ]),
              'testUrl': testUrl,
              'timeoutMs': timeoutMs,
            });
      final envelope = jsonDecode(raw) as Map<String, dynamic>;
      if (envelope['ok'] != true) {
        throw NozeltEngineException(
          method: 'testProxyDelays',
          code: 'delay_test_failed',
          message: (envelope['error'] ?? 'delay test failed').toString(),
        );
      }
      final results =
          (envelope['results'] as Map?)?.cast<String, dynamic>() ??
          const <String, dynamic>{};
      final decoded = {
        for (final name in names)
          name: switch (results[name]) {
            final Map value when value['delay'] is num =>
              (value['delay'] as num).toInt(),
            _ => null,
          },
      };
      return decoded;
    } finally {
      _delayResultListeners.remove(requestId);
    }
  }

  Future<String> _testWindowsProxyDelays(
    WindowsNativeBridge windows, {
    required VpnCore core,
    required String configYaml,
    required String namesJson,
    required List<NativeCoreProbeTarget> nativeTargets,
    required String testUrl,
    required int timeoutMs,
    required bool offline,
    required void Function(String name, int? delay)? onResult,
  }) async {
    final begin =
        jsonDecode(
              windows.beginProxyDelays(
                core: core.wireName,
                config: configYaml,
                namesJson: namesJson,
                targetsJson: jsonEncode([
                  for (final target in nativeTargets) target.toJson(),
                ]),
                testUrl: testUrl,
                timeoutMs: timeoutMs,
                offline: offline,
              ),
            )
            as Map<String, dynamic>;
    if (begin['ok'] != true || begin['jobId'] is! String) {
      throw NozeltEngineException(
        method: 'testProxyDelays',
        code: 'delay_test_failed',
        message: (begin['error'] ?? 'could not start delay test').toString(),
      );
    }
    final jobId = begin['jobId'] as String;
    while (true) {
      await Future<void>.delayed(const Duration(milliseconds: 40));
      final poll =
          jsonDecode(windows.pollProxyDelays(jobId)) as Map<String, dynamic>;
      if (poll['ok'] != true) {
        throw NozeltEngineException(
          method: 'testProxyDelays',
          code: 'delay_test_failed',
          message: (poll['error'] ?? 'could not read delay test').toString(),
        );
      }
      final updates = poll['updates'];
      if (updates is List && onResult != null) {
        for (final raw in updates.whereType<Map>()) {
          final name = raw['name']?.toString();
          if (name == null || name.isEmpty) continue;
          final delay = raw['delay'];
          onResult(name, delay is num && delay > 0 ? delay.toInt() : null);
        }
      }
      if (poll['done'] == true) {
        final response = poll['response'];
        if (response is String && response.isNotEmpty) return response;
        throw const NozeltEngineException(
          method: 'testProxyDelays',
          code: 'delay_test_failed',
          message: 'delay test completed without a response',
        );
      }
    }
  }

  /// Cancels temporary latency probes without stopping the active VPN.
  Future<bool> cancelProxyDelayTests() async {
    final windows = _windows;
    if (windows != null) {
      windows.cancelDelayTests();
      return true;
    }
    return _invoke<bool>('cancelDelayTests');
  }

  /// 1 Hz stream of traffic snapshots emitted by [TrafficStreamHandler].
  /// Decode errors are logged-ish-ly via `addError`; consumers should treat
  /// the stream as best-effort.
  Stream<Traffic> trafficStream() {
    if (_windows != null) return _windowsTrafficStream();
    return _trafficChannel.receiveBroadcastStream().map((event) {
      final map = jsonDecode(event as String) as Map<String, dynamic>;
      return Traffic.fromJson(map);
    });
  }

  /// Stream of log lines emitted by the Go core through `binding.SetLogger`.
  Stream<LogEntry> logsStream() {
    if (_windows != null) return _windowsLogsStream();
    return _logsChannel.receiveBroadcastStream().map((event) {
      final map = jsonDecode(event as String) as Map<String, dynamic>;
      return LogEntry.fromJson(map);
    });
  }

  Future<List<DesktopConnection>> getConnections() async {
    final windows = _windows;
    if (windows == null) return const [];
    final raw = await Isolate.run(
      () => WindowsNativeBridge.open().getConnections(),
    );
    final decoded = jsonDecode(raw) as List<dynamic>;
    return decoded
        .map(
          (value) => DesktopConnection.fromJson(
            (value as Map).cast<String, dynamic>(),
          ),
        )
        .toList(growable: false);
  }

  Future<bool> closeConnection(String id) async =>
      _windows?.closeConnection(id) ?? false;

  Future<int> closeAllConnections() async =>
      _windows?.closeAllConnections() ?? 0;

  Future<bool> clearLogs() async {
    final windows = _windows;
    if (windows == null) return false;
    windows.clearLogs();
    return true;
  }

  Stream<Traffic> _windowsTrafficStream() {
    Timer? timer;
    var polling = false;
    late final StreamController<Traffic> controller;
    Future<void> poll() async {
      final windows = _windows;
      if (windows == null || controller.isClosed || polling) return;
      polling = true;
      try {
        final raw = await Isolate.run(
          () => WindowsNativeBridge.open().getTraffic(),
        );
        if (controller.isClosed) return;
        controller.add(
          Traffic.fromJson(jsonDecode(raw) as Map<String, dynamic>),
        );
      } catch (_) {
        if (!controller.isClosed) {
          controller.addError(
            StateError('Windows traffic data is unavailable.'),
          );
        }
      } finally {
        polling = false;
      }
    }

    controller = StreamController<Traffic>(
      onListen: () {
        poll();
        timer = Timer.periodic(const Duration(seconds: 1), (_) => poll());
      },
      onCancel: () => timer?.cancel(),
    );
    return controller.stream;
  }

  Stream<LogEntry> _windowsLogsStream() {
    var emitted = 0;
    Timer? timer;
    late final StreamController<LogEntry> controller;
    void poll() {
      final windows = _windows;
      if (windows == null || controller.isClosed) return;
      try {
        final value = jsonDecode(windows.getLogs());
        final decoded = value is List<dynamic> ? value : const <dynamic>[];
        // The native buffer keeps the newest 2000 lines; once it is full its
        // length stops growing, so new lines are found by sequence number.
        for (final value in decoded) {
          final map = (value as Map).cast<String, dynamic>();
          final sequence = (map['seq'] as num?)?.toInt();
          if (sequence != null) {
            if (sequence <= emitted) continue;
            emitted = sequence;
          }
          controller.add(LogEntry.fromJson(map));
        }
      } catch (_) {
        controller.addError(StateError('Windows logs are unavailable.'));
      }
    }

    controller = StreamController<LogEntry>(
      onListen: () {
        poll();
        timer = Timer.periodic(
          const Duration(milliseconds: 500),
          (_) => poll(),
        );
      },
      onCancel: () => timer?.cancel(),
    );
    return controller.stream;
  }

  void _requireWindowsOK(String method, String raw) {
    final decoded = jsonDecode(raw);
    if (decoded is Map && decoded['ok'] == true) return;
    throw NozeltEngineException(
      method: method,
      code: decoded is Map
          ? decoded['error']?.toString() ?? 'failed'
          : 'failed',
      message: '<native operation failed>',
      // Only display text such as the other VPN's program name.
      details: decoded is Map ? decoded['detail']?.toString() : null,
    );
  }

  Future<T> _invoke<T>(String method, [Map<String, dynamic>? args]) async {
    try {
      final result = await _methodChannel.invokeMethod<T>(method, args);
      if (result == null) {
        throw NozeltEngineException(
          method: method,
          code: 'null_result',
          message: 'platform returned null for $method',
        );
      }
      return result;
    } on PlatformException catch (e) {
      throw NozeltEngineException(
        method: method,
        code: e.code,
        message: e.message ?? '<no message>',
        details: e.details,
      );
    }
  }

  Future<T> _invokeWithTimeout<T>(
    String method,
    Duration timeout, [
    Map<String, dynamic>? args,
  ]) async {
    try {
      return await _invoke<T>(method, args).timeout(timeout);
    } on TimeoutException {
      throw NozeltEngineException(
        method: method,
        code: 'timeout',
        message: 'platform call timed out',
      );
    }
  }
}

class _DecodedSubscription {
  const _DecodedSubscription({
    required this.ok,
    required this.nodes,
    this.profileName,
    this.description,
    this.webPageUrl,
    this.suggestedCore = VpnCore.mihomo,
    this.error,
    this.providerRouting = const {},
  });

  final bool ok;
  final List<ProxyNode> nodes;
  final String? profileName;
  final String? description;
  final String? webPageUrl;
  final VpnCore suggestedCore;
  final String? error;
  final Map<String, dynamic> providerRouting;
}

class ParsedSubscription {
  const ParsedSubscription({
    required this.nodes,
    required this.metadata,
    this.suggestedCore = VpnCore.mihomo,
    this.providerRouting = const {},
  });

  final List<ProxyNode> nodes;
  final SubscriptionMetadata metadata;
  final VpnCore suggestedCore;
  final Map<String, dynamic> providerRouting;
}

_DecodedSubscription _decodeSubscription(String raw) {
  final map = jsonDecode(raw) as Map<String, dynamic>;
  if (map['ok'] != true) {
    return _DecodedSubscription(
      ok: false,
      nodes: const [],
      error: (map['error'] ?? 'could not parse subscription').toString(),
    );
  }
  final parsed = ((map['proxies'] as List?) ?? const [])
      .map((value) => ProxyNode.fromRaw((value as Map).cast<String, dynamic>()))
      .where((node) => node.isUsableOutbound)
      .toList(growable: false);
  return _DecodedSubscription(
    ok: true,
    nodes: ProxyNode.normalizeNames(parsed),
    profileName: _optionalEnvelopeText(map['profileName'], maxProfileNameRunes),
    description: _optionalEnvelopeText(
      map['description'],
      maxSubscriptionDescriptionRunes,
    ),
    webPageUrl: _optionalEnvelopeText(map['webPageUrl'], 8192),
    suggestedCore: VpnCore.fromWireName(map['suggestedCore']),
    providerRouting:
        (map['providerRouting'] as Map?)?.cast<String, dynamic>() ?? const {},
  );
}

String? _optionalEnvelopeText(Object? value, int maxRunes) {
  final text = value?.toString().trim();
  if (text == null || text.isEmpty) return null;
  return String.fromCharCodes(text.runes.take(maxRunes));
}

class VpnPolicyState {
  const VpnPolicyState({
    required this.alwaysOn,
    required this.lockdown,
    required this.lockdownKnown,
  });

  final bool alwaysOn;
  final bool lockdown;
  final bool lockdownKnown;
}

class PickedConfigFile {
  const PickedConfigFile({required this.name, required this.bytes});

  final String name;
  final Uint8List bytes;
}

/// Thrown when the platform channel reports an error or returns null.
class NozeltEngineException implements Exception {
  const NozeltEngineException({
    required this.method,
    required this.code,
    required this.message,
    this.details,
  });

  final String method;
  final String code;
  final String message;
  final Object? details;

  /// Crash reporters and Flutter's uncaught-error handler call `toString()`.
  /// Platform messages are retained for in-process diagnosis but are never
  /// rendered here because an upstream exception may contain a subscription
  /// URL, proxy endpoint, or other credential-bearing input.
  @override
  String toString() => 'NozeltEngineException($method, $code)';
}
