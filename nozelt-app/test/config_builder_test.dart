import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:nozelt/src/core/config_builder.dart';
import 'package:nozelt/src/core/tun_settings.dart';
import 'package:nozelt/src/core/proxy_node.dart';
import 'package:nozelt/src/core/routing_rule.dart';

const _testNode = ProxyNode(
  name: 'Helsinki',
  type: 'hysteria2',
  server: 'vpn.example',
  port: 443,
  raw: {
    'name': 'Helsinki',
    'type': 'hysteria2',
    'server': 'vpn.example',
    'port': 443,
  },
);

void main() {
  _providerRoutingTests();
  test('Android config forces privileged sing-tun routing options off', () {
    const legacySettings = TunSettings(
      autoRoute: true,
      autoDetectInterface: true,
    );

    final config =
        jsonDecode(
              ConfigBuilder.buildConfig(legacySettings, nodes: [_testNode]),
            )
            as Map<String, dynamic>;
    final tun = config['tun'] as Map<String, dynamic>;

    expect(tun['auto-route'], isFalse);
    expect(tun['auto-detect-interface'], isFalse);
  });

  test('Windows config lets mihomo own native TUN routing', () {
    final config =
        jsonDecode(
              ConfigBuilder.buildConfig(
                const TunSettings(),
                nodes: [_testNode],
                desktopNativeTun: true,
              ),
            )
            as Map<String, dynamic>;
    final tun = config['tun'] as Map<String, dynamic>;

    expect(tun['enable'], isTrue);
    expect(tun['device'], 'Nozelt');
    expect(tun['auto-route'], isTrue);
    expect(tun['auto-detect-interface'], isTrue);
    expect(tun['strict-route'], isTrue);
    expect(config['find-process-mode'], 'always');
  });

  test('TUN-only config exposes no local proxy, controller, or DNS ports', () {
    final config =
        jsonDecode(
              ConfigBuilder.buildConfig(
                const TunSettings(),
                nodes: [_testNode],
              ),
            )
            as Map<String, dynamic>;
    final dns = config['dns'] as Map<String, dynamic>;
    final sniffer = config['sniffer'] as Map<String, dynamic>;

    expect(config['port'], 0);
    expect(config['socks-port'], 0);
    expect(config['mixed-port'], 0);
    expect(config['external-controller'], isEmpty);
    expect(config['allow-lan'], isFalse);
    expect(config['bind-address'], '127.0.0.1');
    expect(config['unified-delay'], isTrue);
    expect(dns, isNot(contains('listen')));
    expect(dns['nameserver'], const [
      'https://1.1.1.1/dns-query',
      'https://8.8.8.8/dns-query',
    ]);
    expect(dns['proxy-server-nameserver'], dns['nameserver']);
    expect(dns['default-nameserver'], dns['nameserver']);
    expect(
      (dns['default-nameserver'] as List<dynamic>),
      everyElement(startsWith('https://')),
    );
    expect(dns['respect-rules'], isTrue);
    expect(sniffer, {'enable': false});
  });

  test('optional traffic sniffer extends domain rules to pure-IP apps', () {
    final config =
        jsonDecode(
              ConfigBuilder.buildConfig(
                const TunSettings(snifferEnabled: true),
                nodes: [_testNode],
              ),
            )
            as Map<String, dynamic>;
    final sniffer = config['sniffer'] as Map<String, dynamic>;
    final sniff = sniffer['sniff'] as Map<String, dynamic>;

    expect(sniffer['enable'], isTrue);
    expect(sniffer['parse-pure-ip'], isTrue);
    expect(sniffer['override-destination'], isTrue);
    expect((sniff['HTTP'] as Map)['ports'], contains('8080-8880'));
    expect((sniff['TLS'] as Map)['ports'], contains('443'));
    expect((sniff['QUIC'] as Map)['ports'], contains('443'));
  });

  test('fake DNS keeps local and reverse names off public resolvers', () {
    final config =
        jsonDecode(
              ConfigBuilder.buildConfig(
                const TunSettings(),
                nodes: [_testNode],
              ),
            )
            as Map<String, dynamic>;
    final dns = config['dns'] as Map<String, dynamic>;
    final policy = dns['nameserver-policy'] as Map<String, dynamic>;

    expect(dns['enhanced-mode'], 'fake-ip');
    expect(
      dns['fake-ip-filter'],
      containsAll(['*.lan', '*.local', 'localhost']),
    );
    expect(policy['+.local'], 'rcode://success');
    expect(policy['+.in-addr.arpa'], 'rcode://success');
    expect(policy['+.ip6.arpa'], 'rcode://success');
  });

  test('global routing is implemented through the selected PROXY group', () {
    const settings = TunSettings(routingMode: RoutingMode.global);
    final nodes = [
      ProxyNode(
        name: 'Helsinki',
        type: 'hysteria2',
        server: 'vpn.example',
        port: 443,
        raw: const {
          'name': 'Helsinki',
          'type': 'hysteria2',
          'server': 'vpn.example',
          'port': 443,
        },
      ),
      ProxyNode(
        name: 'Stockholm',
        type: 'vless',
        server: 'se.example',
        port: 443,
        raw: const {
          'name': 'Stockholm',
          'type': 'vless',
          'server': 'se.example',
          'port': 443,
        },
      ),
    ];

    final config =
        jsonDecode(
              ConfigBuilder.buildConfig(
                settings,
                nodes: nodes,
                selectedNodeName: 'Stockholm',
              ),
            )
            as Map<String, dynamic>;
    final groups = config['proxy-groups'] as List<dynamic>;
    final selector = groups.first as Map<String, dynamic>;

    // Mihomo's built-in GLOBAL selector is unrelated to Nozelt's selected
    // node. The safe implementation keeps rule mode and sends everything to
    // the PROXY group explicitly.
    expect(config['mode'], 'rule');
    expect(config['profile'], {
      'store-selected': false,
      'store-fake-ip': false,
    });
    // Everything public goes to PROXY; local ranges keep the LAN policy.
    final globalRules = (config['rules'] as List).cast<String>();
    expect(globalRules.last, 'MATCH,PROXY');
    expect(globalRules, contains('IP-CIDR,127.0.0.0/8,DIRECT,no-resolve'));
    expect(globalRules, contains('IP-CIDR,192.168.0.0/16,REJECT,no-resolve'));
    expect(globalRules.where((rule) => !rule.startsWith('IP-CIDR,')), [
      'MATCH,PROXY',
    ]);
    expect(groups, hasLength(1));
    expect((selector['proxies'] as List<dynamic>).first, 'Stockholm');
    expect(selector['proxies'] as List<dynamic>, isNot(contains('auto')));
    expect(selector['proxies'] as List<dynamic>, isNot(contains('DIRECT')));
  });

  test('rule routing blocks LAN by default before PROXY fallback', () {
    final config =
        jsonDecode(
              ConfigBuilder.buildConfig(
                const TunSettings(routingMode: RoutingMode.rule),
                nodes: [_testNode],
              ),
            )
            as Map<String, dynamic>;
    final rules = (config['rules'] as List<dynamic>).cast<String>();

    expect(config['mode'], 'rule');
    expect(rules, contains('IP-CIDR,10.0.0.0/8,REJECT,no-resolve'));
    expect(rules, contains('IP-CIDR,100.64.0.0/10,REJECT,no-resolve'));
    expect(rules, contains('IP-CIDR,224.0.0.0/4,REJECT,no-resolve'));
    expect(rules, contains('IP-CIDR,fe80::/10,REJECT,no-resolve'));
    expect(rules, contains('IP-CIDR,ff00::/8,REJECT,no-resolve'));
    expect(rules, contains('IP-CIDR,127.0.0.0/8,DIRECT,no-resolve'));
    expect(rules.last, 'MATCH,PROXY');
  });

  test('LAN access is explicit and persisted in generated rules', () {
    final config =
        jsonDecode(
              ConfigBuilder.buildConfig(
                const TunSettings(allowLan: true),
                nodes: [_testNode],
              ),
            )
            as Map<String, dynamic>;
    final rules = (config['rules'] as List<dynamic>).cast<String>();

    expect(rules, contains('IP-CIDR,10.0.0.0/8,DIRECT,no-resolve'));
    expect(rules, contains('IP-CIDR,100.64.0.0/10,DIRECT,no-resolve'));
    expect(rules, contains('IP-CIDR,fc00::/7,DIRECT,no-resolve'));
    expect(rules, contains('IP-CIDR,fe80::/10,DIRECT,no-resolve'));
  });

  test('custom domain rules are validated and emitted in order', () {
    const settings = TunSettings(
      customRules: [
        RoutingRule(
          id: 'one',
          type: RoutingRuleType.domainSuffix,
          value: '*.example.com',
          action: RoutingRuleAction.direct,
        ),
        RoutingRule(
          id: 'two',
          type: RoutingRuleType.domainKeyword,
          value: 'telemetry',
          action: RoutingRuleAction.reject,
        ),
      ],
    );
    final config =
        jsonDecode(ConfigBuilder.buildConfig(settings, nodes: [_testNode]))
            as Map<String, dynamic>;
    final rules = (config['rules'] as List<dynamic>).cast<String>();

    expect(rules[0], 'DOMAIN-SUFFIX,example.com,DIRECT');
    expect(rules[1], 'DOMAIN-KEYWORD,telemetry,REJECT');
    expect(rules.last, 'MATCH,PROXY');
  });

  test('settings validation returns localizable error keys', () {
    expect(const TunSettings(mtu: 1).validationKey(), 'invalidMtu');
    expect(
      const TunSettings(fakeIpRange: 'not-a-network/15').validationKey(),
      'invalidFakeIp',
    );
    expect(
      const TunSettings(fakeIpRange: '10.0.0.0/8').validationKey(),
      'invalidFakeIp',
    );
    expect(
      const TunSettings(fakeIpRange: '198.18.0.0/24').validationKey(),
      'invalidFakeIp',
    );
    expect(
      const TunSettings(fakeIpRange: '198.19.0.0/16').validationKey(),
      isNull,
    );
    expect(
      const TunSettings(nameservers: ['udp://1.1.1.1']).validationKey(),
      'encryptedDnsOnly',
    );
    expect(
      const TunSettings(
        nameservers: ['https://dns.example/dns-query'],
      ).validationKey(),
      'dnsIpLiteralOnly',
    );
    expect(
      TunSettings(
        nameservers: List.filled(
          TunSettings.maxNameservers + 1,
          'https://1.1.1.1/dns-query',
        ),
      ).validationKey(),
      'invalidDns',
    );
    expect(const TunSettings().validationKey(), isNull);
    expect(
      TunSettings(
        customRules: List.generate(
          TunSettings.maxCustomRules + 1,
          (index) => RoutingRule(
            id: '$index',
            type: RoutingRuleType.domain,
            value: 'host$index.example',
            action: RoutingRuleAction.proxy,
          ),
        ),
      ).validationKey(),
      'invalidRule',
    );
  });

  test('config generation fails closed without a proxy node', () {
    expect(
      () => ConfigBuilder.buildConfig(const TunSettings()),
      throwsStateError,
    );
  });

  test('config generation rejects a selectable DIRECT pseudo-node', () {
    const direct = ProxyNode(
      name: 'Bypass',
      type: 'direct',
      server: '127.0.0.1',
      port: 1,
      raw: {'name': 'Bypass', 'type': 'direct'},
    );

    expect(
      () =>
          ConfigBuilder.buildConfig(const TunSettings(), nodes: const [direct]),
      throwsStateError,
    );
  });

  test('config generation rejects a pseudo-node disguised by DTO fields', () {
    const disguised = ProxyNode(
      name: 'Bypass',
      type: 'hysteria2',
      server: 'vpn.example',
      port: 443,
      raw: {
        'name': 'Bypass',
        'type': 'direct',
        'server': 'vpn.example',
        'port': 443,
      },
    );

    expect(
      () => ConfigBuilder.buildConfig(
        const TunSettings(),
        nodes: const [disguised],
      ),
      throwsStateError,
    );
  });

  test('large configurations are encoded on a background isolate', () async {
    final nodes = List.generate(
      256,
      (index) => ProxyNode(
        name: 'Node $index',
        type: 'hysteria2',
        server: '192.0.2.${index % 250 + 1}',
        port: 443,
        raw: {
          'name': 'Node $index',
          'type': 'hysteria2',
          'server': '192.0.2.${index % 250 + 1}',
          'port': 443,
          'password': 'test-$index',
        },
      ),
    );

    final encoded = await ConfigBuilder.buildConfigAsync(
      const TunSettings(),
      nodes: nodes,
      selectedNodeName: 'Node 200',
    );
    final config = jsonDecode(encoded) as Map<String, dynamic>;
    final selector = (config['proxy-groups'] as List).first as Map;

    expect(config['proxies'], hasLength(256));
    expect((selector['proxies'] as List).first, 'Node 200');
  });

  test('expands a Happ automatic node into a mihomo url-test group', () {
    const automatic = ProxyNode(
      name: 'Auto | Europe | WIFI',
      type: 'url-test',
      server: 'one.example',
      port: 443,
      raw: {
        'name': 'Auto | Europe | WIFI',
        'type': 'url-test',
        'server': 'one.example',
        'port': 443,
        'nozelt-auto-url': 'http://cp.cloudflare.com/generate_204',
        'nozelt-auto-interval': 20,
        'nozelt-auto-members': [
          {
            'name': 'member one',
            'type': 'vless',
            'server': 'one.example',
            'port': 443,
            'uuid': '11111111-1111-4111-8111-111111111111',
          },
          {
            'name': 'member two',
            'type': 'vless',
            'server': 'two.example',
            'port': 7443,
            'uuid': '22222222-2222-4222-8222-222222222222',
          },
        ],
      },
    );

    final config =
        jsonDecode(
              ConfigBuilder.buildConfig(
                const TunSettings(),
                nodes: const [automatic],
              ),
            )
            as Map<String, dynamic>;
    final proxies = config['proxies'] as List;
    final groups = config['proxy-groups'] as List;
    final automaticGroup = groups.first as Map;
    final selector = groups.last as Map;

    expect(proxies, hasLength(2));
    expect(automaticGroup['name'], automatic.name);
    expect(automaticGroup['type'], 'url-test');
    expect(automaticGroup['proxies'], hasLength(2));
    expect(automaticGroup['url'], 'http://cp.cloudflare.com/generate_204');
    expect(selector['proxies'], [automatic.name]);

    final probePlan = ConfigBuilder.buildDelayProbePlan(
      const [_testNode, automatic],
      targetNodeNames: [automatic.name],
    );
    final memberNames = (automaticGroup['proxies'] as List).cast<String>();
    expect(probePlan.nativeNames, memberNames);
    expect(probePlan.testUrlsByNativeName, {
      for (final name in memberNames)
        name: 'http://cp.cloudflare.com/generate_204',
    });
    expect(
      probePlan.aggregate({memberNames.first: 146, memberNames.last: 82}),
      {automatic.name: 82},
    );
  });

  test('uses embedded Xray observatory URL for an existing ordinary node', () {
    const node = ProxyNode(
      name: 'Whitelist node',
      type: 'vless',
      server: 'node.example',
      port: 443,
      raw: {
        'name': 'Whitelist node',
        'type': 'vless',
        'server': 'node.example',
        'port': 443,
        'uuid': '11111111-1111-4111-8111-111111111111',
        'nozelt-native-config': {
          'burstObservatory': {
            'pingConfig': {
              'destination': 'http://www.gstatic.com/generate_204',
            },
          },
        },
      },
    );

    final plan = ConfigBuilder.buildDelayProbePlan(
      const [node],
      targetNodeNames: const ['Whitelist node'],
    );

    expect(plan.testUrlsByNativeName, {
      'Whitelist node': 'http://www.gstatic.com/generate_204',
    });
    expect(ConfigBuilder.defaultDelayTestUrl, startsWith('http://'));
  });

  test('partial automatic delays appear after the first successful member', () {
    const automatic = ProxyNode(
      name: 'Automatic',
      type: 'url-test',
      server: 'one.example',
      port: 443,
      raw: {
        'name': 'Automatic',
        'type': 'url-test',
        'server': 'one.example',
        'port': 443,
        'nozelt-auto-members': [
          {
            'name': 'member one',
            'type': 'vless',
            'server': 'one.example',
            'port': 443,
            'uuid': '11111111-1111-4111-8111-111111111111',
          },
          {
            'name': 'member two',
            'type': 'vless',
            'server': 'two.example',
            'port': 443,
            'uuid': '22222222-2222-4222-8222-222222222222',
          },
        ],
      },
    );
    final plan = ConfigBuilder.buildDelayProbePlan(
      const [automatic],
      targetNodeNames: const ['Automatic'],
    );

    expect(plan.aggregateCompleted({plan.nativeNames.first: null}), isEmpty);
    expect(plan.aggregateCompleted({plan.nativeNames.first: 91}), {
      'Automatic': 91,
    });
    expect(
      plan.aggregateCompleted({
        for (final name in plan.nativeNames) name: null,
      }),
      {'Automatic': null},
    );
  });
}

void _providerRoutingTests() {
  group('provider routing', () {
    const userRule = RoutingRule(
      id: 'user',
      type: RoutingRuleType.domainSuffix,
      value: 'example.com',
      action: RoutingRuleAction.proxy,
    );
    const routing = {
      'node-names': ['Helsinki'],
      'proxy-groups': [
        {
          'name': 'Russia',
          'type': 'select',
          'proxies': ['DIRECT', 'Helsinki', 'gone-server'],
        },
        {
          'name': 'Fed',
          'type': 'select',
          'use': ['missing-provider'],
        },
      ],
      'rules': [
        'DOMAIN-SUFFIX,example.com,DIRECT',
        'GEOIP,ru,Russia',
        'DOMAIN,fed.test,Fed',
        'DOMAIN,global.test,GLOBAL',
        'RULE-SET,missing,DIRECT',
        'MATCH,PROXY',
      ],
    };

    List<String> render({required bool desktop}) {
      final config =
          jsonDecode(
                ConfigBuilder.buildConfig(
                  const TunSettings(customRules: [userRule]),
                  nodes: const [_testNode],
                  desktopNativeTun: desktop,
                  providerRouting: routing,
                ),
              )
              as Map<String, dynamic>;
      final groups = (config['proxy-groups'] as List).cast<Map>();
      final russia = groups.firstWhere(
        (group) => group['name'] == '__Nozelt provider group 1',
      );
      expect(russia['proxies'], ['DIRECT', 'Helsinki']);
      final fed = groups.firstWhere(
        (group) => group['name'] == '__Nozelt provider group 2',
      );
      expect(fed.containsKey('use'), isFalse);
      expect(fed['proxies'], ['PROXY']);
      return (config['rules'] as List).cast<String>();
    }

    for (final desktop in [false, true]) {
      test(
        'applies on ${desktop ? 'Windows' : 'Android'} after user rules',
        () {
          final rules = render(desktop: desktop);
          final user = rules.indexOf('DOMAIN-SUFFIX,example.com,PROXY');
          final provider = rules.indexOf('DOMAIN-SUFFIX,example.com,DIRECT');
          expect(user, greaterThanOrEqualTo(0));
          expect(provider, greaterThan(user));
          expect(
            rules.indexOf('IP-CIDR,192.168.0.0/16,REJECT,no-resolve'),
            lessThan(provider),
          );
          expect(rules, contains('GEOIP,ru,__Nozelt provider group 1'));
          expect(rules, contains('DOMAIN,global.test,PROXY'));
          expect(rules.any((rule) => rule.startsWith('RULE-SET')), isFalse);
          expect(rules.last, 'MATCH,PROXY');
        },
      );
    }
  });
}
