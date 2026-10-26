import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:flutter/foundation.dart' show visibleForTesting;

import 'config_builder.dart';
import 'config_error.dart';
import 'profile.dart';
import 'proxy_marks.dart';
import 'proxy_node.dart';
import 'routing_rule.dart';
import 'tun_settings.dart';
import 'vpn_core.dart';

class CoreRenderedConfig {
  const CoreRenderedConfig({required this.core, required this.content});

  final VpnCore core;
  final String content;
}

class NativeCoreProbeTarget {
  const NativeCoreProbeTarget({
    required this.name,
    required this.config,
    required this.url,
  });

  final String name;
  final String config;
  final String url;

  Map<String, dynamic> toJson() => {'name': name, 'config': config, 'url': url};
}

class MultiCoreConfigBuilder {
  const MultiCoreConfigBuilder._();

  static Future<CoreRenderedConfig> buildAsync(
    TunSettings settings, {
    required Profile profile,
    bool desktopNativeTun = false,
  }) {
    return Isolate.run(
      () =>
          build(settings, profile: profile, desktopNativeTun: desktopNativeTun),
    );
  }

  static CoreRenderedConfig build(
    TunSettings settings, {
    required Profile profile,
    bool desktopNativeTun = false,
  }) {
    final core = profile.effectiveCore;
    if (desktopNativeTun) {
      for (final node in profile.nodes) {
        _requireVerifiedTls(node.raw);
      }
    }
    if (desktopNativeTun && core != VpnCore.mihomo) {
      // One TUN/routing/telemetry layer for every Windows transport core.
      // Native allocates a loopback port and fresh SOCKS credentials at start.
      final selected = _selected(profile);
      final transportSettings = settings.copyWith(
        customRules: const [],
        routingMode: RoutingMode.global,
      );
      final transport =
          jsonDecode(
                core == VpnCore.xray
                    ? _buildXray(
                        transportSettings,
                        profile,
                        windowsTransport: true,
                      )
                    : _buildSingBox(
                        transportSettings,
                        profile,
                        windowsTransport: true,
                      ),
              )
              as Map<String, dynamic>;
      _protectWindowsAutomaticFallbacks(transport, core);
      if (core == VpnCore.xray && settings.routingMode == RoutingMode.rule) {
        _requireOriginalProcessContext(transport['routing']);
      }
      if (core == VpnCore.singBox && settings.routingMode == RoutingMode.rule) {
        _requireOriginalProcessContext(transport['route']);
      }
      if (core == VpnCore.xray) {
        _configureWindowsXrayDns(transport, settings);
      } else {
        _configureWindowsSingBoxDns(transport, settings);
      }
      final frontend =
          jsonDecode(
                ConfigBuilder.buildConfig(
                  settings,
                  nodes: [
                    ProxyNode.fromRaw({
                      'name': selected.name,
                      'type': 'socks5',
                      'server': '127.0.0.1',
                      'port': 1,
                      'udp': true,
                    }),
                  ],
                  selectedNodeName: selected.name,
                  desktopNativeTun: true,
                ),
              )
              as Map<String, dynamic>;
      return CoreRenderedConfig(
        core: core,
        content: jsonEncode({
          'nozeltWindowsRelay': 1,
          'transport': transport,
          'frontend': frontend,
        }),
      );
    }
    final content = switch (core) {
      VpnCore.mihomo => ConfigBuilder.buildConfig(
        settings,
        nodes: profile.nodes,
        selectedNodeName: profile.effectiveSelectedNodeName,
        desktopNativeTun: desktopNativeTun,
        providerRouting: profile.providerRouting,
        providerCacheKey: profile.id,
        autoExclusion: profile.autoExclusion,
      ),
      VpnCore.xray => _buildXray(
        settings,
        profile,
        desktopNativeTun: desktopNativeTun,
      ),
      VpnCore.singBox => _buildSingBox(
        settings,
        profile,
        desktopNativeTun: desktopNativeTun,
      ),
    };
    return CoreRenderedConfig(core: core, content: content);
  }

  static void _requireVerifiedTls(Object? value) {
    if (value is Map) {
      for (final entry in value.entries) {
        if (const {
              'skip-cert-verify',
              'allowInsecure',
              'allow_insecure',
              'insecure',
            }.contains(entry.key) &&
            (entry.value == true || entry.value == 'true')) {
          throw CoreConfigurationError(
            'windowsTlsVerificationRequired',
            'Windows requires TLS certificate verification. Correct the server certificate or profile.',
          );
        }
        _requireVerifiedTls(entry.value);
      }
    } else if (value is List) {
      for (final item in value) {
        _requireVerifiedTls(item);
      }
    }
  }

  static void _requireOriginalProcessContext(Object? value) {
    if (value is Map) {
      if (const {
        'process_name',
        'process_path',
        'process_path_regex',
        'user',
        'user_id',
        'package_name',
        'package_name_regex',
        'source_ip_cidr',
        'source_ip_is_private',
        'source_geoip',
        'source_port',
        'source_port_range',
        'rule_set_ip_cidr_match_source',
        'inbound',
        'auth_user',
        'source',
        'sourcePort',
        'inboundTag',
      }.any(value.containsKey)) {
        throw CoreConfigurationError(
          'windowsProviderProcessRulesUnsupported',
          'Windows provider rules require original source context. Use supported Nozelt Routing rules.',
        );
      }
      for (final child in value.values) {
        _requireOriginalProcessContext(child);
      }
    } else if (value is List) {
      for (final child in value) {
        _requireOriginalProcessContext(child);
      }
    }
  }

  /// Every server name an Xray outbound dials: classic vnext/servers lists,
  /// the flat `settings.address` of newer VLESS/Hysteria documents, WireGuard
  /// endpoints and XHTTP download servers nested in streamSettings. A name
  /// missed here would be resolved through the tunnel it is building.
  static List<String> xrayEndpointHosts(Map outbound) {
    final hosts = <String>[];
    void walk(Object? value) {
      if (value is Map) {
        for (final entry in value.entries) {
          final child = entry.value;
          if (entry.key == 'address' && child is String) {
            hosts.add(child);
          } else if (entry.key == 'endpoint' && child is String) {
            final host = Uri.tryParse('udp://$child')?.host;
            if (host != null) hosts.add(host);
          } else {
            walk(child);
          }
        }
      } else if (value is List) {
        value.forEach(walk);
      }
    }

    walk(outbound['settings']);
    walk(outbound['streamSettings']);
    return hosts;
  }

  static void _configureWindowsXrayDns(
    Map<String, dynamic> document,
    TunSettings settings,
  ) {
    // System DNS returns the frontend's fake IPs after TUN starts. Resolve
    // transport endpoints with Xray's own encrypted DNS instead, and send
    // those bootstrap requests through a dedicated, bound freedom outbound.
    // Xray does not support Mihomo's tls:// and quic:// resolver syntax.
    final bootstrapServers = settings.dns.bootstrap.isEmpty
        ? settings.nameservers
        : settings.dns.bootstrap;
    final servers = settings.nameservers
        .where((value) => Uri.parse(value).scheme == 'https')
        .toList();
    if (servers.isEmpty) {
      throw StateError('Windows Xray requires an HTTPS DNS resolver.');
    }
    final endpointServers = bootstrapServers
        .where((v) => Uri.parse(v).scheme == 'https')
        .toList();
    if (endpointServers.isEmpty) {
      throw StateError(
        'Windows Xray requires an HTTPS bootstrap DNS resolver.',
      );
    }
    final dns = document['dns'] is Map
        ? Map<String, dynamic>.from(document['dns'] as Map)
        : <String, dynamic>{};
    final dnsTag = 'nozelt-internal-dns';
    dns['tag'] = dnsTag;
    final endpoints = <String>{};
    final outbounds = document['outbounds'] as List;
    for (final outbound in outbounds.whereType<Map>()) {
      for (final host in xrayEndpointHosts(outbound)) {
        if (host.isNotEmpty && InternetAddress.tryParse(host) == null) {
          endpoints.add('full:$host');
        }
      }
    }
    final bootstrapDnsTag = 'nozelt-endpoint-dns';
    dns['servers'] = [
      if (endpoints.isNotEmpty)
        for (final server in endpointServers)
          {
            'address': server,
            'domains': endpoints.toList(),
            'skipFallback': true,
            'tag': bootstrapDnsTag,
          },
      ...servers,
    ];
    dns['disableFallbackIfMatch'] = true;
    dns.remove('clientIp');
    dns.remove('clientIP');
    dns['queryStrategy'] = settings.ipv6 ? 'UseIP' : 'UseIPv4';
    document['dns'] = dns;
    final excluded = outbounds
        .whereType<Map>()
        .where(
          (item) => {'freedom', 'blackhole', 'dns'}.contains(item['protocol']),
        )
        .map((item) => item['tag'].toString())
        .toSet();
    final proxyTarget = _nativeXrayProxyTarget(
      document,
      excludedOutboundTags: excluded,
    );
    if (proxyTarget == null) {
      throw StateError('Windows Xray has no DNS proxy transport.');
    }
    final usedTags = outbounds
        .whereType<Map>()
        .map((item) => item['tag'])
        .toSet();
    var tag = 'nozelt-bootstrap';
    while (usedTags.contains(tag)) {
      tag = '$tag-1';
    }
    outbounds.add({'tag': tag, 'protocol': 'freedom'});
    final routing = document['routing'] is Map
        ? Map<String, dynamic>.from(document['routing'] as Map)
        : <String, dynamic>{};
    final rules = List<dynamic>.from(routing['rules'] as List? ?? const []);
    rules.insert(0, {
      'type': 'field',
      // Match DNS-generated traffic, never all traffic to resolver IPs.
      'inboundTag': [bootstrapDnsTag],
      'outboundTag': tag,
    });
    rules.insert(1, {
      'type': 'field',
      'inboundTag': [dnsTag],
      proxyTarget.$1: proxyTarget.$2,
    });
    if (settings.routingMode == RoutingMode.global) {
      rules.replaceRange(2, rules.length, [
        {'type': 'field', 'network': 'tcp,udp', proxyTarget.$1: proxyTarget.$2},
      ]);
    }
    routing['rules'] = rules;
    document['routing'] = routing;
  }

  static void _configureWindowsSingBoxDns(
    Map<String, dynamic> document,
    TunSettings settings,
  ) {
    final outbounds = (document['outbounds'] as List).whereType<Map>().toList();
    final route = (document['route'] as Map).cast<String, dynamic>();
    final remote = outbounds
        .where((item) => !{'direct', 'block', 'dns'}.contains(item['type']))
        .toList();
    if (remote.isEmpty) {
      throw StateError('Windows sing-box has no DNS proxy transport.');
    }
    final byTag = {for (final item in outbounds) item['tag']: item};
    bool safe(Object? tag, Set<Object?> seen) {
      if (!seen.add(tag)) return false;
      final item = byTag[tag];
      if (item == null || {'direct', 'block', 'dns'}.contains(item['type'])) {
        return false;
      }
      if (item['outbounds'] case final List members) {
        return members.isNotEmpty &&
            members.every((member) => safe(member, {...seen}));
      }
      return true;
    }

    final safeRemote = remote.where((item) => safe(item['tag'], {})).toList();
    if (safeRemote.isEmpty) {
      throw StateError('Windows DNS has no protected proxy transport.');
    }
    final proxyTags = safeRemote.map((item) => item['tag']).toSet();
    final proxyTag = proxyTags.contains(route['final'])
        ? route['final']
        : safeRemote.first['tag'];
    for (final ruleSet
        in (route['rule_set'] as List? ?? const []).whereType<Map>()) {
      if (ruleSet['type'] == 'local') {
        throw StateError(
          'Import Windows provider local rule sets into Nozelt Routing.',
        );
      }
      if (ruleSet['type'] == 'remote') {
        final url = Uri.tryParse(ruleSet['url']?.toString() ?? '');
        if (url == null || url.scheme != 'https' || url.host.isEmpty) {
          throw StateError('Windows remote rule sets require HTTPS.');
        }
        ruleSet['download_detour'] = proxyTag;
      }
    }
    final dns = _singBoxDNS(settings);
    final servers = (dns['servers'] as List).cast<Map<String, dynamic>>();
    final bootstrapSettings = settings.copyWith(
      nameservers: settings.dns.bootstrap.isEmpty
          ? settings.nameservers
          : settings.dns.bootstrap,
    );
    final bootstrapServers = (_singBoxDNS(bootstrapSettings)['servers'] as List)
        .cast<Map<String, dynamic>>();
    final bootstrap = <Map<String, dynamic>>[
      for (var i = 0; i < bootstrapServers.length; i++)
        {...bootstrapServers[i], 'tag': 'bootstrap-$i'},
    ];
    for (var i = 0; i < servers.length; i++) {
      servers[i]['detour'] = proxyTag;
    }
    servers.addAll(bootstrap);
    for (final item in outbounds) {
      if (item['server'] is String) item['domain_resolver'] = 'bootstrap-0';
      if (item['type'] == 'direct') item['domain_resolver'] = 'dns-0';
    }
    // Destination lookups use the proxy; only transport endpoint resolution
    // explicitly selects a physical, encrypted bootstrap resolver.
    route['default_domain_resolver'] = 'dns-0';
    if (settings.routingMode == RoutingMode.global) {
      route['rules'] = <dynamic>[];
      route.remove('rule_set');
      route['final'] = proxyTag;
    }
    document['dns'] = dns;
    document['route'] = route;
  }

  static void _protectWindowsAutomaticFallbacks(
    Map<String, dynamic> document,
    VpnCore core,
  ) {
    final outbounds = (document['outbounds'] as List).whereType<Map>().toList();
    final directTags = outbounds
        .where(
          (item) => core == VpnCore.xray
              ? item['protocol'] == 'freedom'
              : item['type'] == 'direct',
        )
        .map((item) => item['tag'])
        .toSet();
    if (core == VpnCore.xray) {
      final routing = document['routing'];
      if (routing is Map && routing['balancers'] is List) {
        for (final balancer
            in (routing['balancers'] as List).whereType<Map>()) {
          final prefixes = (balancer['selector'] as List?) ?? const [];
          final candidates = outbounds
              .where(
                (item) =>
                    !{
                      'freedom',
                      'blackhole',
                      'dns',
                    }.contains(item['protocol']) &&
                    prefixes.any(
                      (prefix) =>
                          item['tag'].toString().startsWith(prefix.toString()),
                    ),
              )
              .map((item) => item['tag'])
              .toList();
          if (candidates.isEmpty) {
            throw StateError(
              'Windows balancer has no protected proxy transport.',
            );
          }
          if (directTags.any(
            (tag) => candidates.any(
              (prefix) => tag.toString().startsWith(prefix.toString()),
            ),
          )) {
            throw StateError(
              'Windows balancer prefix includes a direct transport.',
            );
          }
          balancer['selector'] = candidates;
          if (directTags.contains(balancer['fallbackTag'])) {
            balancer.remove('fallbackTag');
          }
        }
      }
    } else {
      final byTag = {for (final item in outbounds) item['tag']: item};
      bool canSelectDirect(Object? tag, Set<Object?> visited) {
        if (directTags.contains(tag)) return true;
        if (!visited.add(tag)) return true;
        final item = byTag[tag];
        if (item == null) return true;
        if (item['outbounds'] case final List members) {
          return members.any((member) => canSelectDirect(member, {...visited}));
        }
        return false;
      }

      for (final item in outbounds.where((item) => item['type'] == 'urltest')) {
        final members = (item['outbounds'] as List)
            .where((tag) => !canSelectDirect(tag, {}))
            .toList();
        if (members.isEmpty) {
          throw StateError(
            'Windows automatic group has no protected proxy transport.',
          );
        }
        item['outbounds'] = members;
      }
    }
  }

  /// Renders each requested node with its own real native core. Automatic
  /// Xray documents retain their provider balancer/observatory, so their
  /// measured path is exactly the path used by the VPN process.
  static Future<List<NativeCoreProbeTarget>> buildNativeProbeTargetsAsync(
    TunSettings settings, {
    required Profile profile,
    required Iterable<String> targetNodeNames,
    bool desktopNativeTun = false,
  }) {
    return Isolate.run(() {
      if (profile.effectiveCore == VpnCore.mihomo) {
        throw StateError('Mihomo probes use ConfigBuilder.');
      }
      final requested = targetNodeNames.toSet();
      return [
        for (final node in profile.nodes)
          if (requested.contains(node.name))
            NativeCoreProbeTarget(
              name: node.name,
              config: desktopNativeTun
                  ? jsonEncode(
                      (jsonDecode(
                            build(
                              settings,
                              profile: profile.copyWith(
                                selectedNodeName: node.name,
                              ),
                              desktopNativeTun: true,
                            ).content,
                          )
                          as Map)['transport'],
                    )
                  : switch (profile.effectiveCore) {
                      VpnCore.xray => _buildXrayProbe(
                        settings,
                        profile.copyWith(selectedNodeName: node.name),
                      ),
                      VpnCore.singBox => _buildSingBox(
                        settings,
                        profile.copyWith(selectedNodeName: node.name),
                      ),
                      VpnCore.mihomo => throw StateError('unreachable'),
                    },
              url: _nativeProbeUrl(node),
            ),
      ];
    });
  }

  static String _nativeProbeUrl(ProxyNode node) {
    return ConfigBuilder.delayTestUrlForNode(node);
  }

  static String _buildXrayProbe(TunSettings settings, Profile profile) {
    final document = (jsonDecode(_buildXray(settings, profile)) as Map)
        .cast<String, dynamic>();
    final routing = document['routing'];
    final balancers = routing is Map ? routing['balancers'] : null;
    final usesProviderBalancer = balancers is List && balancers.isNotEmpty;

    // Standalone Happ/Xray entries often retain a burstObservatory even
    // though no routing rule or balancer consumes it. Starting that observer
    // beside Nozelt's own HTTP probe creates two concurrent handshakes through
    // the same Hysteria/QUIC outbound. On restricted mobile transports this
    // causes otherwise usable nodes to time out. Keep provider observation
    // only where it is semantically required to choose an AUTO member; Nozelt
    // always performs the final user-visible delay measurement itself.
    if (!usesProviderBalancer) {
      document.remove('observatory');
      document.remove('burstObservatory');
    }
    return jsonEncode(document);
  }

  static ProxyNode _selected(Profile profile) {
    final node = profile.selectedNode;
    if (node == null || !node.isUsableOutbound) {
      throw StateError('The selected profile has no usable proxy node.');
    }
    return node;
  }

  /// [windowsTransport] marks the Windows relay transport: the Mihomo
  /// frontend already applied every routing and LAN rule, so the transport
  /// gets none of its own.
  static String _buildXray(
    TunSettings settings,
    Profile profile, {
    bool desktopNativeTun = false,
    bool windowsTransport = false,
  }) {
    final node = _selected(profile);
    final native = node.raw['nozelt-native-config'];
    final document = native is Map
        ? _deepMap(native)
        : <String, dynamic>{
            'log': {'loglevel': 'warning'},
            'outbounds': [
              _mihomoToXray(node.raw),
              {'tag': 'direct', 'protocol': 'freedom'},
              {'tag': 'block', 'protocol': 'blackhole'},
              {'tag': 'dns-out', 'protocol': 'dns'},
            ],
            'dns': {
              'queryStrategy': settings.ipv6 ? 'UseIP' : 'UseIPv4',
              'servers': settings.nameservers,
            },
            'routing': {
              'domainStrategy': 'IPIfNonMatch',
              'rules': _xrayRules(
                settings,
                desktopNativeTun: desktopNativeTun,
                windowsTransport: windowsTransport,
              ),
            },
          };

    // Android sends DNS packets addressed to the VpnService's virtual DNS
    // endpoint through the TUN. Provider-native Xray documents normally
    // expect a local SOCKS client to resolve DNS and therefore often omit the
    // dns outbound/rule entirely. Without this augmentation Xray forwards
    // 172.19.0.2:53 through the selected proxy as ordinary UDP, which breaks
    // both standalone and balancer-backed subscriptions.
    document.putIfAbsent(
      'dns',
      () => {
        'queryStrategy': settings.ipv6 ? 'UseIP' : 'UseIPv4',
        'servers': settings.nameservers,
      },
    );
    if (native is Map) {
      excludeFromXrayBalancers(document, profile.autoExclusion);
    }
    final dnsOutboundTag = _ensureXrayDnsOutbound(document);
    _ensureXrayDnsRule(document, dnsOutboundTag);
    if (native is Map && !windowsTransport) {
      _applyNativeXrayRules(
        settings,
        document,
        dnsOutboundTag,
        desktopNativeTun: desktopNativeTun,
      );
    }

    // Subscription-provided local SOCKS/HTTP inbounds are inappropriate in an
    // Android TUN client. Keep all outbounds, balancers and observatories but
    // replace inbounds with the descriptor-backed interface owned by Nozelt.
    document['inbounds'] = [
      {
        'tag': 'nozelt-tun',
        'protocol': 'tun',
        'settings': desktopNativeTun
            ? {
                'name': 'Nozelt-Xray',
                'desc': 'Nozelt Xray',
                'mtu': settings.mtu,
                'gateway': [
                  '${ConfigBuilder.tunIpv4Address}/${ConfigBuilder.tunIpv4Prefix}',
                  if (settings.ipv6)
                    '${ConfigBuilder.tunIpv6Address}/${ConfigBuilder.tunIpv6Prefix}',
                ],
                'dns': [ConfigBuilder.tunnelDnsServer],
                'userLevel': 0,
                'autoSystemRoutingTable': [
                  '0.0.0.0/0',
                  if (settings.ipv6) '::/0',
                ],
                'autoOutboundsInterface': 'auto',
              }
            : {'name': 'tun0', 'MTU': settings.mtu, 'userLevel': 0},
        // Xray has no fake-IP mapping: without sniffing a connection carries
        // only an address and every domain/GeoSite rule (Nozelt's and the
        // provider's) silently misses. routeOnly keeps the original address
        // when the user has not asked for destination override.
        'sniffing': {
          'enabled': true,
          'destOverride': ['http', 'tls', 'quic'],
          'routeOnly': !settings.snifferEnabled,
        },
      },
    ];
    document['log'] = {'loglevel': 'warning'};
    return jsonEncode(document);
  }

  /// Every `address`/`port` pair an Xray outbound dials.
  static Set<String> _xrayEndpointKeys(Map outbound) {
    final keys = <String>{};
    void walk(Object? value) {
      if (value is Map) {
        if (value['address'] is String && value['port'] != null) {
          keys.add(AutoExclusion.endpointKey(value['address'], value['port']));
        }
        value.values.forEach(walk);
      } else if (value is List) {
        value.forEach(walk);
      }
    }

    walk(outbound['settings']);
    return keys;
  }

  /// Leaves deleted servers out of a native Xray document's balancers.
  /// Balancers pick members by tag prefix, so excluded outbounds get a tag no
  /// selector matches; references to them follow. A balancer that would be
  /// left without members keeps them all.
  @visibleForTesting
  static void excludeFromXrayBalancers(
    Map<String, dynamic> document,
    AutoExclusion exclusion,
  ) {
    if (exclusion.endpoints.isEmpty) return;
    final routing = document['routing'];
    final balancers = routing is Map ? routing['balancers'] : null;
    if (balancers is! List || balancers.isEmpty) return;
    final outbounds = (document['outbounds'] as List? ?? const [])
        .whereType<Map>()
        .toList();
    final prefixes = <String>{
      for (final balancer in balancers.whereType<Map>())
        for (final prefix in (balancer['selector'] as List?) ?? const [])
          prefix.toString(),
    };
    for (final key in const ['observatory', 'burstObservatory']) {
      if (document[key] case final Map observatory) {
        for (final prefix
            in (observatory['subjectSelector'] as List?) ?? const []) {
          prefixes.add(prefix.toString());
        }
      }
    }
    bool selected(Object? tag) =>
        prefixes.any((prefix) => tag.toString().startsWith(prefix));
    final renames = <String, String>{};
    for (final balancer in balancers.whereType<Map>()) {
      final own = [
        for (final prefix in (balancer['selector'] as List?) ?? const [])
          prefix.toString(),
      ];
      final members = outbounds
          .where(
            (item) =>
                !{'freedom', 'blackhole', 'dns'}.contains(item['protocol']) &&
                own.any((prefix) => item['tag'].toString().startsWith(prefix)),
          )
          .toList();
      final excluded = members
          .where(
            (item) => _xrayEndpointKeys(item).any(exclusion.endpoints.contains),
          )
          .toList();
      if (excluded.isEmpty || excluded.length == members.length) continue;
      for (final item in excluded) {
        final tag = item['tag'].toString();
        if (renames.containsKey(tag)) continue;
        var next = 'nozelt-excluded-${renames.length + 1}';
        while (selected(next) ||
            outbounds.any((other) => other['tag'] == next)) {
          next = '~$next';
          if (next.length > 64) return;
        }
        renames[tag] = next;
      }
    }
    if (renames.isEmpty) return;
    for (final item in outbounds) {
      final tag = item['tag']?.toString();
      if (renames[tag] case final String next) item['tag'] = next;
    }
    void retarget(Object? value) {
      if (value is Map) {
        for (final key in const ['outboundTag', 'fallbackTag', 'dialerProxy']) {
          final current = value[key];
          if (current is String && renames.containsKey(current)) {
            value[key] = renames[current];
          }
        }
        value.values.forEach(retarget);
      } else if (value is List) {
        value.forEach(retarget);
      }
    }

    retarget(document['routing']);
    for (final item in outbounds) {
      retarget(item['streamSettings']);
      if (item['proxySettings'] case final Map proxy) {
        final current = proxy['tag'];
        if (current is String && renames.containsKey(current)) {
          proxy['tag'] = renames[current];
        }
      }
    }
  }

  /// Leaves deleted servers out of a native sing-box document's urltest
  /// outbounds, unless that would leave one empty.
  @visibleForTesting
  static void excludeFromSingBoxUrlTests(
    Map<String, dynamic> document,
    AutoExclusion exclusion,
  ) {
    if (exclusion.endpoints.isEmpty) return;
    final outbounds = (document['outbounds'] as List? ?? const [])
        .whereType<Map>()
        .toList();
    final byTag = {for (final item in outbounds) item['tag']: item};
    bool excluded(Object? tag) {
      final item = byTag[tag];
      return item != null &&
          item['server'] != null &&
          exclusion.excludesEndpoint(item['server'], item['server_port']);
    }

    for (final item in outbounds.where((item) => item['type'] == 'urltest')) {
      final members = (item['outbounds'] as List?)?.toList();
      if (members == null || members.isEmpty) continue;
      item['outbounds'] = AutoExclusion.keepNonEmpty(members, excluded);
    }
  }

  static String _ensureXrayDnsOutbound(Map<String, dynamic> document) {
    final outbounds = switch (document['outbounds']) {
      final List value => value,
      _ => <dynamic>[],
    };
    document['outbounds'] = outbounds;

    for (final raw in outbounds) {
      if (raw is! Map || raw['protocol']?.toString().toLowerCase() != 'dns') {
        continue;
      }
      final tag = raw['tag']?.toString().trim() ?? '';
      if (tag.isNotEmpty) return tag;
    }

    final usedTags = outbounds
        .whereType<Map>()
        .map((outbound) => outbound['tag']?.toString().trim() ?? '')
        .where((tag) => tag.isNotEmpty)
        .toSet();
    var tag = 'dns-out';
    var suffix = 2;
    while (usedTags.contains(tag)) {
      tag = 'dns-out-$suffix';
      suffix += 1;
    }
    outbounds.add({'tag': tag, 'protocol': 'dns'});
    return tag;
  }

  static void _ensureXrayDnsRule(
    Map<String, dynamic> document,
    String dnsOutboundTag,
  ) {
    final routing = switch (document['routing']) {
      final Map value => value.cast<String, dynamic>(),
      _ => <String, dynamic>{},
    };
    document['routing'] = routing;
    final rules = switch (routing['rules']) {
      final List value => value,
      _ => <dynamic>[],
    };
    routing['rules'] = rules;

    final hasDnsRule = rules.whereType<Map>().any((rule) {
      final port = rule['port']?.toString().trim();
      return port == '53' && rule['outboundTag'] == dnsOutboundTag;
    });
    if (hasDnsRule) return;

    rules.insert(0, {
      'type': 'field',
      'network': 'tcp,udp',
      'port': '53',
      'outboundTag': dnsOutboundTag,
    });
  }

  static void _applyNativeXrayRules(
    TunSettings settings,
    Map<String, dynamic> document,
    String dnsOutboundTag, {
    required bool desktopNativeTun,
  }) {
    final enabledRules = settings.routingMode == RoutingMode.rule
        ? settings.customRules.where((rule) => rule.enabled)
        : const <RoutingRule>[];

    final directTag = _ensureXrayProtocolOutbound(
      document,
      protocol: 'freedom',
      preferredTag: 'nozelt-direct',
    );
    final blockTag = _ensureXrayProtocolOutbound(
      document,
      protocol: 'blackhole',
      preferredTag: 'nozelt-block',
    );
    final proxyTarget = _nativeXrayProxyTarget(
      document,
      excludedOutboundTags: {directTag, blockTag, dnsOutboundTag},
    );
    final injected = <Map<String, dynamic>>[];

    for (final rule in enabledRules) {
      final rendered = <String, dynamic>{'type': 'field'};
      switch (rule.type) {
        case RoutingRuleType.geoIp:
          rendered['ip'] = ['geoip:${rule.normalizedValue}'];
          break;
        case RoutingRuleType.geoSite:
          rendered['domain'] = ['geosite:${rule.normalizedValue}'];
          break;
        case RoutingRuleType.domain:
          rendered['domain'] = ['full:${rule.normalizedValue}'];
          break;
        case RoutingRuleType.domainSuffix:
          rendered['domain'] = ['domain:${rule.normalizedValue}'];
          break;
        case RoutingRuleType.domainKeyword:
          rendered['domain'] = ['keyword:${rule.normalizedValue}'];
          break;
        case RoutingRuleType.ipCidr:
          rendered['ip'] = [rule.normalizedValue];
          break;
        case RoutingRuleType.processName:
          if (!desktopNativeTun) continue;
          rendered['process'] = [rule.normalizedValue];
          break;
      }
      switch (rule.action) {
        case RoutingRuleAction.direct:
          rendered['outboundTag'] = directTag;
          break;
        case RoutingRuleAction.reject:
          rendered['outboundTag'] = blockTag;
          break;
        case RoutingRuleAction.proxy:
          if (proxyTarget == null) continue;
          rendered[proxyTarget.$1] = proxyTarget.$2;
          break;
      }
      injected.add(rendered);
    }
    injected.addAll(
      _xrayLocalRules(settings, directTag: directTag, blockTag: blockTag),
    );

    final routing = (document['routing'] as Map).cast<String, dynamic>();
    final rules = routing['rules'] as List;
    var insertionIndex = 0;
    for (var index = 0; index < rules.length; index++) {
      final raw = rules[index];
      if (raw is Map &&
          raw['port']?.toString().trim() == '53' &&
          raw['outboundTag'] == dnsOutboundTag) {
        insertionIndex = index + 1;
      }
    }
    rules.insertAll(insertionIndex, injected);
  }

  static String _ensureXrayProtocolOutbound(
    Map<String, dynamic> document, {
    required String protocol,
    required String preferredTag,
  }) {
    final outbounds = document['outbounds'] as List;
    for (final raw in outbounds) {
      if (raw is! Map ||
          raw['protocol']?.toString().toLowerCase() != protocol) {
        continue;
      }
      final tag = raw['tag']?.toString().trim() ?? '';
      if (tag.isNotEmpty) return tag;
    }
    final used = outbounds
        .whereType<Map>()
        .map((outbound) => outbound['tag']?.toString().trim() ?? '')
        .where((tag) => tag.isNotEmpty)
        .toSet();
    var tag = preferredTag;
    var suffix = 2;
    while (used.contains(tag)) {
      tag = '$preferredTag-$suffix';
      suffix += 1;
    }
    outbounds.add({'tag': tag, 'protocol': protocol});
    return tag;
  }

  static (String, String)? _nativeXrayProxyTarget(
    Map<String, dynamic> document, {
    required Set<String> excludedOutboundTags,
  }) {
    final routing = document['routing'];
    final rules = routing is Map ? routing['rules'] : null;
    if (rules is List) {
      for (final raw in rules.reversed) {
        if (raw is! Map) continue;
        final matchingKeys = raw.keys
            .map((key) => key.toString())
            .where(
              (key) => !{
                'type',
                'network',
                'outboundTag',
                'balancerTag',
                'ruleTag',
              }.contains(key),
            );
        if (matchingKeys.isNotEmpty) continue;
        final balancer = raw['balancerTag']?.toString().trim() ?? '';
        if (balancer.isNotEmpty) return ('balancerTag', balancer);
        final outbound = raw['outboundTag']?.toString().trim() ?? '';
        if (outbound.isNotEmpty && !excludedOutboundTags.contains(outbound)) {
          return ('outboundTag', outbound);
        }
      }
    }
    final balancers = routing is Map ? routing['balancers'] : null;
    if (balancers is List) {
      for (final raw in balancers) {
        if (raw is! Map) continue;
        final tag = raw['tag']?.toString().trim() ?? '';
        if (tag.isNotEmpty) return ('balancerTag', tag);
      }
    }
    final outbounds = document['outbounds'];
    if (outbounds is List) {
      for (final raw in outbounds) {
        if (raw is! Map) continue;
        final tag = raw['tag']?.toString().trim() ?? '';
        final protocol = raw['protocol']?.toString().toLowerCase() ?? '';
        if (tag.isNotEmpty &&
            !excludedOutboundTags.contains(tag) &&
            !{'freedom', 'blackhole', 'dns'}.contains(protocol)) {
          return ('outboundTag', tag);
        }
      }
    }
    return null;
  }

  static List<Map<String, dynamic>> _xrayRules(
    TunSettings settings, {
    bool desktopNativeTun = false,
    bool windowsTransport = false,
  }) {
    final rules = <Map<String, dynamic>>[
      {
        'type': 'field',
        'network': 'tcp,udp',
        'port': '53',
        'outboundTag': 'dns-out',
      },
    ];
    if (settings.routingMode == RoutingMode.rule) {
      for (final rule in settings.customRules.where((rule) => rule.enabled)) {
        final target = switch (rule.action) {
          RoutingRuleAction.proxy => 'proxy',
          RoutingRuleAction.direct => 'direct',
          RoutingRuleAction.reject => 'block',
        };
        final value = rule.normalizedValue;
        final rendered = <String, dynamic>{
          'type': 'field',
          'outboundTag': target,
        };
        switch (rule.type) {
          case RoutingRuleType.geoIp:
            rendered['ip'] = ['geoip:$value'];
            break;
          case RoutingRuleType.geoSite:
            rendered['domain'] = ['geosite:$value'];
            break;
          case RoutingRuleType.domain:
            rendered['domain'] = ['full:$value'];
            break;
          case RoutingRuleType.domainSuffix:
            rendered['domain'] = ['domain:$value'];
            break;
          case RoutingRuleType.domainKeyword:
            rendered['domain'] = ['keyword:$value'];
            break;
          case RoutingRuleType.ipCidr:
            rendered['ip'] = [value];
            break;
          case RoutingRuleType.processName:
            if (!desktopNativeTun) {
              // Android process matching is implemented by VpnService. Xray
              // can discover originating processes itself on Windows.
              continue;
            }
            rendered['process'] = [value];
            break;
        }
        rules.add(rendered);
      }
    }
    if (!windowsTransport) {
      rules.addAll(
        _xrayLocalRules(settings, directTag: 'direct', blockTag: 'block'),
      );
    }
    if (settings.routingMode == RoutingMode.global) {
      rules.add({
        'type': 'field',
        'network': 'tcp,udp',
        'outboundTag': 'proxy',
      });
    }
    // Rule mode has no catch-all rule on purpose: it would count as a match
    // and stop IPIfNonMatch from resolving names for GeoIP/IP rules. The
    // first outbound (the proxy) is Xray's default for unmatched traffic.
    return rules;
  }

  /// Same local-address policy as Mihomo: loopback stays local, LAN ranges
  /// follow the "Allow LAN" switch, in rule and global mode alike.
  static List<Map<String, dynamic>> _xrayLocalRules(
    TunSettings settings, {
    required String directTag,
    required String blockTag,
  }) {
    final lan = ConfigBuilder.localRanges
        .where((range) => range != '127.0.0.0/8' && range != '::1/128')
        .toList(growable: false);
    return [
      {
        'type': 'field',
        'ip': ['127.0.0.0/8', '::1/128'],
        'outboundTag': directTag,
      },
      {
        'type': 'field',
        'ip': lan,
        'outboundTag': settings.allowLan ? directTag : blockTag,
      },
    ];
  }

  static Map<String, dynamic> _mihomoToXray(Map<String, dynamic> raw) {
    final type = raw['type']?.toString().toLowerCase();
    final tag = 'proxy';
    if (type == 'vless' || type == 'vmess') {
      final user = <String, dynamic>{
        'id': raw['uuid']?.toString() ?? '',
        if (type == 'vless') 'encryption': 'none',
        if (raw['flow']?.toString().isNotEmpty == true)
          'flow': raw['flow'].toString(),
        if (type == 'vmess')
          'alterId': int.tryParse(raw['alterId']?.toString() ?? '') ?? 0,
        if (type == 'vmess') 'security': raw['cipher']?.toString() ?? 'auto',
      };
      return {
        'tag': tag,
        'protocol': type,
        'settings': {
          'vnext': [
            {
              'address': raw['server'],
              'port': raw['port'],
              'users': [user],
            },
          ],
        },
        'streamSettings': _xrayStream(raw),
      };
    }
    if (type == 'trojan') {
      return {
        'tag': tag,
        'protocol': 'trojan',
        'settings': {
          'servers': [
            {
              'address': raw['server'],
              'port': raw['port'],
              'password': raw['password'],
            },
          ],
        },
        'streamSettings': _xrayStream(raw),
      };
    }
    if (type == 'shadowsocks' || type == 'ss') {
      return {
        'tag': tag,
        'protocol': 'shadowsocks',
        'settings': {
          'servers': [
            {
              'address': raw['server'],
              'port': raw['port'],
              'method': raw['cipher'],
              'password': raw['password'],
            },
          ],
        },
      };
    }
    throw StateError('The selected node is not compatible with Xray.');
  }

  static Map<String, dynamic> _xrayStream(Map<String, dynamic> raw) {
    final network = raw['network']?.toString().toLowerCase() ?? 'tcp';
    final reality = raw['reality-opts'];
    final tlsEnabled = raw['tls'] == true || reality is Map;
    final stream = <String, dynamic>{
      'network': network,
      'security': reality is Map ? 'reality' : (tlsEnabled ? 'tls' : 'none'),
    };
    if (reality is Map) {
      stream['realitySettings'] = {
        'serverName': raw['servername'] ?? raw['sni'] ?? '',
        'fingerprint': raw['client-fingerprint'] ?? 'chrome',
        'publicKey': reality['public-key'] ?? reality['publicKey'] ?? '',
        'shortId': reality['short-id'] ?? reality['shortId'] ?? '',
      };
    } else if (tlsEnabled) {
      stream['tlsSettings'] = {
        'serverName': raw['servername'] ?? raw['sni'] ?? '',
        'allowInsecure': raw['skip-cert-verify'] == true,
        if (raw['client-fingerprint'] != null)
          'fingerprint': raw['client-fingerprint'],
      };
    }
    if (network == 'ws' && raw['ws-opts'] is Map) {
      final options = (raw['ws-opts'] as Map).cast<String, dynamic>();
      stream['wsSettings'] = {
        'path': options['path'] ?? '/',
        if (options['headers'] is Map) 'headers': options['headers'],
      };
    }
    if (network == 'grpc' && raw['grpc-opts'] is Map) {
      final options = (raw['grpc-opts'] as Map).cast<String, dynamic>();
      stream['grpcSettings'] = {
        'serviceName': options['grpc-service-name'] ?? '',
        if (options['grpc-authority'] != null)
          'authority': options['grpc-authority'],
      };
    }
    if (network == 'xhttp' && raw['xhttp-opts'] is Map) {
      stream['xhttpSettings'] = raw['xhttp-opts'];
    }
    return stream;
  }

  static String _buildSingBox(
    TunSettings settings,
    Profile profile, {
    bool desktopNativeTun = false,
    bool windowsTransport = false,
  }) {
    final node = _selected(profile);
    final native = node.raw['nozelt-native-config'];
    if (node.raw['nozelt-native-core'] == VpnCore.singBox.wireName &&
        native is Map) {
      final document = _deepMap(native);
      excludeFromSingBoxUrlTests(document, profile.autoExclusion);
      document['inbounds'] = [
        _singBoxTun(settings, desktopNativeTun: desktopNativeTun),
      ];
      final route = document['route'];
      if (route is Map) {
        route['auto_detect_interface'] = desktopNativeTun;
      }
      if (!windowsTransport) {
        _applyNativeSingBoxRules(
          settings,
          document,
          desktopNativeTun: desktopNativeTun,
        );
      }
      return jsonEncode(document);
    }
    final dns = _singBoxDNS(settings);
    final outbounds = <Map<String, dynamic>>[
      _mihomoToSingBox(node.raw),
      {'type': 'direct', 'tag': 'direct'},
    ];
    if (!windowsTransport) {
      // Destination names are resolved through the proxy, as in Mihomo. The
      // proxy's own server name uses a direct encrypted bootstrap resolver,
      // because it cannot be resolved through the tunnel it is building.
      final servers = (dns['servers'] as List).cast<Map<String, dynamic>>();
      final bootstrap = [
        for (var i = 0; i < servers.length; i++)
          {...servers[i], 'tag': 'bootstrap-$i'},
      ];
      for (final server in servers) {
        server['detour'] = 'proxy';
      }
      servers.addAll(bootstrap);
      outbounds[0]['domain_resolver'] = 'bootstrap-0';
      outbounds[1]['domain_resolver'] = 'dns-0';
    }
    return jsonEncode({
      'log': {'level': 'warn', 'timestamp': false},
      'dns': dns,
      'inbounds': [_singBoxTun(settings, desktopNativeTun: desktopNativeTun)],
      'outbounds': outbounds,
      'route': {
        'rules': _singBoxRules(
          settings,
          desktopNativeTun: desktopNativeTun,
          windowsTransport: windowsTransport,
        ),
        'rule_set': _singBoxRuleSets(settings),
        'final': 'proxy',
        if (!windowsTransport) 'default_domain_resolver': 'dns-0',
        'auto_detect_interface': desktopNativeTun,
      },
    });
  }

  static Map<String, dynamic> _singBoxTun(
    TunSettings settings, {
    bool desktopNativeTun = false,
  }) => {
    'type': 'tun',
    'tag': 'nozelt-tun',
    'interface_name': desktopNativeTun ? 'Nozelt-sing-box' : 'tun0',
    'address': [
      '${ConfigBuilder.tunIpv4Address}/${ConfigBuilder.tunIpv4Prefix}',
      if (settings.ipv6)
        '${ConfigBuilder.tunIpv6Address}/${ConfigBuilder.tunIpv6Prefix}',
    ],
    'mtu': settings.mtu,
    'auto_route': desktopNativeTun,
    'strict_route': desktopNativeTun,
    'stack': settings.stack.yamlValue,
    // sing-box 1.13+ refuses the legacy inbound `sniff` field; sniffing is
    // a route action now (see _singBoxRules / _applyNativeSingBoxRules).
  };

  static Map<String, dynamic> _singBoxDNS(TunSettings settings) {
    final servers = <Map<String, dynamic>>[];
    for (var index = 0; index < settings.nameservers.length; index++) {
      final uri = Uri.parse(settings.nameservers[index]);
      servers.add({
        'type': switch (uri.scheme) {
          'https' => 'https',
          'tls' => 'tls',
          'quic' => 'quic',
          _ => 'https',
        },
        'tag': 'dns-$index',
        'server': uri.host,
        if (uri.hasPort) 'server_port': uri.port,
        if (uri.scheme == 'https') 'path': uri.path,
        'tls': {'enabled': true, 'server_name': uri.host},
      });
    }
    return {
      'servers': servers,
      'final': 'dns-0',
      'strategy': settings.ipv6 ? 'prefer_ipv4' : 'ipv4_only',
    };
  }

  static List<Map<String, dynamic>> _singBoxRules(
    TunSettings settings, {
    required bool desktopNativeTun,
    bool windowsTransport = false,
  }) {
    final rules = <Map<String, dynamic>>[
      // Sniffing recognizes DNS packets for hijack-dns and recovers names
      // for domain rules. Unlike the old inbound flag it never rewrites the
      // destination address.
      {'action': 'sniff'},
      {'protocol': 'dns', 'action': 'hijack-dns'},
    ];
    if (settings.routingMode == RoutingMode.rule) {
      for (final rule in settings.customRules.where((rule) => rule.enabled)) {
        final rendered = <String, dynamic>{};
        switch (rule.type) {
          case RoutingRuleType.geoIp:
            rendered['rule_set'] = ['nozelt-geoip-${rule.normalizedValue}'];
            break;
          case RoutingRuleType.geoSite:
            rendered['rule_set'] = ['nozelt-geosite-${rule.normalizedValue}'];
            break;
          case RoutingRuleType.domain:
            rendered['domain'] = [rule.normalizedValue];
            break;
          case RoutingRuleType.domainSuffix:
            rendered['domain_suffix'] = [rule.normalizedValue];
            break;
          case RoutingRuleType.domainKeyword:
            rendered['domain_keyword'] = [rule.normalizedValue];
            break;
          case RoutingRuleType.processName:
            if (!desktopNativeTun) continue;
            rendered['process_name'] = [rule.normalizedValue];
            break;
          case RoutingRuleType.ipCidr:
            rendered['ip_cidr'] = [rule.normalizedValue];
            break;
        }
        if (rule.action == RoutingRuleAction.reject) {
          rendered['action'] = 'reject';
        } else {
          rendered['action'] = 'route';
          rendered['outbound'] = rule.action == RoutingRuleAction.direct
              ? 'direct'
              : 'proxy';
        }
        rules.add(rendered);
      }
    }
    if (!windowsTransport) {
      rules.addAll(_singBoxLocalRules(settings, directTag: 'direct'));
    }
    return rules;
  }

  /// Same local-address policy as Mihomo, in rule and global mode alike.
  static List<Map<String, dynamic>> _singBoxLocalRules(
    TunSettings settings, {
    required String directTag,
  }) => [
    {
      'ip_cidr': ['127.0.0.0/8', '::1/128'],
      'action': 'route',
      'outbound': directTag,
    },
    {
      'ip_cidr': ConfigBuilder.localRanges
          .where((range) => range != '127.0.0.0/8' && range != '::1/128')
          .toList(growable: false),
      if (settings.allowLan) ...{
        'action': 'route',
        'outbound': directTag,
      } else
        'action': 'reject',
    },
  ];

  static List<Map<String, dynamic>> _singBoxRuleSets(TunSettings settings) {
    final seen = <String>{};
    final result = <Map<String, dynamic>>[];
    for (final rule in settings.customRules.where((rule) => rule.enabled)) {
      final source = switch (rule.type) {
        RoutingRuleType.geoIp => (
          'geoip',
          'https://raw.githubusercontent.com/SagerNet/sing-geoip/rule-set/geoip-${rule.normalizedValue}.srs',
        ),
        RoutingRuleType.geoSite => (
          'geosite',
          'https://raw.githubusercontent.com/SagerNet/sing-geosite/rule-set/geosite-${rule.normalizedValue}.srs',
        ),
        _ => null,
      };
      if (source == null) continue;
      final tag = 'nozelt-${source.$1}-${rule.normalizedValue}';
      if (!seen.add(tag)) continue;
      result.add({
        'type': 'remote',
        'tag': tag,
        'format': 'binary',
        'url': source.$2,
        if (settings.geoUpdateIntervalHours > 0)
          'update_interval': '${settings.geoUpdateIntervalHours}h',
      });
    }
    return result;
  }

  static void _applyNativeSingBoxRules(
    TunSettings settings,
    Map<String, dynamic> document, {
    required bool desktopNativeTun,
  }) {
    final enabledRules = settings.routingMode == RoutingMode.rule
        ? settings.customRules.where((rule) => rule.enabled)
        : const <RoutingRule>[];

    final outbounds = switch (document['outbounds']) {
      final List value => value,
      _ => <dynamic>[],
    };
    document['outbounds'] = outbounds;
    var directTag = '';
    for (final raw in outbounds) {
      if (raw is Map && raw['type']?.toString().toLowerCase() == 'direct') {
        directTag = raw['tag']?.toString().trim() ?? '';
        if (directTag.isNotEmpty) break;
      }
    }
    if (directTag.isEmpty) {
      final used = outbounds
          .whereType<Map>()
          .map((outbound) => outbound['tag']?.toString().trim() ?? '')
          .where((tag) => tag.isNotEmpty)
          .toSet();
      directTag = 'nozelt-direct';
      var suffix = 2;
      while (used.contains(directTag)) {
        directTag = 'nozelt-direct-$suffix';
        suffix += 1;
      }
      outbounds.add({'type': 'direct', 'tag': directTag});
    }

    final route = switch (document['route']) {
      final Map value => value.cast<String, dynamic>(),
      _ => <String, dynamic>{},
    };
    document['route'] = route;
    final nativeRuleSets = switch (route['rule_set']) {
      final List value => value,
      _ => <dynamic>[],
    };
    route['rule_set'] = nativeRuleSets;
    final existingRuleSetTags = nativeRuleSets
        .whereType<Map>()
        .map((value) => value['tag']?.toString() ?? '')
        .toSet();
    for (final ruleSet in _singBoxRuleSets(settings)) {
      if (existingRuleSetTags.add(ruleSet['tag']!.toString())) {
        nativeRuleSets.add(ruleSet);
      }
    }
    final rules = switch (route['rules']) {
      final List value => value,
      _ => <dynamic>[],
    };
    route['rules'] = rules;
    var proxyTag = route['final']?.toString().trim() ?? '';
    if (proxyTag.isEmpty) {
      for (final raw in outbounds) {
        if (raw is! Map) continue;
        final type = raw['type']?.toString().toLowerCase() ?? '';
        final tag = raw['tag']?.toString().trim() ?? '';
        if (tag.isNotEmpty &&
            tag != directTag &&
            !{'direct', 'block', 'dns'}.contains(type)) {
          proxyTag = tag;
          break;
        }
      }
    }

    final injected = <Map<String, dynamic>>[];
    for (final rule in enabledRules) {
      final rendered = <String, dynamic>{};
      switch (rule.type) {
        case RoutingRuleType.geoIp:
          rendered['rule_set'] = ['nozelt-geoip-${rule.normalizedValue}'];
          break;
        case RoutingRuleType.geoSite:
          rendered['rule_set'] = ['nozelt-geosite-${rule.normalizedValue}'];
          break;
        case RoutingRuleType.domain:
          rendered['domain'] = [rule.normalizedValue];
          break;
        case RoutingRuleType.domainSuffix:
          rendered['domain_suffix'] = [rule.normalizedValue];
          break;
        case RoutingRuleType.domainKeyword:
          rendered['domain_keyword'] = [rule.normalizedValue];
          break;
        case RoutingRuleType.ipCidr:
          rendered['ip_cidr'] = [rule.normalizedValue];
          break;
        case RoutingRuleType.processName:
          if (!desktopNativeTun) continue;
          rendered['process_name'] = [rule.normalizedValue];
          break;
      }
      if (rule.action == RoutingRuleAction.reject) {
        rendered['action'] = 'reject';
      } else {
        final outbound = rule.action == RoutingRuleAction.direct
            ? directTag
            : proxyTag;
        if (outbound.isEmpty) continue;
        rendered['action'] = 'route';
        rendered['outbound'] = outbound;
      }
      injected.add(rendered);
    }
    injected.addAll(_singBoxLocalRules(settings, directTag: directTag));

    // Our inbound replaced the provider's, so its legacy inbound sniffing is
    // gone. Without a sniff action neither DNS hijack nor domain rules work.
    final hasSniff = rules.whereType<Map>().any(
      (rule) => rule['action'] == 'sniff' && !rule.keys.any(_isMatcherKey),
    );
    if (!hasSniff) rules.insert(0, <String, dynamic>{'action': 'sniff'});

    // User rules go after the leading sniff/DNS rules so that names are
    // already known when they are matched.
    var insertionIndex = 0;
    while (insertionIndex < rules.length) {
      final raw = rules[insertionIndex];
      if (raw is Map &&
          (raw['action'] == 'sniff' ||
              raw['action'] == 'hijack-dns' ||
              raw['protocol'] == 'dns')) {
        insertionIndex += 1;
        continue;
      }
      break;
    }
    rules.insertAll(insertionIndex, injected);
  }

  static bool _isMatcherKey(Object? key) =>
      !const {'action', 'sniffer', 'timeout'}.contains(key);

  static Map<String, dynamic> _mihomoToSingBox(Map<String, dynamic> raw) {
    final type = raw['type']?.toString().toLowerCase();
    final common = <String, dynamic>{
      'tag': 'proxy',
      'server': raw['server'],
      'server_port': raw['port'],
    };
    switch (type) {
      case 'vless':
        return {
          ...common,
          'type': 'vless',
          'uuid': raw['uuid'],
          if (raw['flow'] != null) 'flow': raw['flow'],
          'tls': _singBoxTLS(raw),
          'transport': ?_singBoxTransport(raw),
        };
      case 'vmess':
        return {
          ...common,
          'type': 'vmess',
          'uuid': raw['uuid'],
          'security': raw['cipher'] ?? 'auto',
          'alter_id': int.tryParse(raw['alterId']?.toString() ?? '') ?? 0,
          'tls': _singBoxTLS(raw),
          'transport': ?_singBoxTransport(raw),
        };
      case 'trojan':
        return {
          ...common,
          'type': 'trojan',
          'password': raw['password'],
          'tls': _singBoxTLS(raw),
          'transport': ?_singBoxTransport(raw),
        };
      case 'hysteria2':
      case 'hy2':
        final obfs = raw['obfs'];
        return {
          ...common,
          'type': 'hysteria2',
          'password': raw['password'],
          if (obfs != null) 'obfs': {'type': 'salamander', 'password': obfs},
          'tls': _singBoxTLS(raw, force: true),
        };
      case 'shadowsocks':
      case 'ss':
        return {
          ...common,
          'type': 'shadowsocks',
          'method': raw['cipher'],
          'password': raw['password'],
        };
      case 'tuic':
        return {
          ...common,
          'type': 'tuic',
          'uuid': raw['uuid'],
          'password': raw['password'],
          'congestion_control': raw['congestion-controller'] ?? 'cubic',
          'udp_relay_mode': raw['udp-relay-mode'] ?? 'native',
          'tls': _singBoxTLS(raw, force: true),
        };
      case 'anytls':
        return {
          ...common,
          'type': 'anytls',
          'password': raw['password'],
          'tls': _singBoxTLS(raw, force: true),
        };
      default:
        throw StateError('The selected node is not compatible with sing-box.');
    }
  }

  static Map<String, dynamic> _singBoxTLS(
    Map<String, dynamic> raw, {
    bool force = false,
  }) {
    final reality = raw['reality-opts'];
    final enabled = force || raw['tls'] == true || reality is Map;
    return {
      'enabled': enabled,
      if (enabled)
        'server_name': raw['servername'] ?? raw['sni'] ?? raw['server'],
      if (enabled) 'insecure': raw['skip-cert-verify'] == true,
      if (enabled && raw['client-fingerprint'] != null)
        'utls': {'enabled': true, 'fingerprint': raw['client-fingerprint']},
      if (reality is Map)
        'reality': {
          'enabled': true,
          'public_key': reality['public-key'] ?? reality['publicKey'],
          'short_id': reality['short-id'] ?? reality['shortId'],
        },
    };
  }

  static Map<String, dynamic>? _singBoxTransport(Map<String, dynamic> raw) {
    final network = raw['network']?.toString().toLowerCase();
    if (network == null || network == 'tcp') return null;
    if (network == 'ws') {
      final options = raw['ws-opts'] is Map
          ? (raw['ws-opts'] as Map).cast<String, dynamic>()
          : const <String, dynamic>{};
      return {
        'type': 'ws',
        'path': options['path'] ?? '/',
        if (options['headers'] is Map) 'headers': options['headers'],
      };
    }
    if (network == 'grpc') {
      final options = raw['grpc-opts'] is Map
          ? (raw['grpc-opts'] as Map).cast<String, dynamic>()
          : const <String, dynamic>{};
      return {
        'type': 'grpc',
        'service_name': options['grpc-service-name'] ?? '',
      };
    }
    if (network == 'http' || network == 'h2') {
      return {'type': 'http'};
    }
    if (network == 'httpupgrade') {
      return {'type': 'httpupgrade'};
    }
    throw StateError('Unsupported sing-box transport: $network');
  }

  static Map<String, dynamic> _deepMap(Map source) =>
      (jsonDecode(jsonEncode(source)) as Map).cast<String, dynamic>();
}
