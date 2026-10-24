import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:nozelt/src/core/config_builder.dart';
import 'package:nozelt/src/core/multi_core_config_builder.dart';
import 'package:nozelt/src/core/profile.dart';
import 'package:nozelt/src/core/proxy_node.dart';
import 'package:nozelt/src/core/routing_rule.dart';
import 'package:nozelt/src/core/tun_settings.dart';
import 'package:nozelt/src/core/vpn_core.dart';

Profile profile(VpnCore core) => Profile(
  id: 'test',
  name: 'test',
  type: ProfileType.file,
  source: '',
  detectedCore: core,
  nodes: [
    ProxyNode.fromRaw({
      'name': 'server',
      'type': 'vless',
      'server': 'vpn.example.test',
      'port': 443,
      'uuid': '11111111-1111-4111-8111-111111111111',
    }),
  ],
);

void main() {
  test('Windows rejects native source socket rules instead of misrouting', () {
    for (final core in [VpnCore.xray, VpnCore.singBox]) {
      final native = core == VpnCore.xray
          ? {
              'outbounds': [
                {
                  'tag': 'proxy',
                  'protocol': 'vless',
                  'settings': {
                    'vnext': [
                      {
                        'address': 'vpn.example.test',
                        'port': 443,
                        'users': [
                          {
                            'id': '11111111-1111-4111-8111-111111111111',
                            'encryption': 'none',
                          },
                        ],
                      },
                    ],
                  },
                },
                {'tag': 'direct', 'protocol': 'freedom'},
              ],
              'routing': {
                'rules': [
                  {
                    'type': 'field',
                    'source': ['127.0.0.0/8'],
                    'outboundTag': 'direct',
                  },
                ],
              },
            }
          : {
              'outbounds': [
                {
                  'tag': 'proxy',
                  'type': 'vless',
                  'server': 'vpn.example.test',
                  'server_port': 443,
                  'uuid': '11111111-1111-4111-8111-111111111111',
                },
                {'tag': 'direct', 'type': 'direct'},
              ],
              'route': {
                'final': 'proxy',
                'rules': [
                  {
                    'source_ip_cidr': ['127.0.0.0/8'],
                    'outbound': 'direct',
                  },
                ],
              },
            };
      final value = profile(core).copyWith(
        nodes: [
          ProxyNode.fromRaw({
            ...profile(core).nodes.single.raw,
            'nozelt-native-config': native,
            'nozelt-native-core': core.wireName,
          }),
        ],
      );
      expect(
        () => MultiCoreConfigBuilder.build(
          const TunSettings(),
          profile: value,
          desktopNativeTun: true,
        ),
        throwsStateError,
      );
      expect(
        () => MultiCoreConfigBuilder.build(
          const TunSettings(routingMode: RoutingMode.global),
          profile: value,
          desktopNativeTun: true,
        ),
        returnsNormally,
      );
    }
  });
  test(
    'Windows process policy proxies unknown owners before domain DIRECT',
    () {
      final document =
          jsonDecode(
                ConfigBuilder.buildConfig(
                  const TunSettings(
                    customRules: [
                      RoutingRule(
                        id: 'process',
                        type: RoutingRuleType.processName,
                        value: 'steam.exe',
                        action: RoutingRuleAction.proxy,
                      ),
                      RoutingRule(
                        id: 'domain',
                        type: RoutingRuleType.domain,
                        value: 'example.test',
                        action: RoutingRuleAction.direct,
                      ),
                    ],
                  ),
                  nodes: profile(VpnCore.mihomo).nodes,
                  desktopNativeTun: true,
                ),
              )
              as Map;
      expect(
        (document['rules'] as List).first,
        allOf(
          startsWith(r'AND,((PROCESS-NAME-REGEX,^$),(NOT,((OR,('),
          contains('(IP-CIDR,192.168.0.0/16,no-resolve)'),
          endsWith(',PROXY'),
        ),
      );
    },
  );
  test(
    'Windows refuses profiles that disable TLS certificate verification',
    () {
      for (final core in VpnCore.values) {
        final unsafe = profile(core).copyWith(
          nodes: [
            ProxyNode.fromRaw({
              ...profile(core).nodes.first.raw,
              'skip-cert-verify': true,
            }),
          ],
        );
        expect(
          () => MultiCoreConfigBuilder.build(
            const TunSettings(),
            profile: unsafe,
            desktopNativeTun: true,
          ),
          throwsStateError,
        );
      }
    },
  );
  test(
    'Windows global bypasses provider DIRECT routing in both native cores',
    () {
      for (final core in [VpnCore.xray, VpnCore.singBox]) {
        final native = core == VpnCore.xray
            ? <String, dynamic>{
                'outbounds': [
                  {
                    'tag': 'proxy',
                    'protocol': 'vless',
                    'settings': {
                      'vnext': [
                        {
                          'address': 'vpn.example.test',
                          'port': 443,
                          'users': [
                            {
                              'id': '11111111-1111-4111-8111-111111111111',
                              'encryption': 'none',
                            },
                          ],
                        },
                      ],
                    },
                  },
                  {'tag': 'direct', 'protocol': 'freedom'},
                ],
                'routing': {
                  'rules': [
                    {
                      'type': 'field',
                      'domain': ['full:provider.test'],
                      'outboundTag': 'direct',
                    },
                    {
                      'type': 'field',
                      'network': 'tcp,udp',
                      'outboundTag': 'proxy',
                    },
                  ],
                },
              }
            : <String, dynamic>{
                'outbounds': [
                  {
                    'type': 'vless',
                    'tag': 'proxy',
                    'server': 'vpn.example.test',
                    'server_port': 443,
                    'uuid': '11111111-1111-4111-8111-111111111111',
                  },
                  {'type': 'direct', 'tag': 'direct'},
                ],
                'route': {
                  'final': 'proxy',
                  'rules': [
                    {
                      'domain': ['provider.test'],
                      'action': 'route',
                      'outbound': 'direct',
                    },
                  ],
                },
              };
        final value = profile(core).copyWith(
          nodes: [
            ProxyNode.fromRaw({
              ...profile(core).nodes.single.raw,
              'nozelt-native-config': native,
              'nozelt-native-core': core.wireName,
            }),
          ],
        );
        for (final mode in [RoutingMode.rule, RoutingMode.global]) {
          final transport =
              (jsonDecode(
                        MultiCoreConfigBuilder.build(
                          TunSettings(routingMode: mode),
                          profile: value,
                          desktopNativeTun: true,
                        ).content,
                      )
                      as Map)['transport']
                  as Map;
          final rules =
              (transport[core == VpnCore.xray ? 'routing' : 'route']
                      as Map)['rules']
                  as List;
          final direct = rules.whereType<Map>().any(
            (rule) => (rule['outboundTag'] ?? rule['outbound']) == 'direct',
          );
          expect(direct, mode == RoutingMode.rule, reason: '$core/$mode');
        }
      }
    },
  );
  test('Xray automatic balancer cannot fail over to DIRECT', () {
    final value = profile(VpnCore.xray).copyWith(
      nodes: [
        ProxyNode.fromRaw({
          ...profile(VpnCore.xray).nodes.single.raw,
          'nozelt-native-config': {
            'outbounds': [
              {
                'tag': 'proxy-a',
                'protocol': 'vless',
                'settings': {
                  'vnext': [
                    {
                      'address': 'vpn.example.test',
                      'port': 443,
                      'users': [
                        {
                          'id': '11111111-1111-4111-8111-111111111111',
                          'encryption': 'none',
                        },
                      ],
                    },
                  ],
                },
              },
              {'tag': 'direct', 'protocol': 'freedom'},
            ],
            'routing': {
              'balancers': [
                {
                  'tag': 'auto',
                  'selector': [''],
                  'fallbackTag': 'direct',
                },
              ],
              'rules': [
                {'type': 'field', 'network': 'tcp,udp', 'balancerTag': 'auto'},
              ],
            },
          },
        }),
      ],
    );
    final transport =
        (jsonDecode(
                  MultiCoreConfigBuilder.build(
                    const TunSettings(),
                    profile: value,
                    desktopNativeTun: true,
                  ).content,
                )
                as Map)['transport']
            as Map;
    final balancer =
        (((transport['routing'] as Map)['balancers'] as List).single as Map);
    expect(balancer['selector'], ['proxy-a']);
    expect(balancer, isNot(contains('fallbackTag')));
  });
  test('Windows destination DNS stays proxied under explicit DIRECT rules', () {
    final document =
        jsonDecode(
              ConfigBuilder.buildConfig(
                const TunSettings(
                  customRules: [
                    RoutingRule(
                      id: 'direct',
                      type: RoutingRuleType.processName,
                      value: 'steam.exe',
                      action: RoutingRuleAction.direct,
                    ),
                  ],
                ),
                nodes: profile(VpnCore.mihomo).nodes,
                desktopNativeTun: true,
              ),
            )
            as Map;
    final dns = document['dns'] as Map;
    expect(dns['nameserver'], everyElement(endsWith('#PROXY')));
    expect(dns['direct-nameserver'], dns['nameserver']);
    expect(dns['proxy-server-nameserver'], const TunSettings().nameservers);
    expect((document['rules'] as List)[1], 'PROCESS-NAME,steam.exe,DIRECT');
    expect((document['tun'] as Map)['dns-hijack'], [
      'udp://any:53',
      'tcp://any:53',
    ]);
    expect(document['ipv6'], false);
  });
  test(
    'provider routing survives persistence and follows explicit user rules',
    () {
      final value = profile(VpnCore.mihomo).copyWith(
        providerRouting: {
          'node-names': ['server'],
          'proxy-groups': [
            {
              'name': 'other',
              'type': 'select',
              'proxies': ['server'],
            },
          ],
          'rules': [
            'DOMAIN,provider.test,REJECT',
            'IP-CIDR,203.0.113.0/24,other,no-resolve,src',
            'DOMAIN-REGEX,^a,b\u0024,other',
            'MATCH,PROXY',
          ],
        },
      );
      final restored = Profile.fromJson(
        jsonDecode(jsonEncode(value.toJson())) as Map<String, dynamic>,
      );
      expect(restored.providerRouting, value.providerRouting);
      final document =
          jsonDecode(
                MultiCoreConfigBuilder.build(
                  const TunSettings(
                    customRules: [
                      RoutingRule(
                        id: 'user',
                        type: RoutingRuleType.domain,
                        value: 'provider.test',
                        action: RoutingRuleAction.direct,
                      ),
                    ],
                  ),
                  profile: restored,
                  desktopNativeTun: true,
                ).content,
              )
              as Map;
      final rules = (document['rules'] as List).cast<String>();
      expect(rules.first, 'DOMAIN,provider.test,DIRECT');
      expect(rules, contains('DOMAIN,provider.test,REJECT'));
      expect(
        rules,
        contains(
          'IP-CIDR,203.0.113.0/24,__Nozelt provider group 1,no-resolve,src',
        ),
      );
      expect(
        rules,
        contains('DOMAIN-REGEX,^a,b\u0024,__Nozelt provider group 1'),
      );
      expect(rules.last, 'MATCH,PROXY');
    },
  );
  test(
    'global mode ignores provider rules without erasing stored configuration',
    () {
      final value = profile(VpnCore.mihomo).copyWith(
        providerRouting: {
          'rules': ['MATCH,DIRECT'],
        },
      );
      final document =
          jsonDecode(
                MultiCoreConfigBuilder.build(
                  const TunSettings(routingMode: RoutingMode.global),
                  profile: value,
                  desktopNativeTun: true,
                ).content,
              )
              as Map;
      final rules = (document['rules'] as List).cast<String>();
      expect(rules.last, 'MATCH,PROXY');
      expect(rules.where((rule) => !rule.startsWith('IP-CIDR,')), [
        'MATCH,PROXY',
      ]);
      expect(value.providerRouting['rules'], ['MATCH,DIRECT']);
    },
  );
  test('provider rule cache cannot write outside portable core data', () {
    final value = profile(VpnCore.mihomo).copyWith(
      providerRouting: {
        'rule-providers': {
          'geo': {
            'type': 'http',
            'behavior': 'domain',
            'url': 'https://example.test/rules',
            'path': '../../startup/evil.yaml',
          },
        },
        'rules': ['RULE-SET,geo,PROXY'],
      },
    );
    final document =
        jsonDecode(
              MultiCoreConfigBuilder.build(
                const TunSettings(),
                profile: value,
                desktopNativeTun: true,
              ).content,
            )
            as Map;
    expect(
      ((document['rule-providers'] as Map)['geo'] as Map)['path'],
      'rules/test-1.yaml',
    );
    expect(
      ((document['rule-providers'] as Map)['geo'] as Map)['proxy'],
      'PROXY',
    );
  });
  test(
    'Xray bootstrap matches internal DNS identity only, destination DNS uses proxy',
    () {
      final document =
          jsonDecode(
                MultiCoreConfigBuilder.build(
                  const TunSettings(),
                  profile: profile(VpnCore.xray),
                  desktopNativeTun: true,
                ).content,
              )
              as Map;
      final transport = document['transport'] as Map;
      final dns = transport['dns'] as Map;
      final rules = (transport['routing'] as Map)['rules'] as List;
      final bootstrap = rules[0] as Map;
      expect(bootstrap['inboundTag'], ['nozelt-endpoint-dns']);
      expect(bootstrap, isNot(contains('ip')));
      expect((rules[1] as Map)['inboundTag'], ['nozelt-internal-dns']);
      expect((rules[1] as Map)['outboundTag'], 'proxy');
      for (final server in (dns['servers'] as List).whereType<Map>()) {
        expect(server['domains'], ['full:vpn.example.test']);
        expect(server['tag'], 'nozelt-endpoint-dns');
        expect(server['skipFallback'], true);
      }
      expect(dns['disableFallbackIfMatch'], true);
    },
  );
  test('Xray never silently replaces selected DoT with arbitrary DoH', () {
    expect(
      () => MultiCoreConfigBuilder.build(
        const TunSettings(nameservers: ['tls://1.1.1.1']),
        profile: profile(VpnCore.xray),
        desktopNativeTun: true,
      ),
      throwsStateError,
    );
  });
  test('sing-box separates endpoint bootstrap from destination resolution', () {
    final transport =
        (jsonDecode(
                  MultiCoreConfigBuilder.build(
                    const TunSettings(),
                    profile: profile(VpnCore.singBox),
                    desktopNativeTun: true,
                  ).content,
                )
                as Map)['transport']
            as Map;
    final servers = ((transport['dns'] as Map)['servers'] as List).cast<Map>();
    expect(servers.first['detour'], 'proxy');
    expect(
      servers.firstWhere((s) => s['tag'] == 'bootstrap-0'),
      isNot(contains('detour')),
    );
    expect(
      ((transport['outbounds'] as List).first as Map)['domain_resolver'],
      'bootstrap-0',
    );
  });
}
