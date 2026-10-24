import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:nozelt/src/core/multi_core_config_builder.dart';
import 'package:nozelt/src/core/profile.dart';
import 'package:nozelt/src/core/proxy_node.dart';
import 'package:nozelt/src/core/routing_rule.dart';
import 'package:nozelt/src/core/tun_settings.dart';
import 'package:nozelt/src/core/vpn_core.dart';

void main() {
  test(
    'Windows native delay targets retain encrypted transport bootstrap',
    () async {
      final profile = _profile(
        detectedCore: VpnCore.xray,
        raw: {
          'name': 'Server',
          'type': 'vless',
          'server': 'vpn.example.test',
          'port': 443,
          'uuid': '11111111-1111-4111-8111-111111111111',
        },
      );
      final targets = await MultiCoreConfigBuilder.buildNativeProbeTargetsAsync(
        const TunSettings(),
        profile: profile,
        targetNodeNames: ['Server'],
        desktopNativeTun: true,
      );
      final document = jsonDecode(targets.single.config) as Map;
      expect(
        ((document['dns'] as Map)['servers'] as List)
            .whereType<String>()
            .toList(),
        const TunSettings().nameservers,
      );
      expect(
        (((document['routing'] as Map)['rules'] as List).first
            as Map)['outboundTag'],
        'nozelt-bootstrap',
      );
    },
  );
  test('Windows replaces provider plaintext bootstrap DNS only on desktop', () {
    final profile = _profile(
      detectedCore: VpnCore.xray,
      raw: {
        'name': 'Native DNS regression',
        'type': 'vless',
        'server': 'vpn.example.test',
        'port': 443,
        'uuid': '11111111-1111-4111-8111-111111111111',
        'nozelt-native-config': {
          'dns': {
            'servers': ['8.8.8.8'],
            'queryStrategy': 'UseIP',
          },
          'outbounds': [
            {
              'tag': 'proxy',
              'protocol': 'vless',
              'settings': {
                'vnext': [
                  {'address': 'vpn.example.test', 'port': 443},
                ],
              },
            },
          ],
          'routing': {
            'balancers': [
              {
                'tag': 'AUTO',
                'selector': ['proxy'],
              },
            ],
            'rules': [
              {'type': 'field', 'balancerTag': 'AUTO'},
            ],
          },
        },
      },
    );
    final desktop =
        jsonDecode(
              MultiCoreConfigBuilder.build(
                const TunSettings(),
                profile: profile,
                desktopNativeTun: true,
              ).content,
            )
            as Map;
    final transport = desktop['transport'] as Map;
    expect(
      ((transport['dns'] as Map)['servers'] as List)
          .whereType<String>()
          .toList(),
      const TunSettings().nameservers,
    );
    expect((transport['routing'] as Map)['balancers'], isNotEmpty);
    final rules = (transport['routing'] as Map)['rules'] as List;
    expect((rules.first as Map)['outboundTag'], 'nozelt-bootstrap');
    final android =
        jsonDecode(
              MultiCoreConfigBuilder.build(
                const TunSettings(),
                profile: profile,
              ).content,
            )
            as Map;
    expect((android['dns'] as Map)['servers'], ['8.8.8.8']);
  });
  test('legacy profiles detect a preserved Xray document during migration', () {
    final profile = Profile.fromJson({
      'id': 'xray',
      'name': 'examplevpn',
      'type': 'file',
      'source': '',
      'nodes': [
        {
          'name': 'Auto',
          'type': 'vless',
          'server': 'one.example',
          'port': 443,
          'raw': {
            'name': 'Auto',
            'type': 'vless',
            'server': 'one.example',
            'port': 443,
            'uuid': '11111111-1111-4111-8111-111111111111',
            'nozelt-native-core': 'xray',
            'nozelt-native-config': {
              'outbounds': [
                {'protocol': 'freedom', 'tag': 'direct'},
              ],
            },
          },
        },
      ],
    });

    expect(profile.coreMode, ProfileCoreMode.automatic);
    expect(profile.effectiveCore, VpnCore.xray);
  });

  test('manual core selection overrides the detected core', () {
    final profile = _profile(
      coreMode: ProfileCoreMode.manual,
      manualCore: VpnCore.singBox,
      detectedCore: VpnCore.xray,
      raw: {
        'name': 'node',
        'type': 'vless',
        'server': 'one.example',
        'port': 443,
        'uuid': '11111111-1111-4111-8111-111111111111',
      },
    );

    expect(profile.effectiveCore, VpnCore.singBox);
  });

  test('Xray rendering preserves provider balancers and replaces inbounds', () {
    final nativeDocument = {
      'inbounds': [
        {'protocol': 'socks', 'port': 1080},
      ],
      'dns': {
        'queryStrategy': 'UseIP',
        'servers': ['77.88.8.8'],
      },
      'outbounds': [
        {'protocol': 'freedom', 'tag': 'direct'},
      ],
      'routing': {
        'balancers': [
          {
            'tag': 'auto',
            'selector': ['proxy'],
          },
        ],
      },
    };
    final profile = _profile(
      detectedCore: VpnCore.xray,
      raw: {
        'name': 'Auto',
        'type': 'vless',
        'server': 'one.example',
        'port': 443,
        'uuid': '11111111-1111-4111-8111-111111111111',
        'nozelt-native-core': 'xray',
        'nozelt-native-config': nativeDocument,
      },
    );

    final rendered = MultiCoreConfigBuilder.build(
      const TunSettings(),
      profile: profile,
    );
    final document = jsonDecode(rendered.content) as Map<String, dynamic>;
    final inbound = (document['inbounds'] as List).single as Map;

    expect(rendered.core, VpnCore.xray);
    expect(inbound['protocol'], 'tun');
    expect((document['routing'] as Map)['balancers'], isNotEmpty);
    expect((document['dns'] as Map)['servers'], ['77.88.8.8']);
    final dnsOutbound = (document['outbounds'] as List)
        .whereType<Map>()
        .singleWhere((outbound) => outbound['protocol'] == 'dns');
    final rules = (document['routing'] as Map)['rules'] as List;
    expect(rules.first, {
      'type': 'field',
      'network': 'tcp,udp',
      'port': '53',
      'outboundTag': dnsOutbound['tag'],
    });
    expect(
      (((nativeDocument['inbounds'] as List).single) as Map)['protocol'],
      'socks',
    );
    expect(
      (nativeDocument['outbounds'] as List).whereType<Map>().where(
        (outbound) => outbound['protocol'] == 'dns',
      ),
      isEmpty,
    );
  });

  test('Xray rendering reuses an existing DNS outbound and rule', () {
    final profile = _profile(
      detectedCore: VpnCore.xray,
      raw: {
        'name': 'Auto',
        'type': 'vless',
        'server': 'one.example',
        'port': 443,
        'uuid': '11111111-1111-4111-8111-111111111111',
        'nozelt-native-core': 'xray',
        'nozelt-native-config': {
          'outbounds': [
            {'protocol': 'vless', 'tag': 'proxy'},
            {'protocol': 'dns', 'tag': 'provider-dns'},
          ],
          'routing': {
            'rules': [
              {
                'type': 'field',
                'network': 'tcp,udp',
                'port': '53',
                'outboundTag': 'provider-dns',
              },
              {'type': 'field', 'network': 'tcp,udp', 'outboundTag': 'proxy'},
            ],
          },
        },
      },
    );

    final rendered = MultiCoreConfigBuilder.build(
      const TunSettings(),
      profile: profile,
    );
    final document = jsonDecode(rendered.content) as Map<String, dynamic>;
    final dnsOutbounds = (document['outbounds'] as List).whereType<Map>().where(
      (outbound) => outbound['protocol'] == 'dns',
    );
    final dnsRules = ((document['routing'] as Map)['rules'] as List)
        .whereType<Map>()
        .where((rule) => rule['port'] == '53');

    expect(dnsOutbounds, hasLength(1));
    expect(dnsRules, hasLength(1));
    expect(dnsRules.single['outboundTag'], 'provider-dns');
  });

  test('native Xray applies user direct rules before provider routing', () {
    final profile = _profile(
      detectedCore: VpnCore.xray,
      raw: {
        'name': 'Xray node',
        'type': 'vless',
        'server': 'one.example',
        'port': 443,
        'nozelt-native-core': 'xray',
        'nozelt-native-config': {
          'outbounds': [
            {'protocol': 'vless', 'tag': 'provider-proxy'},
          ],
          'routing': {
            'rules': [
              {
                'type': 'field',
                'network': 'tcp,udp',
                'outboundTag': 'provider-proxy',
              },
            ],
          },
        },
      },
    );
    final rendered = MultiCoreConfigBuilder.build(
      const TunSettings(
        customRules: [
          RoutingRule(
            id: 'playerok',
            type: RoutingRuleType.domainKeyword,
            value: 'playerok',
            action: RoutingRuleAction.direct,
          ),
        ],
      ),
      profile: profile,
    );
    final document = jsonDecode(rendered.content) as Map<String, dynamic>;
    final rules = ((document['routing'] as Map)['rules'] as List)
        .whereType<Map>()
        .toList();
    final playerok = rules.singleWhere(
      (rule) => (rule['domain'] as List?)?.contains('keyword:playerok') == true,
    );
    final providerIndex = rules.indexWhere(
      (rule) => rule['outboundTag'] == 'provider-proxy',
    );

    expect(playerok['outboundTag'], isNot('provider-proxy'));
    expect(rules.indexOf(playerok), lessThan(providerIndex));
    expect(
      (document['outbounds'] as List).whereType<Map>().any(
        (outbound) =>
            outbound['tag'] == playerok['outboundTag'] &&
            outbound['protocol'] == 'freedom',
      ),
      isTrue,
    );
  });

  test('native sing-box applies user direct rules before provider routing', () {
    final profile = _profile(
      detectedCore: VpnCore.singBox,
      raw: {
        'name': 'Sing node',
        'type': 'vless',
        'server': 'one.example',
        'port': 443,
        'nozelt-native-core': 'sing-box',
        'nozelt-native-config': {
          'outbounds': [
            {'type': 'vless', 'tag': 'provider-proxy'},
          ],
          'route': {
            'final': 'provider-proxy',
            'rules': [
              {'protocol': 'dns', 'action': 'hijack-dns'},
            ],
          },
        },
      },
    );
    final rendered = MultiCoreConfigBuilder.build(
      const TunSettings(
        customRules: [
          RoutingRule(
            id: 'playerok',
            type: RoutingRuleType.domainSuffix,
            value: 'playerok.com',
            action: RoutingRuleAction.direct,
          ),
        ],
      ),
      profile: profile,
    );
    final document = jsonDecode(rendered.content) as Map<String, dynamic>;
    final rules = ((document['route'] as Map)['rules'] as List)
        .whereType<Map>()
        .toList();
    final playerok = rules.singleWhere(
      (rule) =>
          (rule['domain_suffix'] as List?)?.contains('playerok.com') == true,
    );

    expect(playerok['action'], 'route');
    expect(playerok['outbound'], isNot('provider-proxy'));
    // sniff (added, the provider had none) and hijack-dns run first so the
    // name is known when the user rule is matched.
    expect(rules.first, {'action': 'sniff'});
    expect(rules.indexOf(playerok), 2);
    expect(
      (document['outbounds'] as List).whereType<Map>().any(
        (outbound) =>
            outbound['tag'] == playerok['outbound'] &&
            outbound['type'] == 'direct',
      ),
      isTrue,
    );
  });

  test('sing-box renders an Android descriptor-backed TUN config', () {
    final profile = _profile(
      detectedCore: VpnCore.singBox,
      raw: {
        'name': 'node',
        'type': 'hysteria2',
        'server': 'hy.example',
        'port': 443,
        'password': 'secret',
        'sni': 'hy.example',
      },
    );

    final rendered = MultiCoreConfigBuilder.build(
      const TunSettings(),
      profile: profile,
    );
    final document = jsonDecode(rendered.content) as Map<String, dynamic>;
    final inbound = (document['inbounds'] as List).single as Map;
    final outbound = (document['outbounds'] as List).first as Map;

    expect(rendered.core, VpnCore.singBox);
    expect(inbound['type'], 'tun');
    expect(inbound['auto_route'], false);
    expect(outbound['type'], 'hysteria2');
    expect((document['route'] as Map)['final'], 'proxy');
  });

  test('Xray renders an automatic Windows TUN configuration', () {
    final profile = _profile(
      detectedCore: VpnCore.xray,
      raw: {
        'name': 'Xray node',
        'type': 'vless',
        'server': 'xray.example',
        'port': 443,
        'uuid': '11111111-1111-4111-8111-111111111111',
        'tls': true,
        'servername': 'xray.example',
      },
    );

    final rendered = MultiCoreConfigBuilder.build(
      const TunSettings(),
      profile: profile,
      desktopNativeTun: true,
    );
    final document = jsonDecode(rendered.content) as Map<String, dynamic>;
    final frontend = document['frontend'] as Map;
    final tun = frontend['tun'] as Map;
    expect(rendered.core, VpnCore.xray);
    expect(document['nozeltWindowsRelay'], 1);
    expect(tun['auto-route'], true);
    expect(tun['auto-detect-interface'], true);
    expect(frontend['find-process-mode'], 'always');
    expect((document['transport'] as Map)['outbounds'], isNotEmpty);
    expect(tun['inet6-address'], isEmpty);
    final transport = document['transport'] as Map;
    expect(
      ((transport['dns'] as Map)['servers'] as List)
          .whereType<String>()
          .toList(),
      const TunSettings().nameservers,
    );
    final bootstrap =
        ((transport['routing'] as Map)['rules'] as List).first as Map;
    expect(bootstrap, isNot(contains('ip')));
    expect(bootstrap['inboundTag'], ['nozelt-endpoint-dns']);
    expect(bootstrap['outboundTag'], 'nozelt-bootstrap');
  });

  test('sing-box renders an automatic strict Windows TUN configuration', () {
    final profile = _profile(
      detectedCore: VpnCore.singBox,
      raw: {
        'name': 'Sing node',
        'type': 'hysteria2',
        'server': 'hy.example',
        'port': 443,
        'password': 'secret',
        'sni': 'hy.example',
      },
    );

    final rendered = MultiCoreConfigBuilder.build(
      const TunSettings(),
      profile: profile,
      desktopNativeTun: true,
    );
    final document = jsonDecode(rendered.content) as Map<String, dynamic>;
    final frontend = document['frontend'] as Map;
    final inbound = frontend['tun'] as Map;

    expect(rendered.core, VpnCore.singBox);
    expect(document['nozeltWindowsRelay'], 1);
    expect(inbound['auto-route'], true);
    expect(inbound['auto-detect-interface'], true);
    expect(frontend['find-process-mode'], 'always');
    final transport = document['transport'] as Map;
    expect((transport['route'] as Map)['default_domain_resolver'], 'dns-0');
  });

  test(
    'native Xray probes retain the provider balancer and test URL',
    () async {
      final profile = _profile(
        detectedCore: VpnCore.xray,
        raw: {
          'name': 'Auto bypass',
          'type': 'url-test',
          'server': 'one.example',
          'port': 443,
          'nozelt-auto-members': [
            {
              'name': 'member-1',
              'type': 'vless',
              'server': 'one.example',
              'port': 443,
              'uuid': '11111111-1111-4111-8111-111111111111',
            },
            {
              'name': 'member-2',
              'type': 'vless',
              'server': 'two.example',
              'port': 443,
              'uuid': '22222222-2222-4222-8222-222222222222',
            },
          ],
          'nozelt-native-core': 'xray',
          'nozelt-native-config': {
            'burstObservatory': {
              'pingConfig': {
                'destination': 'http://cp.cloudflare.com/generate_204',
              },
            },
            'outbounds': [
              {'tag': 'proxy', 'protocol': 'vless'},
              {'tag': 'proxy-2', 'protocol': 'vless'},
            ],
            'routing': {
              'balancers': [
                {
                  'tag': 'AUTO',
                  'selector': ['proxy'],
                },
              ],
            },
          },
        },
      );

      final targets = await MultiCoreConfigBuilder.buildNativeProbeTargetsAsync(
        const TunSettings(),
        profile: profile,
        targetNodeNames: ['Auto bypass'],
      );
      final document =
          jsonDecode(targets.single.config) as Map<String, dynamic>;

      expect(targets.single.name, 'Auto bypass');
      expect(targets.single.url, 'http://cp.cloudflare.com/generate_204');
      expect((document['routing'] as Map)['balancers'], isNotEmpty);
      expect(document['burstObservatory'], isNotNull);
    },
  );

  test(
    'standalone native Xray probes disable unused provider observers',
    () async {
      final profile = _profile(
        detectedCore: VpnCore.xray,
        raw: {
          'name': 'Mobile bypass',
          'type': 'hysteria2',
          'server': 'mobile.example',
          'port': 443,
          'nozelt-native-core': 'xray',
          'nozelt-native-config': {
            'observatory': {
              'subjectSelector': ['proxy'],
            },
            'burstObservatory': {
              'pingConfig': {
                'destination': 'http://cp.cloudflare.com/generate_204',
              },
              'subjectSelector': ['proxy'],
            },
            'outbounds': [
              {'tag': 'proxy', 'protocol': 'hysteria'},
            ],
            'routing': {
              'rules': [
                {'type': 'field', 'outboundTag': 'proxy'},
              ],
            },
          },
        },
      );

      final targets = await MultiCoreConfigBuilder.buildNativeProbeTargetsAsync(
        const TunSettings(),
        profile: profile,
        targetNodeNames: ['Mobile bypass'],
      );
      final document =
          jsonDecode(targets.single.config) as Map<String, dynamic>;

      expect(targets.single.url, 'http://cp.cloudflare.com/generate_204');
      expect(document, isNot(contains('observatory')));
      expect(document, isNot(contains('burstObservatory')));
    },
  );

  test('native sing-box probes are rendered by sing-box', () async {
    final profile = _profile(
      detectedCore: VpnCore.singBox,
      raw: {
        'name': 'Sing node',
        'type': 'hysteria2',
        'server': 'hy.example',
        'port': 443,
        'password': 'secret',
        'sni': 'hy.example',
      },
    );

    final targets = await MultiCoreConfigBuilder.buildNativeProbeTargetsAsync(
      const TunSettings(),
      profile: profile,
      targetNodeNames: ['Sing node'],
    );
    final document = jsonDecode(targets.single.config) as Map<String, dynamic>;
    final outbound = (document['outbounds'] as List).first as Map;

    expect(targets.single.name, 'Sing node');
    expect(outbound['type'], 'hysteria2');
    expect((document['route'] as Map)['final'], 'proxy');
  });

  test('Windows Xray bootstraps every server name, including flat ones', () {
    final profile = _profile(
      detectedCore: VpnCore.xray,
      raw: {
        'name': 'Auto',
        'type': 'vless',
        'server': 'one.example',
        'port': 443,
        'uuid': '11111111-1111-4111-8111-111111111111',
        'nozelt-native-config': {
          'outbounds': [
            {
              'tag': 'hy',
              'protocol': 'hysteria',
              'settings': {'version': 2, 'address': 'hy.example', 'port': 443},
            },
            {
              'tag': 'flat',
              'protocol': 'vless',
              'settings': {'address': 'flat.example', 'port': 443},
              'streamSettings': {
                'xhttpSettings': {
                  'extra': {
                    'downloadSettings': {'address': 'down.example'},
                  },
                },
              },
            },
            {
              'tag': 'classic',
              'protocol': 'vless',
              'settings': {
                'vnext': [
                  {'address': 'classic.example', 'port': 443},
                ],
              },
            },
          ],
          'routing': {
            'balancers': [
              {
                'tag': 'AUTO',
                'selector': ['hy', 'flat', 'classic'],
              },
            ],
            'rules': [
              {'type': 'field', 'balancerTag': 'AUTO'},
            ],
          },
        },
      },
    );
    final desktop =
        jsonDecode(
              MultiCoreConfigBuilder.build(
                const TunSettings(),
                profile: profile,
                desktopNativeTun: true,
              ).content,
            )
            as Map;
    final servers =
        ((desktop['transport'] as Map)['dns'] as Map)['servers'] as List;
    final bootstrap = servers.whereType<Map>().firstWhere(
      (server) => server['tag'] == 'nozelt-endpoint-dns',
    );
    expect(
      (bootstrap['domains'] as List).toSet(),
      containsAll({
        'full:hy.example',
        'full:flat.example',
        'full:down.example',
        'full:classic.example',
      }),
    );
  });

  group('routing parity across cores', () {
    const node = {
      'name': 'Node',
      'type': 'vless',
      'server': 'vpn.example.test',
      'port': 443,
      'uuid': '11111111-1111-4111-8111-111111111111',
      'tls': true,
    };
    const geoRule = RoutingRule(
      id: 'geo',
      type: RoutingRuleType.geoIp,
      value: 'ru',
      action: RoutingRuleAction.direct,
    );

    Map<String, dynamic> render(VpnCore core, TunSettings settings) =>
        jsonDecode(
              MultiCoreConfigBuilder.build(
                settings,
                profile: _profile(detectedCore: core, raw: node),
              ).content,
            )
            as Map<String, dynamic>;

    test('Xray always sniffs for routing and keeps LAN policy', () {
      final document = render(
        VpnCore.xray,
        const TunSettings(customRules: [geoRule]),
      );
      final sniffing =
          ((document['inbounds'] as List).single as Map)['sniffing'] as Map;
      expect(sniffing['enabled'], isTrue);
      expect(sniffing['routeOnly'], isTrue);
      final rules = ((document['routing'] as Map)['rules'] as List).cast<Map>();
      // No catch-all in rule mode: it would stop IPIfNonMatch resolution.
      expect(
        rules.where(
          (rule) =>
              rule.keys.toSet().containsAll({'network', 'outboundTag'}) &&
              rule.keys.length == 3,
        ),
        isEmpty,
      );
      expect(
        rules.any(
          (rule) =>
              (rule['ip'] as List?)?.contains('192.168.0.0/16') == true &&
              rule['outboundTag'] == 'block',
        ),
        isTrue,
      );
      final global = render(
        VpnCore.xray,
        const TunSettings(routingMode: RoutingMode.global, allowLan: true),
      );
      final globalRules = ((global['routing'] as Map)['rules'] as List)
          .cast<Map>();
      expect(
        globalRules.any(
          (rule) =>
              (rule['ip'] as List?)?.contains('192.168.0.0/16') == true &&
              rule['outboundTag'] == 'direct',
        ),
        isTrue,
      );
      expect(globalRules.last['outboundTag'], 'proxy');
    });

    test('sing-box uses sniff actions and resolves through the proxy', () {
      final document = render(
        VpnCore.singBox,
        const TunSettings(customRules: [geoRule], snifferEnabled: true),
      );
      final tun = (document['inbounds'] as List).single as Map;
      expect(tun.containsKey('sniff'), isFalse);
      final route = document['route'] as Map;
      final rules = (route['rules'] as List).cast<Map>();
      expect(rules[0], {'action': 'sniff'});
      expect(rules[1], {'protocol': 'dns', 'action': 'hijack-dns'});
      expect(rules.last['action'], 'reject');
      expect(route['default_domain_resolver'], 'dns-0');
      final servers = ((document['dns'] as Map)['servers'] as List).cast<Map>();
      expect(
        servers.where((server) => server['tag'].toString().startsWith('dns-')),
        everyElement(containsPair('detour', 'proxy')),
      );
      expect(
        servers.where(
          (server) => server['tag'].toString().startsWith('bootstrap-'),
        ),
        everyElement(isNot(contains('detour'))),
      );
      final proxy = (document['outbounds'] as List).cast<Map>().first;
      expect(proxy['domain_resolver'], 'bootstrap-0');
    });
  });
}

Profile _profile({
  ProfileCoreMode coreMode = ProfileCoreMode.automatic,
  VpnCore manualCore = VpnCore.mihomo,
  VpnCore detectedCore = VpnCore.mihomo,
  required Map<String, dynamic> raw,
}) {
  return Profile(
    id: 'profile',
    name: 'Profile',
    type: ProfileType.file,
    source: '',
    nodes: [ProxyNode.fromRaw(raw)],
    coreMode: coreMode,
    manualCore: manualCore,
    detectedCore: detectedCore,
  );
}
