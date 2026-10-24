import 'dart:convert';
import 'dart:io';

import 'package:nozelt/src/core/multi_core_config_builder.dart';
import 'package:nozelt/src/core/profile.dart';
import 'package:nozelt/src/core/proxy_node.dart';
import 'package:nozelt/src/core/routing_rule.dart';
import 'package:nozelt/src/core/tun_settings.dart';
import 'package:nozelt/src/core/vpn_core.dart';
import 'package:nozelt/src/core/windows_native_bridge.dart';

Future<void> main() async {
  if (!Platform.isWindows) {
    stderr.writeln('Windows core validation must run on Windows.');
    exitCode = 2;
    return;
  }
  final root = Directory.current;
  final coreDirectory = Directory(
    '${root.parent.path}${Platform.pathSeparator}native-cores'
    '${Platform.pathSeparator}build${Platform.pathSeparator}windows',
  );
  final cases = [
    (
      core: VpnCore.xray,
      executable: File('${coreDirectory.path}\\xray.exe'),
      arguments: const ['run', '-test', '-c', 'stdin:'],
      raw: <String, dynamic>{
        'name': 'Validation Xray',
        'type': 'vless',
        'server': '127.0.0.1',
        'port': 443,
        'uuid': '11111111-1111-4111-8111-111111111111',
        'tls': true,
        'servername': 'example.com',
      },
    ),
    (
      core: VpnCore.singBox,
      executable: File('${coreDirectory.path}\\singbox-runner.exe'),
      arguments: const ['--check', '-'],
      raw: <String, dynamic>{
        'name': 'Validation sing-box',
        'type': 'hysteria2',
        'server': '127.0.0.1',
        'port': 443,
        'password': 'validation-only',
        'sni': 'example.com',
      },
    ),
  ];
  final bridge = WindowsNativeBridge.open();

  for (final testCase in cases) {
    if (!testCase.executable.existsSync()) {
      throw StateError('Missing ${testCase.executable.path}');
    }
    final profile = Profile(
      id: 'validation',
      name: 'Validation',
      type: ProfileType.file,
      source: '',
      nodes: [ProxyNode.fromRaw(testCase.raw)],
      detectedCore: testCase.core,
    );
    final rendered = MultiCoreConfigBuilder.build(
      const TunSettings(),
      profile: profile,
      desktopNativeTun: true,
    );
    final validation =
        jsonDecode(
              bridge.validateCoreConfig(
                testCase.core.wireName,
                rendered.content,
              ),
            )
            as Map<String, dynamic>;
    if (validation['ok'] != true) {
      throw StateError(
        '${testCase.core.displayName} rejected the generated Windows config '
        ': $validation',
      );
    }
    final targets = await MultiCoreConfigBuilder.buildNativeProbeTargetsAsync(
      const TunSettings(),
      profile: profile,
      targetNodeNames: [profile.selectedNode!.name],
    );
    final begin =
        jsonDecode(
              bridge.beginProxyDelays(
                core: testCase.core.wireName,
                config: '',
                namesJson: '[]',
                targetsJson: jsonEncode([
                  {
                    'name': 'validation',
                    'config': targets.single.config,
                    'url': 'http://127.0.0.1/generate_204',
                  },
                ]),
                testUrl: '',
                timeoutMs: 500,
                offline: true,
              ),
            )
            as Map<String, dynamic>;
    if (begin['ok'] != true || begin['jobId'] is! String) {
      throw StateError(
        '${testCase.core.displayName} native probe did not start.',
      );
    }
    Map<String, dynamic>? probe;
    final deadline = DateTime.now().add(const Duration(seconds: 8));
    while (DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 30));
      final poll =
          jsonDecode(bridge.pollProxyDelays(begin['jobId'] as String))
              as Map<String, dynamic>;
      if (poll['done'] == true && poll['response'] is String) {
        probe = jsonDecode(poll['response'] as String) as Map<String, dynamic>;
        break;
      }
    }
    if (probe?['ok'] != true ||
        (probe?['results'] as Map?)?.containsKey('validation') != true) {
      throw StateError(
        '${testCase.core.displayName} native probe contract failed.',
      );
    }
    stdout.writeln('${testCase.core.displayName}: configuration valid');
  }

  // All subsequent cases only parse synthetic documents. No TUN/core starts.
  final data = Platform.environment['NOZELT_DATA_DIR'];
  if (data == null ||
      !File('$data/core/geosite.dat').existsSync() ||
      !File('$data/core/geoip.dat').existsSync()) {
    throw StateError(
      'Supply NOZELT_DATA_DIR with bundled core/geosite.dat and core/geoip.dat; no test downloads.',
    );
  }
  final rules = [
    const RoutingRule(
      id: 'p',
      type: RoutingRuleType.processName,
      value: 'steam.exe',
      action: RoutingRuleAction.direct,
    ),
    const RoutingRule(
      id: 'd',
      type: RoutingRuleType.domain,
      value: 'blocked.test',
      action: RoutingRuleAction.reject,
    ),
    const RoutingRule(
      id: 's',
      type: RoutingRuleType.domainSuffix,
      value: 'example.test',
      action: RoutingRuleAction.proxy,
    ),
    const RoutingRule(
      id: 'ip',
      type: RoutingRuleType.ipCidr,
      value: '203.0.113.0/24',
      action: RoutingRuleAction.direct,
    ),
    const RoutingRule(
      id: 'geo',
      type: RoutingRuleType.geoIp,
      value: 'cn',
      action: RoutingRuleAction.proxy,
    ),
    const RoutingRule(
      id: 'site',
      type: RoutingRuleType.geoSite,
      value: 'google',
      action: RoutingRuleAction.proxy,
    ),
  ];
  for (final core in VpnCore.values) {
    final value = Profile(
      id: 'policy-validation',
      name: 'Validation',
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
          'tls': true,
          'servername': 'vpn.example.test',
        }),
      ],
      providerRouting: core == VpnCore.mihomo
          ? {
              'node-names': ['server'],
              'proxy-groups': [
                {
                  'name': 'Provider',
                  'type': 'select',
                  'proxies': ['server', 'DIRECT'],
                },
              ],
              'rule-providers': {
                'embedded': {
                  'type': 'inline',
                  'behavior': 'domain',
                  'payload': ['+.provider.test'],
                },
              },
              'sub-rules': {
                'nested': ['DOMAIN,sub.test,Provider', 'MATCH,PROXY'],
              },
              'rules': [
                'DOMAIN-REGEX,^provider[0-9]+\\.test\$,Provider',
                'RULE-SET,embedded,Provider',
                'SUB-RULE,(NETWORK,TCP),nested',
                'IP-CIDR,198.51.100.0/24,Provider,no-resolve',
                'MATCH,PROXY',
              ],
            }
          : {},
    );
    for (final mode in RoutingMode.values) {
      for (final ipv6 in [false, true]) {
        final rendered = MultiCoreConfigBuilder.build(
          TunSettings(
            routingMode: mode,
            ipv6: ipv6,
            customRules: rules,
            geoUpdateIntervalHours: 0,
          ),
          profile: value,
          desktopNativeTun: true,
        );
        final result =
            jsonDecode(
                  bridge.validateCoreConfig(core.wireName, rendered.content),
                )
                as Map;
        if (result['ok'] != true) {
          throw StateError(
            '${core.displayName} $mode ipv6=$ipv6 policy validation failed: $result',
          );
        }
        stdout.writeln(
          '${core.displayName}: $mode ipv6=$ipv6 process/domain/IP/Geo/provider config valid',
        );
      }
    }
  }
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
                      'address': '127.0.0.1',
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
                'streamSettings': {
                  'security': 'tls',
                  'tlsSettings': {'serverName': 'example.com'},
                },
              },
              {'tag': 'direct', 'protocol': 'freedom'},
            ],
            'routing': {
              'rules': [
                {
                  'type': 'field',
                  'domain': ['full:provider.test', 'geosite:google'],
                  'outboundTag': 'direct',
                },
                {
                  'type': 'field',
                  'ip': ['geoip:cn'],
                  'outboundTag': 'proxy',
                },
                {'type': 'field', 'network': 'tcp,udp', 'outboundTag': 'proxy'},
              ],
            },
          }
        : <String, dynamic>{
            'outbounds': [
              {
                'type': 'vless',
                'tag': 'proxy',
                'server': '127.0.0.1',
                'server_port': 443,
                'uuid': '11111111-1111-4111-8111-111111111111',
                'tls': {'enabled': true, 'server_name': 'example.com'},
              },
              {'type': 'direct', 'tag': 'direct'},
            ],
            'route': {
              'final': 'proxy',
              'rule_set': [
                {
                  'type': 'inline',
                  'tag': 'provider',
                  'rules': [
                    {
                      'domain_suffix': ['provider.test'],
                    },
                  ],
                },
              ],
              'rules': [
                {
                  'rule_set': ['provider'],
                  'action': 'route',
                  'outbound': 'direct',
                },
              ],
            },
          };
    final value = Profile(
      id: 'native-provider-validation',
      name: 'Validation',
      type: ProfileType.file,
      source: '',
      detectedCore: core,
      nodes: [
        ProxyNode.fromRaw({
          'name': 'server',
          'type': 'vless',
          'server': '127.0.0.1',
          'port': 443,
          'uuid': '11111111-1111-4111-8111-111111111111',
          'tls': true,
          'nozelt-native-core': core.wireName,
          'nozelt-native-config': native,
        }),
      ],
    );
    for (final mode in RoutingMode.values) {
      final rendered = MultiCoreConfigBuilder.build(
        TunSettings(routingMode: mode, geoUpdateIntervalHours: 0),
        profile: value,
        desktopNativeTun: true,
      );
      final result =
          jsonDecode(bridge.validateCoreConfig(core.wireName, rendered.content))
              as Map;
      if (result['ok'] != true) {
        throw StateError(
          '${core.displayName} native provider $mode rejected: $result',
        );
      }
      stdout.writeln(
        '${core.displayName}: native provider $mode configuration valid',
      );
    }
  }
}
