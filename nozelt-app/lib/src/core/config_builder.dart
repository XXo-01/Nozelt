import 'dart:convert';
import 'dart:isolate';

import 'package:flutter/foundation.dart' show visibleForTesting;

import 'proxy_marks.dart';
import 'proxy_node.dart';
import 'routing_rule.dart';
import 'tun_settings.dart';

/// Maps the user-visible nodes selected for a delay test to the concrete
/// mihomo outbounds that must be probed. Ordinary nodes map one-to-one, while
/// automatic groups map to their hidden members and report the fastest
/// reachable member.
class DelayProbePlan {
  const DelayProbePlan._(this.namesByNode, this.testUrlsByNativeName);

  final Map<String, List<String>> namesByNode;
  final Map<String, String> testUrlsByNativeName;

  List<String> get nativeNames => [
    for (final names in namesByNode.values) ...names,
  ];

  Map<String, int?> aggregate(Map<String, int?> nativeDelays) {
    return {
      for (final entry in namesByNode.entries)
        entry.key: _minimumDelay(entry.value, nativeDelays),
    };
  }

  /// Aggregates only display nodes whose native result is already useful.
  /// A successful automatic member can be shown immediately; an unavailable
  /// automatic group is emitted only after every member has completed.
  Map<String, int?> aggregateCompleted(Map<String, int?> nativeDelays) {
    final completed = <String, int?>{};
    for (final entry in namesByNode.entries) {
      final delay = _minimumDelay(entry.value, nativeDelays);
      if (delay != null || entry.value.every(nativeDelays.containsKey)) {
        completed[entry.key] = delay;
      }
    }
    return completed;
  }

  static int? _minimumDelay(
    List<String> names,
    Map<String, int?> nativeDelays,
  ) {
    int? minimum;
    for (final name in names) {
      final delay = nativeDelays[name];
      if (delay == null || delay <= 0) continue;
      if (minimum == null || delay < minimum) minimum = delay;
    }
    return minimum;
  }
}

/// Assembles the mihomo config and the VpnService.Builder options from user
/// [TunSettings] and the active profile's [ProxyNode]s.
///
/// The config is emitted as **JSON** rather than hand-written YAML. JSON is a
/// valid subset of YAML, so mihomo's `config.Parse` accepts it (verified by a
/// Go unit test), and — crucially — it lets us inject mihomo's own proxy maps
/// (`node.raw`, with all their nested reality-opts/xhttp-opts/ws-opts) verbatim
/// without any fragile YAML string-building. The `start(configString)` pipeline
/// is unchanged; only the serialization format is.
///
/// Android invariants: `auto-route:false` because VpnService owns routes;
/// `auto-detect-interface:false` because sandboxed Android apps cannot create
/// sing-tun's netlink monitor; `dns-hijack:[any:53]`; `addDnsServer` routes
/// into the TUN; MTU is single-sourced with the VpnService. Mihomo egress is
/// excluded per socket through VpnService.protect(), not by excluding Nozelt's
/// complete UID from the tunnel.
class ConfigBuilder {
  const ConfigBuilder._();

  // Happ/Xray subscriptions commonly use the HTTP endpoint deliberately:
  // mobile white-list routes may permit it while the HTTPS endpoint is not
  // reachable. The request itself still traverses the encrypted proxy.
  static const String defaultDelayTestUrl =
      'http://www.gstatic.com/generate_204';
  static const String tunIpv4Address = '172.19.0.1';
  static const int tunIpv4Prefix = 30;
  static const String tunIpv6Address = 'fdfe:dcba:9876::1';
  static const int tunIpv6Prefix = 126;
  static const String tunnelDnsServer = '172.19.0.2';
  static const String vpnSessionName = 'Nozelt';

  static const String groupSelect = 'PROXY';

  /// Builds the full mihomo config string (JSON) from [s] and the active
  /// profile's [nodes]. Missing nodes fail closed: a VPN configuration must
  /// never silently degrade to direct Internet access.
  static String buildConfig(
    TunSettings s, {
    List<ProxyNode> nodes = const [],
    String? selectedNodeName,
    bool desktopNativeTun = false,
    Map<String, dynamic> providerRouting = const {},
    String providerCacheKey = 'profile',
    AutoExclusion autoExclusion = AutoExclusion.none,
  }) {
    if (s.validationKey() case final String error) {
      throw ArgumentError(error);
    }
    if (nodes.isEmpty) {
      throw StateError('A VPN config requires at least one proxy node.');
    }
    if (nodes.length > maxProxyNodes) {
      throw StateError('A VPN config exceeds the safe proxy node limit.');
    }
    if (nodes.any((node) => !node.isUsableOutbound)) {
      throw StateError('A VPN config contains a non-proxy or invalid node.');
    }
    final selectedIndex = selectedNodeName == null
        ? -1
        : nodes.indexWhere((node) => node.name == selectedNodeName);
    final safeNodes = ProxyNode.normalizeNames(nodes);
    final safeSelection = selectedIndex >= 0
        ? safeNodes[selectedIndex].name
        : safeNodes.first.name;
    final expanded = _expandAutomaticNodes(safeNodes, autoExclusion);
    final config = <String, dynamic>{
      // A TUN-only Android client must not expose localhost proxy/controller
      // sockets: Android apps share the device network namespace and another
      // app can probe loopback ports. All traffic enters through VpnService.
      'port': 0,
      'socks-port': 0,
      'mixed-port': 0,
      'external-controller': '',
      'bind-address': '127.0.0.1',
      // Keep mihomo itself in rule mode. Its built-in `global` mode routes
      // through the separate internal GLOBAL selector, whose selection is not
      // the Nozelt PROXY selector and can silently fall back to DIRECT. With
      // fake-IP DNS that means attempts to dial 198.18.0.0/15 on the physical
      // network, causing a retry/FD storm. Nozelt implements its user-facing
      // global mode as a single MATCH,PROXY rule instead.
      'mode': 'rule',
      // Measure the established proxy path instead of counting a cold
      // TLS/QUIC setup only when the VPN is stopped. Mihomo performs one
      // warm-up request and reports the repeated request through the same
      // connection, giving active and stopped tests comparable results.
      'unified-delay': true,
      'log-level': 'warning',
      'allow-lan': false,
      'ipv6': s.ipv6,
      // Windows desktop rules can resolve the originating executable. Android
      // split tunnelling remains owned by VpnService and must not ask Mihomo
      // to inspect platform processes.
      'find-process-mode': desktopNativeTun ? 'always' : 'off',
      // Nozelt owns selector persistence in its encrypted profile store.
      // Disabling mihomo's cache avoids a one-second attempt to open
      // /sdcard/.config/mihomo/cache.db and prevents duplicate state at rest.
      'profile': {
        'store-selected': false,
        'store-fake-ip':
            desktopNativeTun && s.dns.storeFakeIp && s.dns.mode == 'fake-ip',
      },
      if (s.dns.hosts.isNotEmpty) 'hosts': s.dns.hosts,
      'geodata-mode': true,
      // Android updates geodata itself through the tunnel (shared with
      // Xray); Mihomo's own updater would fetch it outside the VPN.
      'geo-auto-update': desktopNativeTun && s.geoUpdateIntervalHours > 0,
      if (desktopNativeTun && s.geoUpdateIntervalHours > 0)
        'geo-update-interval': s.geoUpdateIntervalHours,
      'geox-url': const {
        'geoip':
            'https://github.com/MetaCubeX/meta-rules-dat/releases/download/latest/geoip.dat',
        'geosite':
            'https://github.com/MetaCubeX/meta-rules-dat/releases/download/latest/geosite.dat',
      },
      'dns': _dns(s, desktopNativeTun: desktopNativeTun),
      'sniffer': _sniffer(s),
      'tun': _tun(s, desktopNativeTun: desktopNativeTun),
      'proxies': expanded.proxies,
      'proxy-groups': [
        ...expanded.groups,
        ..._proxyGroups(safeNodes, safeSelection),
      ],
      'rules': _rules(s, desktopNativeTun: desktopNativeTun),
    };
    // Provider routing (Clash/Mihomo subscription rules) applies on every
    // platform: after the user's rules and the LAN policy, before MATCH.
    if (s.routingMode == RoutingMode.rule && providerRouting.isNotEmpty) {
      _applyProviderRouting(
        config,
        providerRouting,
        safeNodes,
        providerCacheKey,
        autoExclusion,
      );
    }
    if (desktopNativeTun && s.routingMode == RoutingMode.rule) {
      final rules = (config['rules'] as List).cast<String>();
      final subRules =
          (config['sub-rules'] as Map?)?.values.expand(
            (value) => (value as List).cast<String>(),
          ) ??
          const <String>[];
      final providers = (config['rule-providers'] as Map?)?.values ?? const [];
      final externalProcessRules = providers.whereType<Map>().any(
        (provider) => provider['behavior'] == 'classical',
      );
      if (externalProcessRules ||
          [...rules, ...subRules].any((rule) => rule.contains('PROCESS-'))) {
        // A closed/short-lived socket, WSL or a VM can have no Windows owner.
        // Never let such traffic fall through a process policy to a DIRECT
        // rule: Internet traffic goes through the proxy instead of being
        // dropped, and local addresses keep the normal LAN policy below.
        final local = localRanges
            .map((range) => '(IP-CIDR,$range,no-resolve)')
            .join(',');
        rules.insert(
          0,
          'AND,((PROCESS-NAME-REGEX,^\$),(NOT,((OR,($local))))),$groupSelect',
        );
      }
    }
    return jsonEncode(config);
  }

  static void _applyProviderRouting(
    Map<String, dynamic> config,
    Map<String, dynamic> source,
    List<ProxyNode> nodes,
    String cacheKey,
    AutoExclusion autoExclusion,
  ) {
    final routing = (jsonDecode(jsonEncode(source)) as Map)
        .cast<String, dynamic>();
    final originalNames = (routing['node-names'] as List?) ?? const [];
    final names = <String, String>{
      for (var i = 0; i < originalNames.length && i < nodes.length; i++)
        originalNames[i].toString(): nodes[i].name,
    };
    final sourceGroups = (routing['proxy-groups'] as List?) ?? const [];
    for (var i = 0; i < sourceGroups.length; i++) {
      final group = sourceGroups[i] as Map;
      final name = group['name'].toString();
      // PROXY always remains Nozelt's explicit selected server.
      names[name] = name == groupSelect
          ? groupSelect
          : '__Nozelt provider group ${i + 1}';
    }
    for (final entry in sourceGroups) {
      final group = (entry as Map).cast<String, dynamic>();
      final original = group['name'].toString();
      if (original == groupSelect) continue;
      group['name'] = names[original];
      if (group['proxies'] case final List members) {
        group['proxies'] = members.map((name) => names[name] ?? name).toList();
      }
      (config['proxy-groups'] as List).add(group);
    }
    final providers =
        (routing['rule-providers'] as Map?)?.cast<String, dynamic>() ?? {};
    final safeKey = cacheKey.replaceAll(RegExp(r'[^a-zA-Z0-9_-]'), '_');
    var providerIndex = 0;
    for (final entry in providers.entries) {
      final provider = (entry.value as Map).cast<String, dynamic>();
      if (provider['type'] == 'file') {
        throw StateError(
          'The profile uses an external local rule file. Import its rules explicitly.',
        );
      }
      if (provider['type'] == 'http') {
        final url = Uri.tryParse(provider['url']?.toString() ?? '');
        if (url == null || url.scheme != 'https' || url.host.isEmpty) {
          throw StateError('Rule providers require HTTPS.');
        }
        provider['proxy'] = groupSelect;
      }
      providerIndex++;
      final extension = provider['format'] == 'mrs' ? 'mrs' : 'yaml';
      provider['path'] = 'rules/$safeKey-$providerIndex.$extension';
      providers[entry.key] = provider;
    }
    if (providers.isNotEmpty) config['rule-providers'] = providers;
    final groups = (config['proxy-groups'] as List).cast<Map>();
    final byName = {for (final group in groups) group['name']: group};

    // A provider document can name servers that were filtered out on import,
    // proxy-providers Nozelt does not load, or Mihomo's GLOBAL selector. Any
    // such reference would stop the whole VPN from starting, so unknown
    // members are dropped and unknown rule targets fall back to the selected
    // server (never to DIRECT).
    const builtins = {'DIRECT', 'REJECT', 'REJECT-DROP', 'PASS', 'COMPATIBLE'};
    final knownTargets = <String>{
      for (final proxy in (config['proxies'] as List).whereType<Map>())
        proxy['name'].toString(),
      for (final group in groups) group['name'].toString(),
    };
    bool isKnown(String target) =>
        knownTargets.contains(target) ||
        builtins.contains(target.toUpperCase());
    for (final group in groups) {
      if (!group['name'].toString().startsWith('__Nozelt provider group')) {
        continue;
      }
      group.remove('use');
      group.remove('include-all-providers');
      final members = ((group['proxies'] as List?) ?? const [])
          .map((member) => member.toString())
          .where(isKnown)
          .toList();
      final includesAll =
          group['include-all'] == true || group['include-all-proxies'] == true;
      group['proxies'] = members.isEmpty && !includesAll
          ? [groupSelect]
          : members;
    }
    bool canSelectDirect(Object? name, Set<Object?> seen) {
      if ({
        'DIRECT',
        'COMPATIBLE',
        'PASS',
      }.contains(name.toString().toUpperCase())) {
        return true;
      }
      if (!seen.add(name)) return true;
      final group = byName[name];
      if (group == null) return false;
      return ((group['proxies'] as List?) ?? const []).any(
        (member) => canSelectDirect(member, {...seen}),
      );
    }

    for (final group in groups.where(
      (group) =>
          {'url-test', 'fallback', 'load-balance'}.contains(group['type']),
    )) {
      final members = (group['proxies'] as List)
          .where((member) => !canSelectDirect(member, {}))
          .toList();
      if (members.isEmpty) {
        throw StateError('Automatic group has no protected proxy transport.');
      }
      group['proxies'] = members;
    }
    excludeDeletedFromAutomaticGroups(
      groups.map((group) => group.cast<String, dynamic>()).toList(),
      [
        for (final proxy in (config['proxies'] as List).whereType<Map>())
          proxy['name'].toString(),
      ],
      autoExclusion,
    );
    String rewriteRule(Object? raw) {
      final parts = raw.toString().split(',');
      if (parts.length < 2) throw StateError('Invalid provider routing rule.');
      final type = parts.first.trim().toUpperCase();
      final targetIndex = type == 'MATCH'
          ? 1
          : {
              'NOT',
              'OR',
              'AND',
              'SUB-RULE',
              'DOMAIN-REGEX',
              'PROCESS-NAME-REGEX',
              'PROCESS-PATH-REGEX',
            }.contains(type)
          ? parts.length - 1
          : 2;
      if (targetIndex >= parts.length) {
        throw StateError('Invalid provider routing target.');
      }
      final target = parts[targetIndex].trim();
      final mapped = names[target] ?? target;
      parts[targetIndex] = type == 'SUB-RULE' || isKnown(mapped)
          ? mapped
          : groupSelect;
      return parts.join(',');
    }

    final subRuleNames = <String>{
      if (routing['sub-rules'] case final Map subRules)
        ...subRules.keys.map((key) => key.toString()),
    };
    // A rule-set or sub-rule that is not part of the document cannot match
    // anything and would only make Mihomo refuse the configuration.
    bool usable(Object? raw) {
      final parts = raw.toString().split(',');
      final type = parts.first.trim().toUpperCase();
      if (type == 'RULE-SET' && parts.length > 1) {
        return providers.containsKey(parts[1].trim());
      }
      if (type == 'SUB-RULE' && parts.length > 2) {
        return subRuleNames.contains(parts.last.trim());
      }
      return true;
    }

    List<String> rewriteAll(List rules) =>
        rules.where(usable).map(rewriteRule).toList();

    final sourceRules = (routing['rules'] as List?) ?? const [];
    final currentRules = (config['rules'] as List).cast<String>();
    // User rules and local-network policy precede provider rules. Provider's
    // own terminal MATCH is retained; our final MATCH covers documents without it.
    currentRules.insertAll(currentRules.length - 1, rewriteAll(sourceRules));
    config['rules'] = currentRules;
    if (routing['sub-rules'] case final Map subRules) {
      config['sub-rules'] = subRules.map(
        (name, rules) => MapEntry(name, rewriteAll(rules as List)),
      );
    }
  }

  /// Keeps subscription-controlled nested maps from monopolizing Flutter's UI
  /// isolate while they are normalized and JSON-encoded. Node count alone is
  /// not a safe size proxy: one node may contain very large transport options,
  /// so every live configuration build uses a worker isolate.
  static Future<String> buildConfigAsync(
    TunSettings settings, {
    List<ProxyNode> nodes = const [],
    String? selectedNodeName,
    bool desktopNativeTun = false,
    AutoExclusion autoExclusion = AutoExclusion.none,
  }) {
    return Isolate.run(
      () => buildConfig(
        settings,
        nodes: nodes,
        selectedNodeName: selectedNodeName,
        desktopNativeTun: desktopNativeTun,
        autoExclusion: autoExclusion,
      ),
    );
  }

  /// Builds the concrete native probe-name mapping using the same automatic
  /// node expansion as [buildConfig]. The map keeps the profile's original
  /// display names as keys even if defensive normalization changes a
  /// mihomo-facing name.
  static DelayProbePlan buildDelayProbePlan(
    List<ProxyNode> nodes, {
    required Iterable<String> targetNodeNames,
    AutoExclusion autoExclusion = AutoExclusion.none,
  }) {
    if (nodes.isEmpty) return const DelayProbePlan._({}, {});
    final targets = targetNodeNames.toSet();
    final safeNodes = ProxyNode.normalizeNames(nodes);
    final expanded = _expandAutomaticNodes(safeNodes, autoExclusion);
    final namesByNode = <String, List<String>>{};
    final testUrlsByNativeName = <String, String>{};
    for (var index = 0; index < nodes.length; index++) {
      final originalName = nodes[index].name;
      if (!targets.contains(originalName)) continue;
      final safeName = safeNodes[index].name;
      final nativeNames = expanded.probeNames[safeName] ?? const <String>[];
      namesByNode[originalName] = List<String>.unmodifiable(nativeNames);
      final testUrl = delayTestUrlForNode(safeNodes[index]);
      for (final nativeName in nativeNames) {
        testUrlsByNativeName[nativeName] = testUrl;
      }
    }
    return DelayProbePlan._(
      Map.unmodifiable(namesByNode),
      Map.unmodifiable(testUrlsByNativeName),
    );
  }

  /// Resolves the provider's own connectivity endpoint for every node, not
  /// only automatic groups. Existing imported Xray documents may predate the
  /// flattened `nozelt-auto-url` field, so read burstObservatory directly as
  /// well. All cores then use the same validated URL and measurement rules.
  static String delayTestUrlForNode(ProxyNode node) {
    final candidates = <Object?>[node.raw['nozelt-auto-url']];
    final native = node.raw['nozelt-native-config'];
    if (native is Map) {
      final observatory = native['burstObservatory'];
      if (observatory is Map) {
        final ping = observatory['pingConfig'];
        if (ping is Map) candidates.add(ping['destination']);
      }
    }
    for (final raw in candidates) {
      final candidate = (raw ?? '').toString().trim();
      final parsed = Uri.tryParse(candidate);
      if (parsed != null &&
          (parsed.isScheme('http') || parsed.isScheme('https')) &&
          parsed.host.isNotEmpty &&
          parsed.userInfo.isEmpty) {
        return parsed.toString();
      }
    }
    return defaultDelayTestUrl;
  }

  static Map<String, dynamic> _dns(
    TunSettings s, {
    required bool desktopNativeTun,
  }) {
    final secureResolvers = s.nameservers;
    final advanced = s.dns;
    final bootstrap = advanced.bootstrap.isNotEmpty
        ? advanced.bootstrap
        : secureResolvers;
    List<String> viaProxy(List<String> values) =>
        values.map((v) => '$v#PROXY').toList();
    // Destination DNS must not inherit DIRECT process/IP rules. Only endpoint
    // bootstrap uses the physical network; both paths use encrypted resolvers.
    // Android relies on respect-rules instead, except with HTTP/3, which
    // Mihomo cannot combine with respect-rules.
    final destinationResolvers = desktopNativeTun || advanced.preferH3
        ? secureResolvers.map((value) => '$value#PROXY').toList()
        : secureResolvers;
    return {
      'enable': true,
      // dns-hijack feeds the in-process resolver directly. A UDP/TCP DNS
      // listener is unnecessary and would be visible to other local apps.
      // The advanced DNS settings apply on Android too; only Windows-only
      // host integration (system hosts file, persisted Fake-IP) is gated.
      'ipv6': s.ipv6 && advanced.ipv6,
      'enhanced-mode': advanced.mode,
      'fake-ip-range': s.fakeIpRange,
      if (s.ipv6) 'fake-ip-range6': advanced.fakeIpv6Range,
      'fake-ip-filter': advanced.filters,
      'fake-ip-filter-mode': advanced.filterMode,
      'fake-ip-ttl': advanced.fakeIpTtl,
      'ipv6-timeout': advanced.ipv6Timeout,
      'cache-algorithm': advanced.cacheAlgorithm,
      'cache-max-size': advanced.cacheSize,
      'prefer-h3': advanced.preferH3,
      'use-hosts': advanced.useHosts,
      'use-system-hosts': desktopNativeTun && advanced.useSystemHosts,
      'direct-nameserver-follow-policy': advanced.directFollowPolicy,
      if (advanced.proxyPolicy.isNotEmpty)
        'proxy-server-nameserver-policy': advanced.proxyPolicy,
      if (advanced.fallback.isNotEmpty) ...{
        'fallback': viaProxy(advanced.fallback),
        'fallback-lazy-query': advanced.fallbackLazy,
        'fallback-filter': {
          'geoip': advanced.fallbackGeoIp,
          'geoip-code': advanced.fallbackCountry,
          'ipcidr': advanced.fallbackCidrs,
          'domain': advanced.fallbackDomains,
        },
      },
      // Private/local and reverse-DNS names must not be forwarded to a public
      // resolver when LAN discovery is unavailable. rcode://success returns a
      // local empty answer and therefore leaks neither queried hostnames nor
      // private address structure. Native mDNS on UDP/5353 is unaffected.
      'nameserver-policy': {
        for (final entry in advanced.policy.entries)
          entry.key: viaProxy(entry.value),
        '+.lan': 'rcode://success',
        '+.local': 'rcode://success',
        'localhost': 'rcode://success',
        '+.localhost': 'rcode://success',
        '+.in-addr.arpa': 'rcode://success',
        '+.ip6.arpa': 'rcode://success',
      },
      // IP-literal encrypted resolvers are valid mihomo default nameservers
      // and need no bootstrap lookup. Reusing them here removes the final
      // plaintext-DNS fallback from the generated configuration.
      'default-nameserver': bootstrap,
      'nameserver': destinationResolvers,
      // Prevent the proxy server hostname from being resolved through the
      // proxy itself while still keeping that lookup encrypted.
      'proxy-server-nameserver': bootstrap,
      'direct-nameserver': advanced.directResolvers.isNotEmpty
          ? viaProxy(advanced.directResolvers)
          : destinationResolvers,
      // Explicit #PROXY keeps destination DNS private even when prefer-H3
      // disables respect-rules (an unsupported combination in Mihomo).
      'respect-rules': !advanced.preferH3,
    };
  }

  static Map<String, dynamic> _tun(
    TunSettings s, {
    required bool desktopNativeTun,
  }) {
    final tun = <String, dynamic>{
      'enable': true,
      'stack': s.stack.yamlValue,
      // These must stay false for a sandboxed Android VpnService. Enabling
      // either makes sing-tun create a netlink NetworkUpdateMonitor, which
      // Android denies. They are intentionally not user-configurable.
      'auto-route': desktopNativeTun,
      'auto-detect-interface': desktopNativeTun,
      'mtu': s.mtu,
      // Mihomo sends ping to a real IP DIRECT, outside the proxy and with
      // the real address. Android always answers ping inside the tunnel.
      if (!desktopNativeTun) 'disable-icmp-forwarding': true,
      // The UDP session timeout is a pure Mihomo setting, so Android takes
      // the same advanced value as Windows.
      'udp-timeout': s.desktop.udpTimeout,
    };
    if (desktopNativeTun) {
      final advanced = s.desktop;
      tun['device'] = 'Nozelt';
      if (advanced.stackOverride.isNotEmpty) {
        tun['stack'] = advanced.stackOverride;
      }
      tun['udp-timeout'] = advanced.udpTimeout;
      tun['icmp-timeout'] = advanced.icmpTimeout;
      tun['disable-icmp-forwarding'] = advanced.disableIcmpForwarding;
      if (advanced.stackOverride == 'mips') {
        tun['congestion-controller'] = advanced.congestionController;
      }
      if (advanced.loopbackAddresses.isNotEmpty) {
        tun['loopback-address'] = advanced.loopbackAddresses;
      }
      // Mihomo otherwise inherits its default IPv6 TUN address even when
      // Nozelt's IPv6 setting is off.
      tun['inet6-address'] = s.ipv6 ? [advanced.ipv6Address] : <String>[];
      // Windows strict-route adds DNS leak protection. Crash protection and
      // IPv6 enforcement belong to the separate Windows network guard.
      tun['strict-route'] = true;
    }
    // Mandatory on Android: without interception the synthetic DNS address
    // advertised by VpnService would be unreachable and domain rules could
    // not recover names from fake IPs.
    tun['dns-hijack'] = desktopNativeTun
        ? ['udp://any:53', 'tcp://any:53']
        : ['any:53'];
    return tun;
  }

  static Map<String, dynamic> _sniffer(TunSettings s) {
    // Redir-Host gives apps real addresses, so domain rules need the sniffer
    // to recover names; Fake-IP carries the name in its own mapping.
    if (!s.snifferEnabled && s.dns.mode != 'redir-host') {
      return {'enable': false};
    }
    return {
      'enable': true,
      // Fake-IP traffic already carries a DNS mapping. parse-pure-ip extends
      // rules to connections for which an application supplied only an IP.
      'force-dns-mapping': false,
      'parse-pure-ip': true,
      'override-destination': true,
      // Bound inspection to conventional clear HTTP and encrypted web ports.
      // Mihomo reads only Host/SNI/QUIC Initial metadata, never payload data.
      'sniff': {
        'HTTP': {
          'ports': ['80', '8080-8880'],
          'override-destination': true,
        },
        'TLS': {
          'ports': ['443', '8443'],
        },
        'QUIC': {
          'ports': ['443', '8443'],
        },
      },
    };
  }

  /// Proxy selector. Automatic selection is intentionally absent: Nozelt owns
  /// delay measurements and always uses the explicitly selected node.
  static List<Map<String, dynamic>> _proxyGroups(
    List<ProxyNode> nodes,
    String? selectedNodeName,
  ) {
    final names = nodes.map((n) => n.name).toList();
    final selected = names.contains(selectedNodeName)
        ? selectedNodeName!
        : names.first;
    final selectorEntries = [
      selected,
      ...names.where((name) => name != selected),
    ];
    return [
      {'name': groupSelect, 'type': 'select', 'proxies': selectorEntries},
    ];
  }

  /// Leaves deleted servers out of the provider's url-test, fallback and
  /// load-balance groups. A group that would end up empty keeps its members:
  /// an empty Mihomo group falls back to a direct connection.
  @visibleForTesting
  static void excludeDeletedFromAutomaticGroups(
    List<Map<String, dynamic>> groups,
    List<String> proxyNames,
    AutoExclusion exclusion,
  ) {
    if (exclusion.names.isEmpty) return;
    const automatic = {'url-test', 'fallback', 'load-balance'};
    for (final group in groups) {
      if (!automatic.contains(group['type'])) continue;
      final explicit = [
        for (final member in (group['proxies'] as List?) ?? const [])
          member.toString(),
      ];
      final includesAll =
          group['include-all'] == true || group['include-all-proxies'] == true;
      if (!includesAll) {
        if (explicit.isEmpty) continue;
        group['proxies'] = AutoExclusion.keepNonEmpty(
          explicit,
          exclusion.names.contains,
        );
        continue;
      }
      // Mihomo adds every proxy matching `filter`, then applies
      // `exclude-filter` to all members. Add the deleted names to that
      // filter only when Nozelt can tell the group keeps a member.
      final filters = _mihomoPatterns(group['filter']);
      final excludes = _mihomoPatterns(group['exclude-filter']);
      if (filters == null || excludes == null) continue;
      final members = [
        ...explicit,
        ...proxyNames.where(
          (name) => filters.isEmpty || filters.any((re) => re.hasMatch(name)),
        ),
      ].where((name) => !excludes.any((re) => re.hasMatch(name)));
      if (!members.any((name) => !exclusion.names.contains(name))) continue;
      final names = exclusion.names.toList()..sort();
      final pattern =
          '^(?:${names.map((name) => RegExp.escape(name).replaceAll('`', r'`')).join('|')})\$';
      final existing = group['exclude-filter']?.toString() ?? '';
      group['exclude-filter'] = existing.isEmpty
          ? pattern
          : '$existing`$pattern';
    }
  }

  /// Mihomo's backtick-separated group patterns as Dart expressions, or null
  /// when one cannot be read the same way.
  static List<RegExp>? _mihomoPatterns(Object? value) {
    final text = value?.toString() ?? '';
    if (text.isEmpty) return const [];
    final result = <RegExp>[];
    for (var pattern in text.split('`')) {
      var caseSensitive = true;
      if (pattern.startsWith('(?i)')) {
        pattern = pattern.substring(4);
        caseSensitive = false;
      }
      if (pattern.contains('(?')) {
        // Other inline options and look-arounds differ between engines.
        if (RegExp(r'\(\?[a-zA-Z]').hasMatch(pattern)) return null;
      }
      try {
        result.add(
          RegExp(pattern, caseSensitive: caseSensitive, unicode: true),
        );
      } on FormatException {
        return null;
      }
    }
    return result;
  }

  static ({
    List<Map<String, dynamic>> proxies,
    List<Map<String, dynamic>> groups,
    Map<String, List<String>> probeNames,
  })
  _expandAutomaticNodes(
    List<ProxyNode> nodes, [
    AutoExclusion exclusion = AutoExclusion.none,
  ]) {
    final proxies = <Map<String, dynamic>>[];
    final groups = <Map<String, dynamic>>[];
    final probeNames = <String, List<String>>{};
    final usedNames = {
      groupSelect.toLowerCase(),
      ...nodes.map((node) => node.name.toLowerCase()),
    };
    var groupIndex = 0;
    for (final node in nodes) {
      if (!node.isAutomaticGroup) {
        proxies.add(node.raw);
        probeNames[node.name] = [node.name];
        continue;
      }
      groupIndex++;
      final memberNames = <String>[];
      var memberIndex = 0;
      // Members that are copies of deleted servers are left out, unless that
      // would leave the group empty.
      final sources = AutoExclusion.keepNonEmpty(
        node.automaticMembers,
        (member) =>
            exclusion.excludesEndpoint(member['server'], member['port']),
      );
      for (final source in sources) {
        memberIndex++;
        var name = '__Nozelt auto $groupIndex member $memberIndex';
        while (!usedNames.add(name.toLowerCase())) {
          name = '$name node';
        }
        final member = Map<String, dynamic>.of(source)..['name'] = name;
        proxies.add(member);
        memberNames.add(name);
      }
      final rawInterval = int.tryParse(
        (node.raw['nozelt-auto-interval'] ?? '').toString(),
      );
      // Without a provider interval, re-test once a minute: every check wakes
      // the radio for all members, which costs battery on a phone.
      final interval = (rawInterval ?? 60).clamp(10, 3600).toInt();
      final testUrl = delayTestUrlForNode(node);
      groups.add({
        'name': node.name,
        'type': 'url-test',
        'proxies': memberNames,
        'url': testUrl,
        'interval': interval,
        'tolerance': 100,
        // Groups that carry no traffic are not tested in the background.
        'lazy': true,
      });
      probeNames[node.name] = memberNames;
    }
    return (proxies: proxies, groups: groups, probeNames: probeNames);
  }

  /// Private ranges that never belong to the public Internet. Shared by the
  /// Windows unknown-process guard and the Xray/sing-box LAN rules.
  static const List<String> localRanges = [
    '127.0.0.0/8',
    '::1/128',
    '10.0.0.0/8',
    '100.64.0.0/10',
    '172.16.0.0/12',
    '192.168.0.0/16',
    '169.254.0.0/16',
    '224.0.0.0/4',
    '255.255.255.255/32',
    'fc00::/7',
    'fe80::/10',
    'ff00::/8',
  ];

  /// Default routing: loopback → DIRECT; LAN/link-local/ULA → REJECT unless
  /// explicitly enabled; everything else → PROXY. User rules run first.
  static List<String> _rules(
    TunSettings settings, {
    required bool desktopNativeTun,
  }) {
    // Global mode sends all Internet traffic through the proxy, but local
    // addresses keep the LAN policy: a remote server cannot reach this LAN,
    // and its addresses should not be handed to the provider.
    final userRules = settings.routingMode == RoutingMode.global
        ? const <String>[]
        : settings.customRules
              .where(
                (rule) =>
                    rule.enabled &&
                    rule.validate() == null &&
                    (desktopNativeTun ||
                        rule.type != RoutingRuleType.processName),
              )
              .map((rule) => rule.toMihomoRule(groupSelect));
    final lanAction = settings.allowLan ? 'DIRECT' : 'REJECT';
    return [
      ...userRules,
      'IP-CIDR,127.0.0.0/8,DIRECT,no-resolve',
      'IP-CIDR,::1/128,DIRECT,no-resolve',
      'IP-CIDR,10.0.0.0/8,$lanAction,no-resolve',
      // Carrier-grade NAT is not globally routable and frequently exposes
      // ISP/mobile underlay services. Treat it like LAN, not public Internet.
      'IP-CIDR,100.64.0.0/10,$lanAction,no-resolve',
      'IP-CIDR,172.16.0.0/12,$lanAction,no-resolve',
      'IP-CIDR,192.168.0.0/16,$lanAction,no-resolve',
      'IP-CIDR,169.254.0.0/16,$lanAction,no-resolve',
      // Multicast and limited broadcast are common local discovery escape
      // paths (SSDP, vendor discovery, etc.). They follow the same explicit
      // LAN-access switch instead of silently touching the physical network.
      'IP-CIDR,224.0.0.0/4,$lanAction,no-resolve',
      'IP-CIDR,255.255.255.255/32,$lanAction,no-resolve',
      'IP-CIDR,fc00::/7,$lanAction,no-resolve',
      'IP-CIDR,fe80::/10,$lanAction,no-resolve',
      'IP-CIDR,ff00::/8,$lanAction,no-resolve',
      'MATCH,$groupSelect',
    ];
  }

  /// Builds the VpnService.Builder option bundle. MTU and IPv6 come from [s]
  /// so they stay in lockstep with the config `tun` section.
  static Map<String, dynamic> buildTunOptions(
    TunSettings s, {
    String splitMode = 'off',
    List<String> apps = const [],
  }) {
    return <String, dynamic>{
      'mtu': s.mtu,
      'ipv4Address': tunIpv4Address,
      'ipv4Prefix': tunIpv4Prefix,
      'ipv6Enabled': s.ipv6,
      'ipv6Address': tunIpv6Address,
      'ipv6Prefix': tunIpv6Prefix,
      'dnsServers': <String>[tunnelDnsServer],
      'session': vpnSessionName,
      'splitMode': splitMode,
      'apps': apps,
    };
  }
}
