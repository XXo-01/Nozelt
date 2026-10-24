import 'dart:io';

/// Windows DNS options. Resolver addresses never contain Mihomo dialer/ECS
/// suffixes: the builder owns the encrypted bootstrap and PROXY boundaries.
class AdvancedDnsSettings {
  const AdvancedDnsSettings({
    this.mode = 'fake-ip',
    this.filterMode = 'blacklist',
    this.filters = const ['*.lan', '*.local', 'localhost', 'localhost.*'],
    this.fakeIpv6Range = 'fdfe:dcba:9876::/64',
    this.fakeIpTtl = 1,
    this.ipv6 = true,
    this.ipv6Timeout = 100,
    this.cacheAlgorithm = 'lru',
    this.cacheSize = 4096,
    this.storeFakeIp = false,
    this.preferH3 = false,
    this.useHosts = true,
    this.useSystemHosts = true,
    this.bootstrap = const [],
    this.directResolvers = const [],
    this.fallback = const [],
    this.policy = const {},
    this.proxyPolicy = const {},
    this.hosts = const {},
    this.directFollowPolicy = false,
    this.fallbackGeoIp = false,
    this.fallbackCountry = 'RU',
    this.fallbackCidrs = const ['240.0.0.0/4'],
    this.fallbackDomains = const [],
    this.fallbackLazy = true,
  });

  final String mode, filterMode, fakeIpv6Range, cacheAlgorithm, fallbackCountry;
  final int fakeIpTtl, cacheSize, ipv6Timeout;
  final bool ipv6, storeFakeIp, preferH3, useHosts, useSystemHosts;
  final bool directFollowPolicy, fallbackGeoIp, fallbackLazy;
  final List<String> filters, bootstrap, directResolvers, fallback;
  final List<String> fallbackCidrs, fallbackDomains;
  final Map<String, List<String>> policy, proxyPolicy, hosts;

  static const protectedDomains = {
    '+.lan',
    '+.local',
    'localhost',
    '+.localhost',
    '+.in-addr.arpa',
    '+.ip6.arpa',
  };

  String? validationKey() {
    if (!{'fake-ip', 'redir-host'}.contains(mode) ||
        !{'blacklist', 'whitelist', 'rule'}.contains(filterMode) ||
        !{'lru', 'arc'}.contains(cacheAlgorithm) ||
        fakeIpTtl < 1 ||
        fakeIpTtl > 86400 ||
        cacheSize < 32 ||
        cacheSize > 65536 ||
        ipv6Timeout < 0 ||
        ipv6Timeout > 10000 ||
        !validCidr(fakeIpv6Range, ipv6Ula: true) ||
        int.parse(fakeIpv6Range.split('/').last) > 112) {
      return 'invalidAdvancedDns';
    }
    if (filters.length > 2048 || filters.any((s) => !_safeLine(s))) {
      return 'invalidDnsFilter';
    }
    for (final filter in filters) {
      if (filterMode == 'rule') {
        final parts = filter.split(',');
        final kind = parts.first;
        if (!{
              'DOMAIN',
              'DOMAIN-SUFFIX',
              'DOMAIN-KEYWORD',
              'GEOSITE',
              'MATCH',
            }.contains(kind) ||
            parts.length != (kind == 'MATCH' ? 2 : 3) ||
            !{'fake-ip', 'real-ip'}.contains(parts.last) ||
            (kind != 'MATCH' && parts[1].trim().isEmpty)) {
          return 'invalidDnsFilter';
        }
      } else if (filter.contains(',') || filter.contains('rule-set:')) {
        // Global DNS settings cannot depend on a particular proxy profile's
        // optional provider. GEOSITE/domain filters remain portable.
        return 'invalidDnsFilter';
      }
    }
    if (filterMode == 'rule' &&
        (filters.isEmpty || !filters.last.startsWith('MATCH,'))) {
      return 'invalidDnsFilter';
    }
    for (final values in [bootstrap, directResolvers, fallback]) {
      if (values.length > 8) return 'invalidDns';
      for (final endpoint in values) {
        final error = validateEncryptedResolver(endpoint);
        if (error != null) return error;
      }
    }
    for (final policies in [policy, proxyPolicy]) {
      if (policies.length > 256) return 'invalidDnsPolicy';
      for (final entry in policies.entries) {
        if (!_safeLine(entry.key) ||
            entry.key.contains(',') ||
            entry.key.contains('rule-set:') ||
            _protectedPolicyName(entry.key) ||
            entry.value.isEmpty ||
            entry.value.length > 8) {
          return 'invalidDnsPolicy';
        }
        for (final endpoint in entry.value) {
          final error = validateEncryptedResolver(endpoint);
          if (error != null) return error;
        }
      }
    }
    if (hosts.length > 256) return 'invalidDnsHosts';
    for (final entry in hosts.entries) {
      if (!_safeLine(entry.key) ||
          entry.key.contains(',') ||
          entry.value.isEmpty ||
          entry.value.length > 16 ||
          entry.value.any((s) => InternetAddress.tryParse(s) == null)) {
        return 'invalidDnsHosts';
      }
    }
    if (!RegExp(r'^[A-Z]{2}$').hasMatch(fallbackCountry) ||
        fallbackCidrs.length > 256 ||
        fallbackCidrs.any((s) => !validCidr(s)) ||
        fallbackDomains.length > 256 ||
        fallbackDomains.any((s) => !_safeLine(s))) {
      return 'invalidDnsFallback';
    }
    return null;
  }

  Map<String, dynamic> toMap() => {
    'mode': mode,
    'filterMode': filterMode,
    'filters': filters,
    'fakeIpv6Range': fakeIpv6Range,
    'fakeIpTtl': fakeIpTtl,
    'ipv6Timeout': ipv6Timeout,
    'ipv6': ipv6,
    'cacheAlgorithm': cacheAlgorithm,
    'cacheSize': cacheSize,
    'storeFakeIp': storeFakeIp,
    'preferH3': preferH3,
    'useHosts': useHosts,
    'useSystemHosts': useSystemHosts,
    'bootstrap': bootstrap,
    'directResolvers': directResolvers,
    'fallback': fallback,
    'policy': policy,
    'proxyPolicy': proxyPolicy,
    'hosts': hosts,
    'directFollowPolicy': directFollowPolicy,
    'fallbackGeoIp': fallbackGeoIp,
    'fallbackCountry': fallbackCountry,
    'fallbackCidrs': fallbackCidrs,
    'fallbackDomains': fallbackDomains,
    'fallbackLazy': fallbackLazy,
  };

  factory AdvancedDnsSettings.fromMap(Map<String, dynamic> m) {
    const d = AdvancedDnsSettings();
    return AdvancedDnsSettings(
      mode: m['mode'] as String? ?? d.mode,
      filterMode: m['filterMode'] as String? ?? d.filterMode,
      filters: _list(m['filters'], d.filters),
      fakeIpv6Range: m['fakeIpv6Range'] as String? ?? d.fakeIpv6Range,
      fakeIpTtl: (m['fakeIpTtl'] as num?)?.toInt() ?? d.fakeIpTtl,
      ipv6Timeout: (m['ipv6Timeout'] as num?)?.toInt() ?? d.ipv6Timeout,
      ipv6: m['ipv6'] as bool? ?? d.ipv6,
      cacheAlgorithm: m['cacheAlgorithm'] as String? ?? d.cacheAlgorithm,
      cacheSize: (m['cacheSize'] as num?)?.toInt() ?? d.cacheSize,
      storeFakeIp: m['storeFakeIp'] as bool? ?? d.storeFakeIp,
      preferH3: m['preferH3'] as bool? ?? d.preferH3,
      useHosts: m['useHosts'] as bool? ?? d.useHosts,
      useSystemHosts: m['useSystemHosts'] as bool? ?? d.useSystemHosts,
      bootstrap: _list(m['bootstrap']),
      directResolvers: _list(m['directResolvers']),
      fallback: _list(m['fallback']),
      policy: _map(m['policy']),
      proxyPolicy: _map(m['proxyPolicy']),
      hosts: _map(m['hosts']),
      directFollowPolicy:
          m['directFollowPolicy'] as bool? ?? d.directFollowPolicy,
      fallbackGeoIp: m['fallbackGeoIp'] as bool? ?? d.fallbackGeoIp,
      fallbackCountry: m['fallbackCountry'] as String? ?? d.fallbackCountry,
      fallbackCidrs: _list(m['fallbackCidrs'], d.fallbackCidrs),
      fallbackDomains: _list(m['fallbackDomains']),
      fallbackLazy: m['fallbackLazy'] as bool? ?? d.fallbackLazy,
    );
  }
}

/// Parameters implemented by the bundled Windows sing-tun frontend. Capture
/// and DNS leak prevention are invariants, not user-disableable tuning knobs.
class DesktopTunSettings {
  const DesktopTunSettings({
    this.stackOverride = '',
    this.udpTimeout = 300,
    this.icmpTimeout = 30,
    this.disableIcmpForwarding = true,
    this.congestionController = 'cubic',
    this.loopbackAddresses = const [],
    this.ipv6Address = 'fdfe:dcba:9876::1/126',
  });
  final String stackOverride, congestionController, ipv6Address;
  final int udpTimeout, icmpTimeout;
  final bool disableIcmpForwarding;
  final List<String> loopbackAddresses;

  String? validationKey() {
    if (!{'', 'mips'}.contains(stackOverride) ||
        udpTimeout < 30 ||
        udpTimeout > 86400 ||
        icmpTimeout < 1 ||
        icmpTimeout > 600 ||
        !{'cubic', 'reno', 'bbr', 'bbr3'}.contains(congestionController) ||
        !validCidr(ipv6Address, ipv6Ula: true, aligned: false) ||
        loopbackAddresses.length > 16 ||
        loopbackAddresses.any((s) {
          final ip = InternetAddress.tryParse(s);
          return ip == null ||
              ip.isLoopback ||
              ip.isMulticast ||
              ip.isLinkLocal ||
              !(ip.type == InternetAddressType.IPv4
                  ? ip.rawAddress[0] == 10 ||
                        (ip.rawAddress[0] == 172 &&
                            ip.rawAddress[1] >= 16 &&
                            ip.rawAddress[1] <= 31) ||
                        (ip.rawAddress[0] == 192 && ip.rawAddress[1] == 168)
                  : (ip.rawAddress[0] & 0xfe) == 0xfc);
        })) {
      return 'invalidAdvancedTun';
    }
    return null;
  }

  Map<String, dynamic> toMap() => {
    'stackOverride': stackOverride,
    'udpTimeout': udpTimeout,
    'icmpTimeout': icmpTimeout,
    // A new key: the former default (false) forwarded ping to real IPs past
    // the VPN with the real address. Old saved values must not keep that.
    'disableIcmpForwardingV2': disableIcmpForwarding,
    'congestionController': congestionController,
    'loopbackAddresses': loopbackAddresses,
    'ipv6Address': ipv6Address,
  };
  factory DesktopTunSettings.fromMap(Map<String, dynamic> m) =>
      DesktopTunSettings(
        stackOverride: m['stackOverride'] as String? ?? '',
        udpTimeout: (m['udpTimeout'] as num?)?.toInt() ?? 300,
        icmpTimeout: (m['icmpTimeout'] as num?)?.toInt() ?? 30,
        disableIcmpForwarding: m['disableIcmpForwardingV2'] as bool? ?? true,
        congestionController: m['congestionController'] as String? ?? 'cubic',
        loopbackAddresses: _list(m['loopbackAddresses']),
        ipv6Address: m['ipv6Address'] as String? ?? 'fdfe:dcba:9876::1/126',
      );
}

String? validateEncryptedResolver(String endpoint) {
  if (endpoint.length > 2048 ||
      endpoint.trim() != endpoint ||
      endpoint.contains(RegExp(r'\s'))) {
    return 'invalidDns';
  }
  final uri = Uri.tryParse(endpoint);
  if (uri == null || !{'https', 'tls', 'quic'}.contains(uri.scheme)) {
    return 'encryptedDnsOnly';
  }
  if (InternetAddress.tryParse(uri.host) == null) return 'dnsIpLiteralOnly';
  if (uri.userInfo.isNotEmpty ||
      uri.hasFragment ||
      uri.hasQuery ||
      (uri.hasPort && (uri.port < 1 || uri.port > 65535)) ||
      (uri.scheme == 'https'
          ? uri.path.isEmpty || uri.path == '/'
          : uri.path.isNotEmpty)) {
    return 'invalidDns';
  }
  final ip = InternetAddress.tryParse(uri.host)!;
  if (ip.isLoopback ||
      ip.isMulticast ||
      ip.isLinkLocal ||
      ip.rawAddress.every((b) => b == 0)) {
    return 'invalidDns';
  }
  return null;
}

bool validCidr(String value, {bool ipv6Ula = false, bool aligned = true}) {
  final parts = value.split('/');
  if (parts.length != 2) return false;
  final ip = InternetAddress.tryParse(parts[0]);
  final bits = int.tryParse(parts[1]);
  if (ip == null ||
      bits == null ||
      bits < 0 ||
      bits > ip.rawAddress.length * 8) {
    return false;
  }
  if (ipv6Ula &&
      (ip.type != InternetAddressType.IPv6 ||
          (ip.rawAddress[0] & 0xfe) != 0xfc ||
          bits < 64 ||
          bits > 126)) {
    return false;
  }
  if (!aligned) return true;
  for (var bit = bits; bit < ip.rawAddress.length * 8; bit++) {
    if ((ip.rawAddress[bit ~/ 8] & (1 << (7 - bit % 8))) != 0) return false;
  }
  return true;
}

bool _safeLine(String s) =>
    s.isNotEmpty && s.length <= 512 && !s.contains(RegExp(r'\s|[\x00-\x1f]'));

bool _protectedPolicyName(String pattern) {
  final domain = pattern.toLowerCase().replaceFirst(RegExp(r'^[+*.]+'), '');
  return [
    'lan',
    'local',
    'localhost',
    'in-addr.arpa',
    'ip6.arpa',
  ].any((suffix) => domain == suffix || domain.endsWith('.$suffix'));
}

List<String> _list(Object? value, [List<String> fallback = const []]) =>
    value is List ? value.cast<String>().toList(growable: false) : fallback;
Map<String, List<String>> _map(Object? value) => value is Map
    ? value.map((k, v) => MapEntry(k as String, _list(v)))
    : const {};
