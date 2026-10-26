import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nozelt/src/core/config_builder.dart';
import 'package:nozelt/src/core/multi_core_config_builder.dart';
import 'package:nozelt/src/core/nozelt_engine.dart';
import 'package:nozelt/src/core/profile.dart';
import 'package:nozelt/src/core/proxy_marks.dart';
import 'package:nozelt/src/core/proxy_node.dart';
import 'package:nozelt/src/core/subscription_client.dart';
import 'package:nozelt/src/core/tun_settings.dart';
import 'package:nozelt/src/core/vpn_core.dart';
import 'package:nozelt/src/data/app_preferences.dart';
import 'package:nozelt/src/data/profile_store.dart';
import 'package:nozelt/src/state/engine_provider.dart';
import 'package:nozelt/src/state/nozelt_auto_provider.dart';
import 'package:nozelt/src/state/profiles_provider.dart';
import 'package:nozelt/src/state/settings_provider.dart';

ProxyNode _node(String name, String server, {int port = 443}) =>
    ProxyNode.fromRaw({
      'name': name,
      'type': 'hysteria2',
      'server': server,
      'port': port,
      'password': 'test-only',
    });

Profile _profile(
  List<ProxyNode> nodes, {
  Set<String> pinned = const {},
  Set<String> deleted = const {},
  Map<String, dynamic> providerRouting = const {},
  bool auto = false,
}) => Profile(
  id: 'p',
  name: 'Test',
  type: ProfileType.subscription,
  source: 'https://subscription.example/token',
  nodes: nodes,
  pinnedNodeNames: pinned,
  deletedNodeNames: deleted,
  providerRouting: providerRouting,
  nozeltAuto: auto,
  selectedNodeName: auto ? Profile.nozeltAutoId : null,
);

class _MemoryProfileStore extends ProfileStore {
  _MemoryProfileStore(this.value);

  ProfilesState value;

  @override
  Future<ProfilesState> load() async => value;

  @override
  Future<void> save(ProfilesState state) async => value = state;
}

class _Client extends SubscriptionClient {
  const _Client();

  @override
  Future<SubscriptionDocument> downloadDocument(
    String url, {
    String? userAgent,
  }) async => const SubscriptionDocument(content: 'refreshed');
}

class _RefreshEngine extends NozeltEngine {
  _RefreshEngine(this.nodes);

  List<ProxyNode> nodes;

  @override
  Future<bool> isVpnRequested() async => false;

  @override
  Future<ParsedSubscription> parseSubscriptionDocument(String content) async =>
      ParsedSubscription(
        nodes: nodes,
        metadata: const SubscriptionMetadata(),
        suggestedCore: VpnCore.mihomo,
      );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final a = _node('A', 'a.example');
  final b = _node('B', 'b.example');
  final c = _node('C', 'c.example');

  group('carryNodeMarks', () {
    test('keeps marks of servers that are still there', () {
      expect(carryNodeMarks({'A', 'B'}, [a, b, c], [c, b, a]), {'A', 'B'});
    });

    test('drops marks of servers that left the subscription', () {
      expect(carryNodeMarks({'A', 'B'}, [a, b, c], [a, c]), {'A'});
    });

    test('follows a server the provider renamed', () {
      final renamed = _node('A new name', 'a.example');
      expect(carryNodeMarks({'A'}, [a, b], [renamed, b]), {'A new name'});
    });

    test('does not guess when a rename is ambiguous', () {
      final first = _node('A1', 'a.example');
      final second = _node('A2', 'a.example');
      expect(carryNodeMarks({'A'}, [a, b], [first, second, b]), isEmpty);
    });
  });

  group('Profile marks', () {
    test('survive a JSON round trip and skip unknown names', () {
      final json = _profile([a, b, c], pinned: {'B'}, deleted: {'C'}).toJson();
      expect(json['pinnedNodes'], ['B']);
      expect(json['deletedNodes'], ['C']);
      json['deletedNodes'] = ['C', 'Gone'];
      final restored = Profile.fromJson(
        jsonDecode(jsonEncode(json)) as Map<String, dynamic>,
      );
      expect(restored.pinnedNodeNames, {'B'});
      expect(restored.deletedNodeNames, {'C'});
    });

    test('list pinned first and deleted servers separately', () {
      final profile = _profile([a, b, c], pinned: {'C'}, deleted: {'B'});
      expect(profile.listedNodes.map((n) => n.name), ['C', 'A']);
      expect(profile.deletedNodes.map((n) => n.name), ['B']);
    });

    test('auto server skips deleted servers', () {
      final profile = _profile([a, b, c], deleted: {'A'}, auto: true);
      expect(profile.autoCandidates.map((n) => n.name), ['B', 'C']);
      expect(profile.autoPick?.name, 'B');
      final pick = NozeltAutoServer.choose(
        profile,
        (name) => {'A': 10, 'B': 300, 'C': 200}[name],
      );
      expect(pick, 'C');
    });

    test('with every server deleted the auto server uses the full list', () {
      final profile = _profile([a, b], deleted: {'A', 'B'}, auto: true);
      expect(profile.autoCandidates.map((n) => n.name), ['A', 'B']);
      expect(profile.autoExclusion.isEmpty, isTrue);
    });

    test('manual selection of a deleted server still connects to it', () {
      final profile = _profile(
        [a, b],
        deleted: {'B'},
      ).copyWith(selectedNodeName: 'B');
      expect(profile.effectiveSelectedNodeName, 'B');
    });
  });

  group('subscription refresh', () {
    test('keeps pins and deletions, updates deleted servers and drops '
        'vanished ones', () async {
      SharedPreferences.setMockInitialValues({});
      final preferences = await SharedPreferences.getInstance();
      final store = _MemoryProfileStore(
        ProfilesState(
          profiles: [
            _profile([a, b, c], pinned: {'A', 'C'}, deleted: {'B', 'C'}),
          ],
        ),
      );
      final updatedB = ProxyNode.fromRaw({
        ...b.raw,
        'password': 'new-password',
      });
      final engine = _RefreshEngine([a, updatedB]);
      final container = ProviderContainer(
        overrides: [
          sharedPreferencesProvider.overrideWithValue(preferences),
          nozeltEngineProvider.overrideWithValue(engine),
          profileStoreProvider.overrideWithValue(store),
          subscriptionClientProvider.overrideWithValue(const _Client()),
        ],
      );
      addTearDown(container.dispose);

      await container.read(profilesProvider.future);
      await container.read(profilesProvider.notifier).refresh('p');

      final refreshed = store.value.profiles.single;
      expect(refreshed.pinnedNodeNames, {'A'});
      expect(refreshed.deletedNodeNames, {'B'});
      expect(
        refreshed.nodes.firstWhere((n) => n.name == 'B').raw['password'],
        'new-password',
      );
    });

    test('delete, restore and pin through the notifier', () async {
      SharedPreferences.setMockInitialValues({});
      final preferences = await SharedPreferences.getInstance();
      final store = _MemoryProfileStore(
        ProfilesState(
          profiles: [
            _profile([a, b]),
          ],
          activeId: 'p',
        ),
      );
      final container = ProviderContainer(
        overrides: [
          sharedPreferencesProvider.overrideWithValue(preferences),
          nozeltEngineProvider.overrideWithValue(_RefreshEngine([a, b])),
          profileStoreProvider.overrideWithValue(store),
        ],
      );
      addTearDown(container.dispose);
      await container.read(profilesProvider.future);
      final notifier = container.read(profilesProvider.notifier);

      await notifier.setNodeDeleted('p', 'A', true);
      await notifier.toggleNodePinned('p', 'B');
      expect(store.value.profiles.single.deletedNodeNames, {'A'});
      expect(store.value.profiles.single.pinnedNodeNames, {'B'});

      await notifier.setNodeDeleted('p', 'A', false);
      await notifier.toggleNodePinned('p', 'B');
      expect(store.value.profiles.single.deletedNodeNames, isEmpty);
      expect(store.value.profiles.single.pinnedNodeNames, isEmpty);
    });
  });

  group('automatic groups exclude deleted servers', () {
    const settings = TunSettings();

    List<Map> groupsOf(String config) =>
        ((jsonDecode(config) as Map)['proxy-groups'] as List).cast<Map>();

    test('Mihomo provider url-test group', () {
      final profile = _profile(
        [a, b, c],
        deleted: {'B'},
        providerRouting: {
          'node-names': ['A', 'B', 'C'],
          'proxy-groups': [
            {
              'name': 'Auto',
              'type': 'url-test',
              'proxies': ['A', 'B', 'C'],
              'url': 'https://www.gstatic.com/generate_204',
            },
            {
              'name': 'Pick',
              'type': 'select',
              'proxies': ['A', 'B', 'C'],
            },
          ],
          'rules': ['MATCH,Auto'],
        },
      );
      final config = ConfigBuilder.buildConfig(
        settings,
        nodes: profile.nodes,
        providerRouting: profile.providerRouting,
        autoExclusion: profile.autoExclusion,
      );
      final groups = groupsOf(config);
      final auto = groups.firstWhere((g) => g['type'] == 'url-test');
      final pick = groups.firstWhere(
        (g) => g['type'] == 'select' && g['name'] != 'PROXY',
      );
      final proxy = groups.firstWhere((g) => g['name'] == 'PROXY');
      expect(auto['proxies'], ['A', 'C']);
      // Manual choices keep the deleted server.
      expect(pick['proxies'], ['A', 'B', 'C']);
      expect(proxy['proxies'], containsAll(['A', 'B', 'C']));
    });

    test('a group is never emptied', () {
      final groups = [
        {
          'name': 'Auto',
          'type': 'fallback',
          'proxies': ['B'],
        },
      ];
      ConfigBuilder.excludeDeletedFromAutomaticGroups(groups, [
        'A',
        'B',
      ], const AutoExclusion(names: {'B'}));
      expect(groups.single['proxies'], ['B']);
    });

    test('include-all groups get an exclude-filter', () {
      final groups = <Map<String, dynamic>>[
        {'name': 'Auto', 'type': 'url-test', 'include-all': true},
      ];
      ConfigBuilder.excludeDeletedFromAutomaticGroups(groups, [
        'A',
        'B (1)',
      ], const AutoExclusion(names: {'B (1)'}));
      final filter = RegExp(groups.single['exclude-filter'] as String);
      expect(filter.hasMatch('B (1)'), isTrue);
      expect(filter.hasMatch('A'), isFalse);
    });

    test('Mihomo expanded AUTO entry leaves out copies of deleted servers', () {
      final auto = ProxyNode.fromRaw({
        'name': 'AUTO',
        'type': 'url-test',
        'server': 'a.example',
        'port': 443,
        'nozelt-auto-members': [a.raw, b.raw, c.raw],
      });
      final profile = _profile([auto, a, b, c], deleted: {'B'});
      final config = ConfigBuilder.buildConfig(
        settings,
        nodes: profile.nodes,
        autoExclusion: profile.autoExclusion,
      );
      final group = groupsOf(config).firstWhere((g) => g['name'] == 'AUTO');
      expect(group['proxies'], hasLength(2));
      final proxies = ((jsonDecode(config) as Map)['proxies'] as List)
          .cast<Map>();
      final servers = {
        for (final proxy in proxies)
          if ((group['proxies'] as List).contains(proxy['name']))
            proxy['server'],
      };
      expect(servers, {'a.example', 'c.example'});
    });

    test('Xray balancer leaves out deleted servers', () {
      final document = <String, dynamic>{
        'outbounds': [
          {
            'tag': 'proxy-1',
            'protocol': 'vless',
            'settings': {
              'vnext': [
                {'address': 'a.example', 'port': 443},
              ],
            },
          },
          {
            'tag': 'proxy-2',
            'protocol': 'vless',
            'settings': {'address': 'b.example', 'port': 443},
          },
          {'tag': 'direct', 'protocol': 'freedom'},
        ],
        'routing': {
          'balancers': [
            {
              'tag': 'auto',
              'selector': ['proxy'],
              'fallbackTag': 'proxy-2',
            },
          ],
          'rules': [
            {
              'outboundTag': 'proxy-2',
              'domain': ['example.org'],
            },
          ],
        },
      };
      MultiCoreConfigBuilder.excludeFromXrayBalancers(
        document,
        AutoExclusion.forNodes([a, b], {'B'}),
      );
      final tags = (document['outbounds'] as List)
          .map((item) => (item as Map)['tag'])
          .toList();
      expect(tags[0], 'proxy-1');
      expect(tags[1], isNot(startsWith('proxy')));
      final routing = document['routing'] as Map;
      expect(
        ((routing['balancers'] as List).single as Map)['fallbackTag'],
        tags[1],
      );
      expect(
        ((routing['rules'] as List).single as Map)['outboundTag'],
        tags[1],
      );
    });

    test('sing-box urltest leaves out deleted servers', () {
      final document = <String, dynamic>{
        'outbounds': [
          {
            'type': 'urltest',
            'tag': 'auto',
            'outbounds': ['a', 'b'],
          },
          {
            'type': 'vless',
            'tag': 'a',
            'server': 'a.example',
            'server_port': 443,
          },
          {
            'type': 'vless',
            'tag': 'b',
            'server': 'b.example',
            'server_port': 443,
          },
        ],
      };
      MultiCoreConfigBuilder.excludeFromSingBoxUrlTests(
        document,
        AutoExclusion.forNodes([a, b], {'B'}),
      );
      expect(((document['outbounds'] as List).first as Map)['outbounds'], [
        'a',
      ]);
    });

    test('usesAutomaticGroups sees provider auto groups', () {
      expect(usesAutomaticGroups(_profile([a, b])), isFalse);
      expect(
        usesAutomaticGroups(
          _profile(
            [a, b],
            providerRouting: {
              'proxy-groups': [
                {
                  'name': 'Auto',
                  'type': 'url-test',
                  'proxies': ['A'],
                },
              ],
            },
          ),
        ),
        isTrue,
      );
    });
  });
}
