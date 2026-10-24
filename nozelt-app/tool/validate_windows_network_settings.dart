import 'dart:convert';
import 'dart:io';
import 'package:nozelt/src/core/advanced_network_settings.dart';
import 'package:nozelt/src/core/multi_core_config_builder.dart';
import 'package:nozelt/src/core/profile.dart';
import 'package:nozelt/src/core/proxy_node.dart';
import 'package:nozelt/src/core/tun_settings.dart';
import 'package:nozelt/src/core/vpn_core.dart';
import 'package:nozelt/src/core/windows_native_bridge.dart';

// Synthetic offline validation only. The DLL parses configs / asks native
// children to check syntax; it never starts a TUN, arms WFP or changes DNS.
void main() {
  final bridge = WindowsNativeBridge.open();
  var checked = 0;
  for (final core in VpnCore.values) {
    final profile = Profile(
      id: 'network-test',
      name: 'Network test',
      type: ProfileType.manual,
      source: '',
      detectedCore: core,
      nodes: [
        ProxyNode.fromRaw({
          'name': 'fixture',
          'type': 'vless',
          'server': 'vpn.example.test',
          'port': 443,
          'uuid': '11111111-1111-4111-8111-111111111111',
          'tls': true,
          'servername': 'vpn.example.test',
        }),
      ],
    );
    for (final stack in ['gvisor', 'system', 'mixed', 'mips']) {
      for (final mode in ['fake-ip', 'redir-host']) {
        for (final ipv6 in [false, true]) {
          for (final filter in ['blacklist', 'whitelist', 'rule']) {
            const resolver = 'https://9.9.9.9/dns-query';
            final s = TunSettings(
              ipv6: ipv6,
              stack: TunStack.fromName(stack),
              geoUpdateIntervalHours: 0,
              dns: AdvancedDnsSettings(
                mode: mode,
                filterMode: filter,
                filters: filter == 'rule'
                    ? [
                        'GEOSITE,google,fake-ip',
                        'DOMAIN-SUFFIX,real.test,real-ip',
                        'MATCH,fake-ip',
                      ]
                    : ['+.real.test', 'geosite:google'],
                fakeIpTtl: 37,
                cacheAlgorithm: 'arc',
                cacheSize: 8192,
                bootstrap: [resolver],
                directResolvers: [resolver],
                fallback: [resolver],
                policy: {
                  '+.policy.test': [resolver],
                  'geosite:google': [resolver],
                },
                proxyPolicy: {
                  'vpn.example.test': [resolver],
                },
                hosts: {
                  'nas.lan': ['192.168.1.10', 'fd00::10'],
                },
                fallbackGeoIp: true,
                fallbackCountry: 'RU',
                fallbackCidrs: ['240.0.0.0/4', '::/128'],
                fallbackDomains: ['+.fallback.test'],
              ),
              desktop: DesktopTunSettings(
                stackOverride: stack == 'mips' ? 'mips' : '',
                udpTimeout: 600,
                icmpTimeout: 45,
                disableIcmpForwarding: true,
                congestionController: 'bbr3',
                loopbackAddresses: ['10.0.0.1', 'fd00::1'],
              ),
            );
            final rendered = MultiCoreConfigBuilder.build(
              s,
              profile: profile,
              desktopNativeTun: true,
            );
            final result =
                jsonDecode(
                      bridge.validateCoreConfig(
                        core.wireName,
                        rendered.content,
                      ),
                    )
                    as Map;
            if (result['ok'] != true) {
              throw StateError(
                'Rejected ${core.name}/$stack/$mode/ipv6=$ipv6/$filter: ${result['code']}',
              );
            }
            checked++;
          }
        }
      }
    }
    stdout.writeln('${core.displayName}: 48 DNS/TUN combinations valid');
  }
  stdout.writeln(
    '$checked configurations validated; no TUN or system networking changes.',
  );
}
