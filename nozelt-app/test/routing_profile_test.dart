import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:nozelt/src/core/config_builder.dart';
import 'package:nozelt/src/core/multi_core_config_builder.dart';
import 'package:nozelt/src/core/profile.dart';
import 'package:nozelt/src/core/proxy_node.dart';
import 'package:nozelt/src/core/routing_profile.dart';
import 'package:nozelt/src/core/routing_rule.dart';
import 'package:nozelt/src/core/split_tunnel_settings.dart';
import 'package:nozelt/src/core/tun_settings.dart';
import 'package:nozelt/src/core/vpn_core.dart';

void main() {
  test(
    'shared Windows process rules survive links but never enter Android configs',
    () {
      const rule = RoutingRule(
        id: 'steam',
        type: RoutingRuleType.processName,
        value: 'Steam.EXE',
        action: RoutingRuleAction.reject,
      );
      const routing = RoutingProfile(
        id: 'portable',
        name: 'Portable',
        rules: [rule],
        split: SplitTunnelSettings(
          mode: SplitMode.disallowed,
          apps: {'com.example.bank'},
        ),
      );
      final imported = RoutingProfile.decodeShareLink(
        routing.encodeShareLink(),
        id: 'copy',
      );
      expect(imported.rules.single.normalizedValue, 'steam.exe');
      expect(imported.split.apps, {'com.example.bank'});
      final settings = const TunSettings().copyWith(
        customRules: imported.rules,
      );
      for (final core in VpnCore.values) {
        final profile = Profile(
          id: 'server',
          name: 'Server',
          type: ProfileType.file,
          source: '',
          detectedCore: core,
          nodes: [
            ProxyNode.fromRaw({
              'name': 'node',
              'type': 'vless',
              'server': 'example.com',
              'port': 443,
              'uuid': '11111111-1111-4111-8111-111111111111',
            }),
          ],
        );
        final android = MultiCoreConfigBuilder.build(
          settings,
          profile: profile,
        ).content;
        expect(android, isNot(contains('steam.exe')), reason: core.name);
        final windows = MultiCoreConfigBuilder.build(
          settings,
          profile: profile,
          desktopNativeTun: true,
        ).content;
        expect(
          windows,
          contains('PROCESS-NAME,steam.exe,REJECT'),
          reason: core.name,
        );
        expect(windows, isNot(contains('com.example.bank')), reason: core.name);
      }
    },
  );
  const geoIp = RoutingRule(
    id: 'geoip-ru',
    type: RoutingRuleType.geoIp,
    value: 'ru',
    action: RoutingRuleAction.direct,
  );
  const geoSite = RoutingRule(
    id: 'geosite-youtube',
    type: RoutingRuleType.geoSite,
    value: 'youtube',
    action: RoutingRuleAction.proxy,
  );

  test('routing profile config and link preserve the complete policy', () {
    const profile = RoutingProfile(
      id: 'local-id',
      name: 'Домашняя маршрутизация',
      split: SplitTunnelSettings(
        mode: SplitMode.disallowed,
        apps: {'org.telegram.messenger'},
      ),
      rules: [
        geoIp,
        geoSite,
        RoutingRule(
          id: 'steam',
          type: RoutingRuleType.processName,
          value: 'steam.exe',
          action: RoutingRuleAction.direct,
        ),
      ],
      settings: RoutingProfileSettings(
        geoUpdateIntervalHours: 72,
        lastGeoUpdateEpochSeconds: 123456789,
        actionOrder: [
          RoutingRuleAction.reject,
          RoutingRuleAction.direct,
          RoutingRuleAction.proxy,
        ],
      ),
    );

    final fromConfig = RoutingProfile.decodeConfig(
      profile.encodeConfig(),
      id: 'imported-config',
    );
    final fromLink = RoutingProfile.decodeShareLink(
      profile.encodeShareLink(),
      id: 'imported-link',
    );

    for (final imported in [fromConfig, fromLink]) {
      expect(imported.name, profile.name);
      expect(imported.split.mode, SplitMode.disallowed);
      expect(imported.split.apps, {'org.telegram.messenger'});
      expect(imported.rules.map((rule) => rule.type), [
        RoutingRuleType.geoIp,
        RoutingRuleType.geoSite,
        RoutingRuleType.processName,
      ]);
      expect(imported.settings.geoUpdateIntervalHours, 72);
      expect(imported.settings.lastGeoUpdateEpochSeconds, isNull);
      expect(imported.settings.actionOrder[1], RoutingRuleAction.direct);
    }
  });

  test('compressed share links remain compact for a substantial policy', () {
    final profile = RoutingProfile(
      id: 'large',
      name: 'Россия без рекламы и телеметрии',
      split: const SplitTunnelSettings(
        mode: SplitMode.disallowed,
        apps: {'com.example.bank', 'ru.example.market', 'org.example.player'},
      ),
      rules: [
        for (var index = 0; index < 256; index++)
          RoutingRule(
            id: 'rule-$index',
            type: RoutingRuleType.domainSuffix,
            value: 'service-$index.example.ru',
            action: index.isEven
                ? RoutingRuleAction.direct
                : RoutingRuleAction.reject,
            enabled: index % 11 != 0,
          ),
      ],
    );

    final link = profile.encodeShareLink();
    final imported = RoutingProfile.decodeShareLink(link, id: 'imported');

    expect(link, startsWith('nozelt://routing-profile/import/v2?data='));
    expect(link.length, lessThan(4096));
    expect(imported.rules, hasLength(profile.rules.length));
    expect(imported.rules[11].enabled, isFalse);
    expect(imported.rules[12].enabled, isTrue);
  });

  test('legacy uncompressed share links remain importable', () {
    const profile = RoutingProfile(
      id: 'legacy',
      name: 'Legacy',
      rules: [geoIp],
    );
    final payload = base64Url
        .encode(utf8.encode(profile.encodeConfig()))
        .replaceAll('=', '');
    final link = Uri(
      scheme: routingProfileLinkScheme,
      host: routingProfileLinkHost,
      path: '/import',
      queryParameters: {'data': payload},
    ).toString();

    final imported = RoutingProfile.decodeShareLink(link, id: 'imported');

    expect(imported.name, 'Legacy');
    expect(imported.rules.single.type, RoutingRuleType.geoIp);
  });

  test('legacy global policy migrates into one active routing profile', () {
    const tun = TunSettings(
      routingMode: RoutingMode.global,
      customRules: [geoIp],
    );
    const split = SplitTunnelSettings(
      mode: SplitMode.allowed,
      apps: {'org.example.app'},
    );

    final migrated = RoutingProfilesState.fromLegacy(tun, split);

    expect(migrated.profiles, hasLength(1));
    expect(migrated.active.routingMode, RoutingMode.global);
    expect(migrated.active.rules.single.type, RoutingRuleType.geoIp);
    expect(migrated.active.split.apps, {'org.example.app'});
    expect(RoutingProfilesState.decode(migrated.encode()).validate(), isNull);
  });

  test('encrypted state retains the local geodata refresh timestamp', () {
    const profile = RoutingProfile(
      id: 'timestamp',
      name: 'Timestamp',
      settings: RoutingProfileSettings(lastGeoUpdateEpochSeconds: 123456789),
    );
    const state = RoutingProfilesState(
      profiles: [profile],
      activeId: 'timestamp',
    );

    expect(
      RoutingProfilesState.decode(
        state.encode(),
      ).active.settings.lastGeoUpdateEpochSeconds,
      123456789,
    );
  });

  test('routing action order determines generated rule priority', () {
    const profile = RoutingProfile(
      id: 'order',
      name: 'Order',
      rules: [geoSite, geoIp],
      settings: RoutingProfileSettings(
        actionOrder: [
          RoutingRuleAction.direct,
          RoutingRuleAction.proxy,
          RoutingRuleAction.reject,
        ],
      ),
    );
    final effective = const TunSettings().copyWith(
      customRules: profile.orderedRules,
    );
    final document =
        jsonDecode(
              ConfigBuilder.buildConfig(effective, nodes: const [_mihomoNode]),
            )
            as Map<String, dynamic>;
    final rules = (document['rules'] as List).cast<String>();

    expect(rules[0], 'GEOIP,ru,DIRECT');
    expect(rules[1], 'GEOSITE,youtube,PROXY');
  });

  test('Xray and sing-box receive native geodata rules', () {
    const settings = TunSettings(customRules: [geoIp, geoSite]);
    final xray =
        jsonDecode(
              MultiCoreConfigBuilder.build(
                settings,
                profile: _nativeProfile(VpnCore.xray),
              ).content,
            )
            as Map<String, dynamic>;
    final xrayRules = ((xray['routing'] as Map)['rules'] as List)
        .whereType<Map>();
    expect(
      xrayRules.any(
        (rule) => (rule['ip'] as List?)?.contains('geoip:ru') == true,
      ),
      isTrue,
    );
    expect(
      xrayRules.any(
        (rule) =>
            (rule['domain'] as List?)?.contains('geosite:youtube') == true,
      ),
      isTrue,
    );

    final singBox =
        jsonDecode(
              MultiCoreConfigBuilder.build(
                settings,
                profile: _nativeProfile(VpnCore.singBox),
              ).content,
            )
            as Map<String, dynamic>;
    final route = singBox['route'] as Map;
    expect(
      (route['rule_set'] as List).whereType<Map>().map((value) => value['tag']),
      containsAll(['nozelt-geoip-ru', 'nozelt-geosite-youtube']),
    );
  });
}

const _mihomoNode = ProxyNode(
  name: 'Node',
  type: 'hysteria2',
  server: 'vpn.example',
  port: 443,
  raw: {
    'name': 'Node',
    'type': 'hysteria2',
    'server': 'vpn.example',
    'port': 443,
  },
);

Profile _nativeProfile(VpnCore core) => Profile(
  id: core.wireName,
  name: core.displayName,
  type: ProfileType.file,
  source: '',
  nodes: [
    ProxyNode(
      name: 'Node',
      type: 'vless',
      server: 'vpn.example',
      port: 443,
      raw: {
        'name': 'Node',
        'type': 'vless',
        'server': 'vpn.example',
        'port': 443,
        'uuid': '11111111-1111-4111-8111-111111111111',
      },
    ),
  ],
  selectedNodeName: 'Node',
  coreMode: ProfileCoreMode.manual,
  manualCore: core,
  detectedCore: core,
);
