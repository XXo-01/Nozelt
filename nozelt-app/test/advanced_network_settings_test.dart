import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:nozelt/src/core/advanced_network_settings.dart';
import 'package:nozelt/src/core/config_builder.dart';
import 'package:nozelt/src/core/multi_core_config_builder.dart';
import 'package:nozelt/src/core/profile.dart';
import 'package:nozelt/src/core/proxy_node.dart';
import 'package:nozelt/src/core/tun_settings.dart';
import 'package:nozelt/src/core/vpn_core.dart';

const endpoint = 'https://9.9.9.9/dns-query';
Profile fixture(VpnCore core) => Profile(
  id: 'test',
  name: 'test',
  type: ProfileType.manual,
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
  test('legacy preferences migrate with protected defaults', () {
    final s = TunSettings.fromMap({
      'mtu': 1500,
      'nameservers': ['1.1.1.1'],
    });
    expect(s.dns.mode, 'fake-ip');
    expect(s.dns.storeFakeIp, false);
    expect(s.desktop.udpTimeout, 300);
    expect(s.nameservers, ['https://1.1.1.1/dns-query']);
    expect(s.validationKey(), isNull);
  });

  test('all advanced settings survive persistence without losing routing', () {
    const s = TunSettings(
      ipv6: true,
      routingMode: RoutingMode.global,
      dns: AdvancedDnsSettings(
        mode: 'redir-host',
        filterMode: 'rule',
        filters: ['DOMAIN-SUFFIX,example.test,real-ip', 'MATCH,fake-ip'],
        fakeIpTtl: 60,
        cacheAlgorithm: 'arc',
        cacheSize: 8192,
        storeFakeIp: true,
        bootstrap: [endpoint],
        directResolvers: [endpoint],
        fallback: [endpoint],
        policy: {
          '+.example.test': [endpoint],
        },
        proxyPolicy: {
          'vpn.example.test': [endpoint],
        },
        hosts: {
          'nas.lan': ['192.168.1.10'],
        },
        fallbackCountry: 'US',
      ),
      desktop: DesktopTunSettings(
        stackOverride: 'mips',
        udpTimeout: 600,
        icmpTimeout: 45,
        disableIcmpForwarding: true,
        congestionController: 'bbr',
        loopbackAddresses: ['10.0.0.1'],
      ),
    );
    expect(TunSettings.decode(s.encode()).toMap(), s.toMap());
    expect(s.validationKey(), isNull);
  });

  test('every Windows transport uses the same DNS and TUN settings', () {
    const s = TunSettings(
      ipv6: true,
      dns: AdvancedDnsSettings(
        cacheAlgorithm: 'arc',
        fakeIpTtl: 37,
        bootstrap: [endpoint],
        directResolvers: [endpoint],
        fallback: [endpoint],
        policy: {
          '+.example.test': [endpoint],
        },
        proxyPolicy: {
          'vpn.example.test': [endpoint],
        },
        hosts: {
          'nas.lan': ['192.168.1.10'],
        },
        preferH3: true,
      ),
      desktop: DesktopTunSettings(
        stackOverride: 'mips',
        udpTimeout: 123,
        icmpTimeout: 12,
        congestionController: 'bbr3',
        loopbackAddresses: ['10.0.0.1'],
      ),
    );
    Map? reference;
    for (final core in VpnCore.values) {
      final config =
          jsonDecode(
                MultiCoreConfigBuilder.build(
                  s,
                  profile: fixture(core),
                  desktopNativeTun: true,
                ).content,
              )
              as Map;
      final frontend = (config['frontend'] ?? config) as Map;
      final dns = frontend['dns'] as Map;
      final tun = frontend['tun'] as Map;
      expect(dns['fallback'], ['$endpoint#PROXY']);
      expect(dns['direct-nameserver'], ['$endpoint#PROXY']);
      expect(dns['nameserver-policy']['+.example.test'], ['$endpoint#PROXY']);
      expect(dns['proxy-server-nameserver-policy']['vpn.example.test'], [
        endpoint,
      ]);
      expect(dns['default-nameserver'], [endpoint]);
      expect(dns['fake-ip-ttl'], 37);
      expect(dns['fake-ip-range6'], 'fdfe:dcba:9876::/64');
      expect(dns['respect-rules'], false);
      expect(frontend['hosts']['nas.lan'], ['192.168.1.10']);
      expect(tun['stack'], 'mips');
      expect(tun['udp-timeout'], 123);
      expect(tun['icmp-timeout'], 12);
      expect(tun['congestion-controller'], 'bbr3');
      expect(tun['strict-route'], true);
      expect(tun['auto-route'], true);
      expect(tun['dns-hijack'], ['udp://any:53', 'tcp://any:53']);
      if (reference != null) expect(dns, reference);
      reference = dns;
      if (core == VpnCore.xray) {
        final servers = config['transport']['dns']['servers'] as List;
        expect(servers.first['address'], endpoint);
        expect(servers.first['tag'], 'nozelt-endpoint-dns');
      } else if (core == VpnCore.singBox) {
        final servers = config['transport']['dns']['servers'] as List;
        expect(
          servers.firstWhere((v) => v['tag'] == 'bootstrap-0')['server'],
          '9.9.9.9',
        );
        expect(
          servers
              .firstWhere((v) => v['tag'] == 'bootstrap-0')
              .containsKey('detour'),
          false,
        );
      }
    }
  });

  test('Android takes advanced DNS/TUN options but keeps VPN ownership', () {
    const s = TunSettings(
      dns: AdvancedDnsSettings(
        mode: 'redir-host',
        storeFakeIp: true,
        useSystemHosts: true,
      ),
      desktop: DesktopTunSettings(stackOverride: 'mips', udpTimeout: 1000),
    );
    final config =
        jsonDecode(
              ConfigBuilder.buildConfig(
                s,
                nodes: fixture(VpnCore.mihomo).nodes,
              ),
            )
            as Map;
    // Shared Mihomo options follow the user's advanced settings.
    expect(config['dns']['enhanced-mode'], 'redir-host');
    expect(config['tun']['udp-timeout'], 1000);
    // Redir-Host needs the sniffer to keep domain rules working.
    expect(config['sniffer']['enable'], isTrue);
    // Windows-only host integration and routing ownership stay off.
    expect(config['profile']['store-fake-ip'], false);
    expect(config['dns']['use-system-hosts'], false);
    expect(config['tun']['stack'], 'gvisor');
    expect(config['tun']['auto-route'], false);
    expect(config['tun']['disable-icmp-forwarding'], true);
    expect(config['find-process-mode'], 'off');
  });

  test('resolver suffixes cannot override proxy, TLS or expose ECS', () {
    for (final value in [
      '$endpoint#DIRECT',
      '$endpoint#PROXY',
      '$endpoint#ecs=1.2.3.0/24',
      '$endpoint#skip-cert-verify=true',
      '$endpoint?ecs=1.2.3.4',
      'tls://1.1.1.1/path',
      'https://127.0.0.1/dns-query',
      'https://0.0.0.0/dns-query',
      'https://1.1.1.1:0/dns-query',
    ]) {
      expect(
        TunSettings(nameservers: [value]).validationKey(),
        isNotNull,
        reason: value,
      );
      expect(
        TunSettings(
          dns: AdvancedDnsSettings(fallback: [value]),
        ).validationKey(),
        isNotNull,
      );
      expect(
        TunSettings(
          dns: AdvancedDnsSettings(
            policy: {
              '+.example.test': [value],
            },
          ),
        ).validationKey(),
        isNotNull,
      );
    }
    expect(
      const TunSettings(nameservers: ['system']).validationKey(),
      'encryptedDnsOnly',
    );
    expect(
      const TunSettings(
        nameservers: ['https://dns.example/dns-query'],
      ).validationKey(),
      'dnsIpLiteralOnly',
    );
    expect(
      const TunSettings(
        nameservers: ['https://[2606:4700:4700::1111]/dns-query'],
      ).validationKey(),
      isNull,
    );
  });

  test(
    'DNS validation covers filters, cache, hosts, fallback and local policy',
    () {
      for (final dns in [
        const AdvancedDnsSettings(cacheSize: 0),
        const AdvancedDnsSettings(fakeIpTtl: 0),
        const AdvancedDnsSettings(fakeIpv6Range: '2001:db8::/64'),
        const AdvancedDnsSettings(
          filterMode: 'rule',
          filters: ['DOMAIN,example.test,DIRECT'],
        ),
        const AdvancedDnsSettings(
          filterMode: 'blacklist',
          filters: ['MATCH,fake-ip'],
        ),
        const AdvancedDnsSettings(
          policy: {
            '+.lan': [endpoint],
          },
        ),
        const AdvancedDnsSettings(
          hosts: {
            'example.test': ['not-an-ip'],
          },
        ),
        const AdvancedDnsSettings(fallbackCidrs: ['192.168.1.2/24']),
        const AdvancedDnsSettings(fallbackCountry: 'RUS'),
      ]) {
        expect(dns.validationKey(), isNotNull);
      }
      expect(
        const AdvancedDnsSettings(
          filterMode: 'rule',
          filters: ['DOMAIN,a.test,real-ip', 'MATCH,fake-ip'],
        ).validationKey(),
        isNull,
      );
    },
  );

  test('TUN rejects invalid timeouts and unsafe loopback targets', () {
    for (final tun in [
      const DesktopTunSettings(udpTimeout: 0),
      const DesktopTunSettings(icmpTimeout: 601),
      const DesktopTunSettings(stackOverride: 'foo'),
      const DesktopTunSettings(loopbackAddresses: ['1.1.1.1']),
      const DesktopTunSettings(loopbackAddresses: ['127.0.0.1']),
      const DesktopTunSettings(ipv6Address: '::1/128'),
    ]) {
      expect(tun.validationKey(), 'invalidAdvancedTun');
    }
  });
}
