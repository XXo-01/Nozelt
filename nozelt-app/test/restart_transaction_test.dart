import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nozelt/src/core/config_builder.dart';
import 'package:nozelt/src/core/models.dart';
import 'package:nozelt/src/core/nozelt_engine.dart';
import 'package:nozelt/src/core/profile.dart';
import 'package:nozelt/src/core/proxy_node.dart';
import 'package:nozelt/src/core/runtime_rollback.dart';
import 'package:nozelt/src/core/split_tunnel_settings.dart';
import 'package:nozelt/src/core/subscription_client.dart';
import 'package:nozelt/src/core/tun_settings.dart';
import 'package:nozelt/src/core/vpn_core.dart';
import 'package:nozelt/src/data/sensitive_settings_repository.dart';
import 'package:nozelt/src/data/profile_store.dart';
import 'package:nozelt/src/state/engine_provider.dart';
import 'package:nozelt/src/state/network_settings_controller.dart';
import 'package:nozelt/src/state/profiles_provider.dart';
import 'package:nozelt/src/state/settings_provider.dart';
import 'package:nozelt/src/state/split_tunnel_provider.dart';
import 'package:nozelt/src/data/app_preferences.dart';
import 'package:nozelt/src/state/app_settings_provider.dart';
import 'package:nozelt/src/state/app_lifecycle_provider.dart';

const _runningStatus = Status(
  running: true,
  startedAtUnix: 1,
  uptimeSeconds: 1,
  mihomoVersion: 'test',
  nozeltCoreVersion: 'test',
  mode: 'rule',
  tun: TunStatus(enabled: true, stack: 'gvisor', fd: 10),
  socketProtection: true,
);

final _testNode = ProxyNode(
  name: 'Test node',
  type: 'hysteria2',
  server: 'vpn.example',
  port: 443,
  raw: const {
    'name': 'Test node',
    'type': 'hysteria2',
    'server': 'vpn.example',
    'port': 443,
    'password': 'test-only',
  },
);

final _testProfiles = ProfilesState(
  activeId: 'active',
  profiles: [
    Profile(
      id: 'active',
      name: 'Test',
      type: ProfileType.manual,
      source: '',
      nodes: [_testNode],
      selectedNodeName: _testNode.name,
    ),
  ],
);

final _secondNode = ProxyNode(
  name: 'Second node',
  type: 'hysteria2',
  server: 'vpn2.example',
  port: 443,
  raw: const {
    'name': 'Second node',
    'type': 'hysteria2',
    'server': 'vpn2.example',
    'port': 443,
    'password': 'test-only-2',
  },
);

final _switchProfiles = ProfilesState(
  activeId: 'active',
  profiles: [
    ..._testProfiles.profiles,
    Profile(
      id: 'second',
      name: 'Second',
      type: ProfileType.manual,
      source: '',
      nodes: [_secondNode],
      selectedNodeName: _secondNode.name,
    ),
  ],
);

final _subscriptionProfiles = ProfilesState(
  activeId: 'subscription',
  profiles: [
    Profile(
      id: 'subscription',
      name: 'Subscription',
      type: ProfileType.subscription,
      source: 'https://subscription.example/token',
      nodes: [_testNode],
      selectedNodeName: _testNode.name,
      topologyRevision: 7,
    ),
  ],
);

class _MemoryProfileStore extends ProfileStore {
  _MemoryProfileStore(this.value);

  ProfilesState value;

  @override
  Future<ProfilesState> load() async => value;

  @override
  Future<void> save(ProfilesState state) async {
    value = state;
  }
}

class _FixedSubscriptionClient extends SubscriptionClient {
  const _FixedSubscriptionClient();

  @override
  Future<SubscriptionDocument> downloadDocument(
    String url, {
    String? userAgent,
  }) async => const SubscriptionDocument(content: 'updated-test-subscription');
}

class _NegotiatingSubscriptionClient extends SubscriptionClient {
  _NegotiatingSubscriptionClient();

  final List<String?> requestedUserAgents = [];

  @override
  Future<SubscriptionDocument> downloadDocument(
    String url, {
    String? userAgent,
  }) async {
    requestedUserAgents.add(userAgent);
    if (userAgent == SubscriptionClient.xrayUserAgent) {
      return SubscriptionDocument(
        content: 'xray-document',
        metadata: SubscriptionMetadata(
          title: 'examplevpn updated',
          uploadBytes: 2 * 1024 * 1024 * 1024,
          downloadBytes: 3 * 1024 * 1024 * 1024,
          totalBytes: 100 * 1024 * 1024 * 1024,
          expiresAt: DateTime(2027, 1, 2),
          description: 'First line\nSecond line',
          webPageUrl: 'https://t.me/examplevpn_bot',
        ),
      );
    }
    if (userAgent == SubscriptionClient.singBoxUserAgent) {
      return const SubscriptionDocument(content: 'sing-box-document');
    }
    return const SubscriptionDocument(content: 'mihomo-document');
  }
}

class _NegotiatingEngine extends NozeltEngine {
  @override
  Future<bool> isVpnRequested() async => false;

  @override
  Future<ParsedSubscription> parseSubscriptionDocument(String content) async {
    final core = switch (content) {
      'xray-document' => VpnCore.xray,
      'sing-box-document' => VpnCore.singBox,
      _ => VpnCore.mihomo,
    };
    final node = ProxyNode.fromRaw({
      'name': '${core.displayName} node',
      'type': core == VpnCore.mihomo ? 'hysteria2' : 'vless',
      'server': '${core.wireName}.example',
      'port': 443,
      'password': 'test-only',
      if (core != VpnCore.mihomo) 'uuid': 'test-only',
      if (core != VpnCore.mihomo) 'nozelt-native-core': core.wireName,
      if (core != VpnCore.mihomo) 'nozelt-native-config': <String, dynamic>{},
    });
    return ParsedSubscription(
      nodes: [node],
      metadata: const SubscriptionMetadata(),
      suggestedCore: core,
    );
  }
}

class _FixedProfilesNotifier extends ProfilesNotifier {
  @override
  Future<ProfilesState> build() async => _testProfiles;
}

class _RestartFailOnceEngine extends NozeltEngine {
  _RestartFailOnceEngine({this.parsedNodes = const []});

  final List<ProxyNode> parsedNodes;
  int replacementCalls = 0;
  int prepareCalls = 0;
  int startCalls = 0;
  int statusCalls = 0;
  final List<RuntimeRollbackSnapshot?> rollbackSnapshots = [];

  @override
  Future<bool> isVpnRequested() async => false;

  @override
  Future<bool> prepareVpn() async {
    prepareCalls++;
    return true;
  }

  @override
  Future<bool> start(
    String configYaml, {
    String? tunOptionsJson,
    VpnCore core = VpnCore.mihomo,
  }) async {
    startCalls++;
    return true;
  }

  @override
  Future<Status> getStatus() async {
    statusCalls++;
    return _runningStatus;
  }

  @override
  Future<int> restartWithConfig(
    String configYaml, {
    String? tunOptionsJson,
    RuntimeRollbackSnapshot? rollback,
    VpnCore core = VpnCore.mihomo,
  }) async {
    replacementCalls++;
    rollbackSnapshots.add(rollback);
    if (replacementCalls == 1) {
      throw StateError('synthetic replacement failure');
    }
    return replacementCalls;
  }

  @override
  Future<bool> selectProxy(String proxyName) async => true;

  @override
  Future<ParsedSubscription> parseSubscriptionDocument(String content) async =>
      ParsedSubscription(
        nodes: parsedNodes,
        metadata: const SubscriptionMetadata(),
      );
}

class _GatedRestartEngine extends _RestartFailOnceEngine {
  final List<Completer<void>> gates = [];
  int inFlight = 0;
  int maxInFlight = 0;

  @override
  Future<int> restartWithConfig(
    String configYaml, {
    String? tunOptionsJson,
    RuntimeRollbackSnapshot? rollback,
    VpnCore core = VpnCore.mihomo,
  }) async {
    replacementCalls++;
    rollbackSnapshots.add(rollback);
    inFlight++;
    if (inFlight > maxInFlight) maxInFlight = inFlight;
    final gate = Completer<void>();
    gates.add(gate);
    await gate.future;
    inFlight--;
    return replacementCalls;
  }
}

class _DelayedRequestedStateEngine extends NozeltEngine {
  final Completer<bool> requested = Completer<bool>();

  @override
  Future<bool> isVpnRequested() => requested.future;
}

class _TrayEngine extends _RestartFailOnceEngine {
  bool running = false;
  @override
  Future<bool> start(
    String configYaml, {
    String? tunOptionsJson,
    VpnCore core = VpnCore.mihomo,
  }) async {
    startCalls++;
    running = true;
    return true;
  }

  @override
  Future<bool> stop() async {
    running = false;
    return true;
  }

  @override
  Future<Status> getStatus() async {
    statusCalls++;
    return running ? _runningStatus : Status.idle;
  }
}

class _RetainedGuardEngine extends _TrayEngine {
  bool protected = true;
  @override
  Future<Status> getStatus() async => Status(
    running: false,
    startedAtUnix: 0,
    uptimeSeconds: 0,
    mihomoVersion: 'test',
    nozeltCoreVersion: 'test',
    networkGuard: protected,
  );
  @override
  Future<bool> stop() async {
    protected = false;
    return true;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'Windows startup exposes retained protection and explicit stop releases it',
    () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);
      SharedPreferences.setMockInitialValues({});
      final preferences = await SharedPreferences.getInstance();
      final engine = _RetainedGuardEngine();
      final container = ProviderContainer(
        overrides: [
          sharedPreferencesProvider.overrideWithValue(preferences),
          nozeltEngineProvider.overrideWithValue(engine),
        ],
      );
      addTearDown(container.dispose);
      container.read(engineStateProvider);
      await Future<void>.delayed(const Duration(milliseconds: 10));
      expect(
        container.read(engineStateProvider).connection,
        EngineConnectionState.error,
      );
      expect(container.read(engineStateProvider).status.networkGuard, true);
      expect(engine.startCalls, 0);
      await container.read(engineStateProvider.notifier).disconnect();
      expect(engine.protected, false);
      expect(container.read(engineStateProvider).status.networkGuard, false);
    },
  );

  test(
    'Windows silent startup connects once, keeps polling in tray, and respects manual disconnect',
    () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);
      SharedPreferences.setMockInitialValues({});
      final preferences = await SharedPreferences.getInstance();
      final engine = _TrayEngine();
      final container = ProviderContainer(
        overrides: [
          sharedPreferencesProvider.overrideWithValue(preferences),
          nozeltEngineProvider.overrideWithValue(engine),
          profilesProvider.overrideWith(_FixedProfilesNotifier.new),
        ],
      );
      addTearDown(container.dispose);
      // Hidden at initialization, as with --startup --silent.
      container.read(appResumedProvider.notifier).state = false;
      await container.read(appSettingsProvider.notifier).setAutoConnect(true);
      await container.read(profilesProvider.future);
      container.read(engineStateProvider);
      for (var attempt = 0; attempt < 100 && !engine.running; attempt++) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      expect(engine.startCalls, 1);
      expect(
        container.read(engineStateProvider).connection,
        EngineConnectionState.connected,
      );
      final polls = engine.statusCalls;
      await Future<void>.delayed(const Duration(milliseconds: 1100));
      expect(engine.statusCalls, greaterThan(polls));
      await container.read(engineStateProvider.notifier).disconnect();
      container.read(appResumedProvider.notifier).state = true;
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(engine.startCalls, 1);
      expect(
        container.read(engineStateProvider).connection,
        EngineConnectionState.disconnected,
      );
    },
  );

  test(
    'failed TUN replacement propagates and restores previous live settings',
    () async {
      SharedPreferences.setMockInitialValues({});
      final preferences = await SharedPreferences.getInstance();
      final engine = _RestartFailOnceEngine();
      final container = ProviderContainer(
        overrides: [
          sharedPreferencesProvider.overrideWithValue(preferences),
          nozeltEngineProvider.overrideWithValue(engine),
          profilesProvider.overrideWith(_FixedProfilesNotifier.new),
        ],
      );
      addTearDown(container.dispose);

      await container.read(profilesProvider.future);
      expect(_testNode.isUsableOutbound, isTrue);
      expect(
        ConfigBuilder.buildConfig(
          const TunSettings(),
          nodes: [_testNode],
          selectedNodeName: _testNode.name,
        ),
        isNotEmpty,
      );
      expect(
        await ConfigBuilder.buildConfigAsync(
          const TunSettings(),
          nodes: [_testNode],
          selectedNodeName: _testNode.name,
        ),
        isNotEmpty,
      );
      expect(container.read(splitTunnelProvider).apps, isEmpty);
      // Let the initial requested-state restoration observe the fake engine's
      // disconnected flag before starting the explicit test connection.
      await Future<void>.delayed(Duration.zero);
      await container.read(engineStateProvider.notifier).connect();
      expect(engine.prepareCalls, 1);
      expect(engine.startCalls, 1);
      expect(engine.statusCalls, greaterThanOrEqualTo(1));
      expect(
        container.read(engineStateProvider).connection,
        EngineConnectionState.connected,
      );

      await expectLater(
        container.read(networkSettingsControllerProvider).setMtu(1500),
        throwsA(isA<StateError>()),
      );

      // First replacement failed; the controller persisted the old MTU and
      // invoked a second replacement while EngineState was in error.
      expect(engine.replacementCalls, 2);
      expect(engine.rollbackSnapshots.first?.kind, 'tun');
      expect(engine.rollbackSnapshots.last, isNull);
      expect(container.read(tunSettingsProvider).mtu, 9000);
      expect(
        TunSettings.decode(preferences.getString(legacyTunSettingsKey)!).mtu,
        9000,
      );
      expect(
        container.read(engineStateProvider).connection,
        EngineConnectionState.connected,
      );
    },
  );

  test(
    'failed active-profile replacement restores durable and live profile',
    () async {
      SharedPreferences.setMockInitialValues({});
      final preferences = await SharedPreferences.getInstance();
      final engine = _RestartFailOnceEngine();
      final store = _MemoryProfileStore(_switchProfiles);
      final container = ProviderContainer(
        overrides: [
          sharedPreferencesProvider.overrideWithValue(preferences),
          nozeltEngineProvider.overrideWithValue(engine),
          profileStoreProvider.overrideWithValue(store),
        ],
      );
      addTearDown(container.dispose);

      await container.read(profilesProvider.future);
      expect(container.read(splitTunnelProvider).apps, isEmpty);
      await Future<void>.delayed(Duration.zero);
      await container.read(engineStateProvider.notifier).connect();
      expect(
        container.read(engineStateProvider).connection,
        EngineConnectionState.connected,
      );

      await expectLater(
        container.read(profilesProvider.notifier).setActive('second'),
        throwsA(isA<StateError>()),
      );

      expect(engine.replacementCalls, 2);
      expect(engine.rollbackSnapshots.first?.kind, 'profiles');
      expect(engine.rollbackSnapshots.last, isNull);
      expect(container.read(profilesProvider).value?.activeId, 'active');
      expect(store.value.activeId, 'active');
      expect(
        container.read(engineStateProvider).connection,
        EngineConnectionState.connected,
      );
    },
  );

  test(
    'failed active subscription refresh restores previous node definitions',
    () async {
      SharedPreferences.setMockInitialValues({});
      final preferences = await SharedPreferences.getInstance();
      final engine = _RestartFailOnceEngine(parsedNodes: [_secondNode]);
      final store = _MemoryProfileStore(_subscriptionProfiles);
      final container = ProviderContainer(
        overrides: [
          sharedPreferencesProvider.overrideWithValue(preferences),
          nozeltEngineProvider.overrideWithValue(engine),
          profileStoreProvider.overrideWithValue(store),
          subscriptionClientProvider.overrideWithValue(
            const _FixedSubscriptionClient(),
          ),
        ],
      );
      addTearDown(container.dispose);

      await container.read(profilesProvider.future);
      expect(container.read(splitTunnelProvider).apps, isEmpty);
      await Future<void>.delayed(Duration.zero);
      await container.read(engineStateProvider.notifier).connect();

      await expectLater(
        container.read(profilesProvider.notifier).refresh('subscription'),
        throwsA(isA<StateError>()),
      );

      final active = container.read(profilesProvider).value?.active;
      expect(engine.replacementCalls, 2);
      expect(engine.rollbackSnapshots.first?.kind, 'profiles');
      expect(engine.rollbackSnapshots.last, isNull);
      expect(active?.nodes.single.name, _testNode.name);
      expect(active?.topologyRevision, 7);
      expect(store.value.active?.nodes.single.name, _testNode.name);
      expect(
        container.read(engineStateProvider).connection,
        EngineConnectionState.connected,
      );
    },
  );

  test(
    'subscription refresh renegotiates legacy profile and replaces metadata',
    () async {
      SharedPreferences.setMockInitialValues({});
      final preferences = await SharedPreferences.getInstance();
      final client = _NegotiatingSubscriptionClient();
      final store = _MemoryProfileStore(
        ProfilesState(
          profiles: [
            Profile(
              id: 'clev',
              name: 'Old title',
              type: ProfileType.subscription,
              source: 'https://subscription.example/token',
              nodes: [_testNode],
              detectedCore: VpnCore.mihomo,
              subscriptionMetadata: const SubscriptionMetadata(
                description: 'Old description',
                webPageUrl: 'https://t.me/old_bot',
              ),
            ),
          ],
        ),
      );
      final container = ProviderContainer(
        overrides: [
          sharedPreferencesProvider.overrideWithValue(preferences),
          nozeltEngineProvider.overrideWithValue(_NegotiatingEngine()),
          profileStoreProvider.overrideWithValue(store),
          subscriptionClientProvider.overrideWithValue(client),
        ],
      );
      addTearDown(container.dispose);

      await container.read(profilesProvider.future);
      await container.read(profilesProvider.notifier).refresh('clev');

      final refreshed = store.value.profiles.single;
      expect(client.requestedUserAgents, [SubscriptionClient.xrayUserAgent]);
      expect(refreshed.detectedCore, VpnCore.xray);
      expect(refreshed.effectiveCore, VpnCore.xray);
      expect(refreshed.resolvedUserAgent, SubscriptionClient.xrayUserAgent);
      expect(refreshed.name, 'examplevpn updated');
      expect(
        refreshed.subscriptionMetadata?.description,
        'First line\nSecond line',
      );
      expect(
        refreshed.subscriptionMetadata?.telegramUrl,
        'https://t.me/examplevpn_bot',
      );
      expect(refreshed.subscriptionMetadata?.expiresAt, DateTime(2027, 1, 2));
      expect(refreshed.subscriptionMetadata?.usedBytes, 5 * 1024 * 1024 * 1024);
    },
  );

  test(
    'saving a manual core re-downloads the matching subscription format',
    () async {
      SharedPreferences.setMockInitialValues({});
      final preferences = await SharedPreferences.getInstance();
      final client = _NegotiatingSubscriptionClient();
      final store = _MemoryProfileStore(
        ProfilesState(
          profiles: [
            Profile(
              id: 'clev',
              name: 'examplevpn',
              type: ProfileType.subscription,
              source: 'https://subscription.example/token',
              nodes: [_testNode],
              resolvedUserAgent: SubscriptionClient.xrayUserAgent,
              detectedCore: VpnCore.xray,
            ),
          ],
        ),
      );
      final container = ProviderContainer(
        overrides: [
          sharedPreferencesProvider.overrideWithValue(preferences),
          nozeltEngineProvider.overrideWithValue(_NegotiatingEngine()),
          profileStoreProvider.overrideWithValue(store),
          subscriptionClientProvider.overrideWithValue(client),
        ],
      );
      addTearDown(container.dispose);

      await container.read(profilesProvider.future);
      await container
          .read(profilesProvider.notifier)
          .updateDetails(
            'clev',
            name: 'My examplevpn',
            autoUpdateMinutes: 60,
            coreMode: ProfileCoreMode.manual,
            manualCore: VpnCore.singBox,
          );

      final refreshed = store.value.profiles.single;
      expect(client.requestedUserAgents, [SubscriptionClient.singBoxUserAgent]);
      expect(refreshed.name, 'My examplevpn');
      expect(refreshed.coreMode, ProfileCoreMode.manual);
      expect(refreshed.manualCore, VpnCore.singBox);
      expect(refreshed.effectiveCore, VpnCore.singBox);
      expect(refreshed.detectedCore, VpnCore.singBox);
      expect(refreshed.nodes.single.name, 'sing-box node');
      expect(refreshed.resolvedUserAgent, SubscriptionClient.singBoxUserAgent);
    },
  );

  test(
    'failed per-app TUN replacement restores durable and live split policy',
    () async {
      SharedPreferences.setMockInitialValues({});
      final preferences = await SharedPreferences.getInstance();
      final engine = _RestartFailOnceEngine();
      final container = ProviderContainer(
        overrides: [
          sharedPreferencesProvider.overrideWithValue(preferences),
          nozeltEngineProvider.overrideWithValue(engine),
          profilesProvider.overrideWith(_FixedProfilesNotifier.new),
        ],
      );
      addTearDown(container.dispose);

      await container.read(profilesProvider.future);
      expect(container.read(splitTunnelProvider).mode, SplitMode.off);
      await Future<void>.delayed(Duration.zero);
      await container.read(engineStateProvider.notifier).connect();
      await container
          .read(splitTunnelProvider.notifier)
          .setMode(SplitMode.disallowed);

      for (var attempt = 0; attempt < 50; attempt++) {
        if (engine.replacementCalls >= 2) break;
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }

      expect(engine.replacementCalls, 2);
      expect(engine.rollbackSnapshots.first?.kind, 'split');
      expect(engine.rollbackSnapshots.last, isNull);
      expect(container.read(splitTunnelProvider).mode, SplitMode.off);
      expect(
        SplitTunnelSettings.decode(
          preferences.getString(legacySplitTunnelKey)!,
        ).mode,
        SplitMode.off,
      );
      expect(
        container.read(engineStateProvider).connection,
        EngineConnectionState.connected,
      );
    },
  );

  test('live configuration replacements are process-wide serialized', () async {
    SharedPreferences.setMockInitialValues({});
    final preferences = await SharedPreferences.getInstance();
    final engine = _GatedRestartEngine();
    final container = ProviderContainer(
      overrides: [
        sharedPreferencesProvider.overrideWithValue(preferences),
        nozeltEngineProvider.overrideWithValue(engine),
        profilesProvider.overrideWith(_FixedProfilesNotifier.new),
      ],
    );
    addTearDown(container.dispose);

    await container.read(profilesProvider.future);
    expect(container.read(splitTunnelProvider).apps, isEmpty);
    await Future<void>.delayed(Duration.zero);
    await container.read(engineStateProvider.notifier).connect();

    final notifier = container.read(engineStateProvider.notifier);
    final first = notifier.restartWithCurrentConfiguration();
    while (engine.gates.isEmpty) {
      await Future<void>.delayed(Duration.zero);
    }
    final second = notifier.restartWithCurrentConfiguration();
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(engine.replacementCalls, 1);
    expect(engine.maxInFlight, 1);

    engine.gates[0].complete();
    while (engine.gates.length < 2) {
      await Future<void>.delayed(Duration.zero);
    }
    expect(engine.inFlight, 1);
    expect(engine.maxInFlight, 1);
    engine.gates[1].complete();
    await Future.wait([first, second]);

    expect(engine.replacementCalls, 2);
    expect(engine.maxInFlight, 1);
    expect(
      container.read(engineStateProvider).connection,
      EngineConnectionState.connected,
    );
  });

  test(
    'queued replacement recovers the latest union after prior failure',
    () async {
      SharedPreferences.setMockInitialValues({});
      final preferences = await SharedPreferences.getInstance();
      final engine = _RestartFailOnceEngine();
      final container = ProviderContainer(
        overrides: [
          sharedPreferencesProvider.overrideWithValue(preferences),
          nozeltEngineProvider.overrideWithValue(engine),
          profilesProvider.overrideWith(_FixedProfilesNotifier.new),
        ],
      );
      addTearDown(container.dispose);

      await container.read(profilesProvider.future);
      expect(container.read(splitTunnelProvider).apps, isEmpty);
      await Future<void>.delayed(Duration.zero);
      await container.read(engineStateProvider.notifier).connect();

      final notifier = container.read(engineStateProvider.notifier);
      final first = notifier.restartWithCurrentConfiguration();
      final queued = notifier.restartWithCurrentConfiguration();
      await expectLater(first, throwsA(isA<StateError>()));
      await queued;

      expect(engine.replacementCalls, 2);
      expect(
        container.read(engineStateProvider).connection,
        EngineConnectionState.connected,
      );
    },
  );

  test('native-state restoration stops when provider is disposed', () async {
    SharedPreferences.setMockInitialValues({});
    final preferences = await SharedPreferences.getInstance();
    final engine = _DelayedRequestedStateEngine();
    final container = ProviderContainer(
      overrides: [
        sharedPreferencesProvider.overrideWithValue(preferences),
        nozeltEngineProvider.overrideWithValue(engine),
      ],
    );

    container.read(engineStateProvider);
    await Future<void>.delayed(Duration.zero);
    container.dispose();
    engine.requested.complete(false);
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);
  });
}
