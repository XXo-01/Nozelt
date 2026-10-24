import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;

import '../core/config_builder.dart';
import '../core/geo_ip_service.dart';
import '../core/models.dart';
import '../core/multi_core_config_builder.dart';
import '../core/notification_ping.dart';
import '../core/profile.dart';
import '../core/proxy_node.dart';
import '../core/vpn_core.dart';
import 'app_lifecycle_provider.dart';
import 'app_settings_provider.dart';
import 'engine_provider.dart';
import 'profiles_provider.dart';
import 'routing_profiles_provider.dart';

class NodeHealthState {
  const NodeHealthState({
    this.testing = const <String>{},
    this.testingAllProfiles = const <String>{},
    this.delays = const <String, NodeDelay>{},
  });

  final Set<String> testing;
  final Set<String> testingAllProfiles;
  final Map<String, NodeDelay> delays;

  bool isTestingAll(String profileId) => testingAllProfiles.contains(profileId);

  bool isTesting(String profileId, String nodeName) =>
      testing.contains(_key(profileId, nodeName));

  NodeDelay? delay(String profileId, String nodeName) =>
      delays[_key(profileId, nodeName)];

  static String _key(String profileId, String nodeName) =>
      '$profileId\u0000$nodeName';
}

class NodeDelay {
  const NodeDelay({required this.milliseconds, required this.checkedAt});

  final int? milliseconds;
  final DateTime checkedAt;
}

class NodeHealthNotifier extends Notifier<NodeHealthState> {
  static const _singlePingDeadline = Duration(seconds: 30);
  static const _allPingDeadline = Duration(seconds: 70);
  Timer? _timer;
  bool _appResumed = true;
  String? _lastTopologySignature;
  String? _lastSelectionSignature;
  bool _resolvingCountries = false;
  final Map<String, String> _countryByServer = {};

  @override
  NodeHealthState build() {
    _appResumed = ref.read(appResumedProvider);
    ref.listen<bool>(appResumedProvider, (_, resumed) {
      _appResumed = resumed;
      if (!resumed && state.testingAllProfiles.isNotEmpty) {
        // An all-node test can otherwise keep several HY2/TLS handshakes alive
        // for minutes after the UI is no longer visible. Go waits for the
        // cancelled workers before returning, without touching the live TUN.
        unawaited(
          ref.read(nozeltEngineProvider).cancelProxyDelayTests().catchError((
            _,
          ) {
            return false;
          }),
        );
      }
      _schedule();
    });
    ref.onDispose(() {
      _timer?.cancel();
    });
    ref.listen(appSettingsProvider, (previous, next) {
      _schedule();
      if (next.onlineGeoIpEnabled &&
          previous?.onlineGeoIpEnabled != next.onlineGeoIpEnabled) {
        final active = ref.read(profilesProvider).value?.active;
        if (active != null) unawaited(ensureCountries(active));
      }
    });
    ref.listen<EngineConnectionState>(
      engineStateProvider.select((value) => value.connection),
      (_, connection) {
        _schedule(forcePing: connection == EngineConnectionState.connected);
        if (connection == EngineConnectionState.connected &&
            ref.read(appSettingsProvider).onlineGeoIpEnabled) {
          final active = ref.read(profilesProvider).value?.active;
          if (active != null) unawaited(ensureCountries(active));
        }
      },
    );
    ref.listen(profilesProvider, (_, next) {
      final active = next.value?.active;
      final topologySignature = _topologySignature(active);
      final selectionSignature = _selectionSignature(active);
      if (topologySignature != _lastTopologySignature ||
          selectionSignature != _lastSelectionSignature) {
        final topologyChanged = topologySignature != _lastTopologySignature;
        _lastTopologySignature = topologySignature;
        _lastSelectionSignature = selectionSignature;
        _retainActiveDelays(active);
        // A selected-node change can immediately reuse that node's own fresh
        // isolated measurement. A topology/core change needs a fresh probe.
        _schedule(forcePing: topologyChanged);
        if (active != null &&
            ref.read(appSettingsProvider).onlineGeoIpEnabled) {
          unawaited(ensureCountries(active));
        }
      }
    });
    Future.microtask(() {
      if (!ref.mounted) return;
      final active = ref.read(profilesProvider).value?.active;
      _lastTopologySignature = _topologySignature(active);
      _lastSelectionSignature = _selectionSignature(active);
      _schedule(forcePing: true);
      if (active != null && ref.read(appSettingsProvider).onlineGeoIpEnabled) {
        unawaited(ensureCountries(active));
      }
    });
    return const NodeHealthState();
  }

  Future<void> pingAll(Profile profile) =>
      _ping(profile, profile.nodes, allNodes: true);

  Future<void> pingNode(Profile profile, ProxyNode node) =>
      _ping(profile, [node], allNodes: false);

  Future<void> _ping(
    Profile profile,
    List<ProxyNode> nodes, {
    required bool allNodes,
  }) async {
    if (!ref.mounted) return;
    if (nodes.isEmpty) return;
    // Native code selects one of two explicit transports: protected sockets
    // while VPN is requested, or direct sockets with encrypted DNS only after
    // Android confirms that VPN is genuinely off. It never falls back to a
    // direct probe during fail-closed recovery.
    final keys = nodes
        .map((node) => NodeHealthState._key(profile.id, node.name))
        .toSet();
    if (keys.any(state.testing.contains)) return;
    state = NodeHealthState(
      testing: {...state.testing, ...keys},
      testingAllProfiles: allNodes
          ? {...state.testingAllProfiles, profile.id}
          : state.testingAllProfiles,
      delays: state.delays,
    );
    // Results arrive incrementally. If the native call itself fails after
    // publishing some nodes, preserve those successful measurements and mark
    // only nodes for which no result was received as unavailable.
    final completedNodeNames = <String>{};
    try {
      final settings = ref.read(effectiveTunSettingsProvider);
      if (profile.effectiveCore == VpnCore.mihomo) {
        final probePlan = ConfigBuilder.buildDelayProbePlan(
          profile.nodes,
          targetNodeNames: nodes.map((node) => node.name),
        );
        final config = await ConfigBuilder.buildConfigAsync(
          settings,
          nodes: profile.nodes,
          selectedNodeName: profile.effectiveSelectedNodeName,
          desktopNativeTun: defaultTargetPlatform == TargetPlatform.windows,
        );
        if (!ref.mounted) return;
        final completed = <String, int?>{};
        final delays = await ref
            .read(nozeltEngineProvider)
            .testProxyDelays(
              configYaml: config,
              names: probePlan.nativeNames,
              testUrlsByName: probePlan.testUrlsByNativeName,
              onResult: (name, delay) {
                if (!ref.mounted) return;
                completed[name] = delay;
                final aggregated = probePlan.aggregateCompleted(completed);
                completedNodeNames.addAll(aggregated.keys);
                _updateDelays(profile.id, aggregated, complete: true);
              },
            )
            .timeout(allNodes ? _allPingDeadline : _singlePingDeadline);
        if (!ref.mounted) return;
        final aggregated = probePlan.aggregate(delays);
        completedNodeNames.addAll(aggregated.keys);
        _updateDelays(profile.id, aggregated);
      } else {
        final names = nodes.map((node) => node.name).toList(growable: false);
        final targets =
            await MultiCoreConfigBuilder.buildNativeProbeTargetsAsync(
              settings,
              profile: profile,
              targetNodeNames: names,
              desktopNativeTun: defaultTargetPlatform == TargetPlatform.windows,
            );
        if (!ref.mounted) return;
        final delays = await ref
            .read(nozeltEngineProvider)
            .testProxyDelays(
              core: profile.effectiveCore,
              configYaml: '',
              names: names,
              nativeTargets: targets,
              onResult: (name, delay) {
                if (!ref.mounted) return;
                completedNodeNames.add(name);
                _updateDelays(profile.id, {name: delay}, complete: true);
              },
            )
            .timeout(allNodes ? _allPingDeadline : _singlePingDeadline);
        if (!ref.mounted) return;
        completedNodeNames.addAll(delays.keys);
        _updateDelays(profile.id, delays);
      }
    } catch (_) {
      if (!ref.mounted) return;
      // Scheduled health checks are best-effort maintenance. A temporary
      // native/network failure must not become an unhandled async exception;
      // mark the attempted nodes unavailable and retry on the next interval.
      _updateDelays(profile.id, {
        for (final node in nodes)
          if (!completedNodeNames.contains(node.name)) node.name: null,
      });
    } finally {
      if (ref.mounted) {
        state = NodeHealthState(
          testing: state.testing.difference(keys),
          testingAllProfiles: allNodes
              ? state.testingAllProfiles.difference({profile.id})
              : state.testingAllProfiles,
          delays: state.delays,
        );
      }
    }
  }

  void _updateDelays(
    String profileId,
    Map<String, int?> values, {
    bool complete = false,
  }) {
    if (!ref.mounted || values.isEmpty) return;
    final checkedAt = DateTime.now();
    final updated = Map<String, NodeDelay>.of(state.delays);
    for (final entry in values.entries) {
      updated[NodeHealthState._key(profileId, entry.key)] = NodeDelay(
        milliseconds: entry.value,
        checkedAt: checkedAt,
      );
    }
    state = NodeHealthState(
      testing: complete
          ? state.testing.difference({
              for (final name in values.keys)
                NodeHealthState._key(profileId, name),
            })
          : state.testing,
      testingAllProfiles: state.testingAllProfiles,
      delays: Map.unmodifiable(updated),
    );

    final active = ref.read(profilesProvider).value?.active;
    final selected = active?.selectedNode;
    if (active != null &&
        selected != null &&
        active.id == profileId &&
        values.containsKey(selected.name)) {
      unawaited(
        ref
            .read(nozeltEngineProvider)
            .updateVpnNotification(
              flag: selected.flagEmoji,
              serverName: selected.displayName,
              pingMs: values[selected.name],
              updatePing: true,
              pingMeasuredAt: checkedAt,
              pingMaxAge: notificationPingMaxAge(
                ref.read(appSettingsProvider).pingIntervalSeconds,
              ),
            )
            .catchError((_) => false),
      );
    }
  }

  void _retainActiveDelays(Profile? active) {
    if (state.delays.isEmpty) return;
    if (active == null) {
      state = NodeHealthState(
        testing: state.testing,
        testingAllProfiles: state.testingAllProfiles,
      );
      return;
    }
    final retained = <String, NodeDelay>{};
    for (final node in active.nodes) {
      final key = NodeHealthState._key(active.id, node.name);
      final delay = state.delays[key];
      if (delay != null) retained[key] = delay;
    }
    if (retained.length == state.delays.length) return;
    state = NodeHealthState(
      testing: state.testing,
      testingAllProfiles: state.testingAllProfiles,
      delays: Map.unmodifiable(retained),
    );
  }

  Future<void> ensureCountries(Profile profile) async {
    if (!ref.mounted) return;
    if (!ref.read(appSettingsProvider).onlineGeoIpEnabled) return;
    // Even though both metadata endpoints use HTTPS, a disconnected lookup
    // would expose the request destination and the user's source network.
    // Automatic GeoIP therefore runs only through Nozelt's active TUN.
    if (ref.read(engineStateProvider).connection !=
        EngineConnectionState.connected) {
      return;
    }
    // On Android, Xray and sing-box exclude Nozelt itself from the VPN, so
    // these lookups would leave from the real address with every server name.
    if (defaultTargetPlatform == TargetPlatform.android &&
        ref.read(profilesProvider).value?.active?.effectiveCore !=
            VpnCore.mihomo) {
      return;
    }
    if (_resolvingCountries) return;
    _resolvingCountries = true;
    final geoClient = http.Client();
    final geoIp = GeoIpService(client: geoClient);
    final pending = <String, String>{};

    Future<void> flushPending() async {
      if (!ref.mounted || pending.isEmpty) return;
      final batch = Map<String, String>.of(pending);
      pending.clear();
      try {
        await ref
            .read(profilesProvider.notifier)
            .setDetectedCountries(profile.id, batch);
      } catch (_) {
        // Country metadata is cosmetic. A failed encrypted profile write
        // must not escape from this unawaited foreground maintenance task.
      }
    }

    try {
      for (final node in profile.nodes) {
        if (!_appResumed ||
            ref.read(engineStateProvider).connection !=
                EngineConnectionState.connected) {
          break;
        }
        if (node.countryCode != null) continue;
        final cacheKey = node.server.trim().toLowerCase();
        final code =
            _countryByServer[cacheKey] ?? await geoIp.detectCountry(node);
        if (!ref.mounted) return;
        if (code != null) {
          if (_countryByServer.length < 4096) {
            _countryByServer[cacheKey] = code;
          }
          pending[node.name] = code;
          // Profile encryption serializes the complete node list. Large
          // batches avoid O(n²) JSON/encrypted-file writes on subscriptions
          // with thousands of nodes while retaining bounded progress.
          if (pending.length >= 512) await flushPending();
        }
      }
    } finally {
      if (ref.mounted) await flushPending();
      geoClient.close();
      _resolvingCountries = false;
    }
  }

  void _schedule({bool forcePing = false}) {
    if (!ref.mounted) return;
    _timer?.cancel();
    _timer = null;
    if (ref.read(engineStateProvider).connection !=
        EngineConnectionState.connected) {
      return;
    }
    final seconds = ref.read(appSettingsProvider).pingIntervalSeconds;
    final profile = ref.read(profilesProvider).value?.active;
    final node = profile?.selectedNode;
    if (profile == null || node == null) return;
    unawaited(
      _syncSelectedNotification(
        profile,
        node,
        intervalSeconds: seconds,
        forcePing: forcePing,
      ),
    );
    if (seconds <= 0) return;
    _timer = Timer.periodic(Duration(seconds: seconds), (_) {
      if (!ref.mounted) return;
      if (ref.read(engineStateProvider).connection !=
          EngineConnectionState.connected) {
        return;
      }
      final currentProfile = ref.read(profilesProvider).value?.active;
      final currentNode = currentProfile?.selectedNode;
      if (currentProfile != null && currentNode != null) {
        unawaited(pingNode(currentProfile, currentNode));
      }
    });
  }

  Future<void> _syncSelectedNotification(
    Profile profile,
    ProxyNode node, {
    required int intervalSeconds,
    required bool forcePing,
  }) async {
    if (!ref.mounted) return;
    final maxAge = notificationPingMaxAge(intervalSeconds);
    final current = state.delay(profile.id, node.name);
    final fresh =
        intervalSeconds > 0 &&
        current != null &&
        current.milliseconds != null &&
        isNotificationPingFresh(
          checkedAt: current.checkedAt,
          now: DateTime.now(),
          maxAge: maxAge,
        );
    if (!forcePing && fresh) {
      await ref
          .read(nozeltEngineProvider)
          .updateVpnNotification(
            flag: node.flagEmoji,
            serverName: node.displayName,
            pingMs: current.milliseconds,
            updatePing: true,
            pingMeasuredAt: current.checkedAt,
            pingMaxAge: maxAge,
          );
      return;
    }

    if (current?.milliseconds != null) {
      final updated = Map<String, NodeDelay>.of(state.delays);
      updated[NodeHealthState._key(profile.id, node.name)] = NodeDelay(
        milliseconds: null,
        checkedAt: DateTime.now(),
      );
      state = NodeHealthState(
        testing: state.testing,
        testingAllProfiles: state.testingAllProfiles,
        delays: Map.unmodifiable(updated),
      );
    }

    await ref
        .read(nozeltEngineProvider)
        .updateVpnNotification(
          flag: node.flagEmoji,
          serverName: node.displayName,
          updatePing: true,
        );
    if (!ref.mounted || intervalSeconds <= 0) return;
    final active = ref.read(profilesProvider).value?.active;
    if (active?.id != profile.id || active?.selectedNode?.name != node.name) {
      return;
    }
    await pingNode(active!, active.selectedNode!);
  }

  static String? _topologySignature(Profile? profile) => profile == null
      ? null
      : '${profile.id}:${profile.topologyRevision}:${profile.effectiveCore.wireName}';

  static String? _selectionSignature(Profile? profile) {
    final node = profile?.selectedNode;
    if (profile == null || node == null) return null;
    return '${profile.id}\u0000${node.name}\u0000${node.server}\u0000${node.port}';
  }
}

final nodeHealthProvider =
    NotifierProvider<NodeHealthNotifier, NodeHealthState>(
      NodeHealthNotifier.new,
    );
