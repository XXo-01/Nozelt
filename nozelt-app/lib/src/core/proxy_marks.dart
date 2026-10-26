import 'package:flutter/foundation.dart' show setEquals;

import 'proxy_node.dart';

/// Carries a per-profile set of server names (pinned or deleted) across a
/// subscription refresh. A name that is still present keeps its mark. A
/// server the provider renamed keeps it too when exactly one new server has
/// the same type, address and port. Servers that left the subscription lose
/// their marks, so a returning server starts fresh.
Set<String> carryNodeMarks(
  Set<String> marks,
  List<ProxyNode> previous,
  List<ProxyNode> refreshed,
) {
  if (marks.isEmpty) return const {};
  final refreshedNames = {for (final node in refreshed) node.name};
  final previousByName = {for (final node in previous) node.name: node};
  final result = <String>{};
  for (final name in marks) {
    if (refreshedNames.contains(name)) {
      result.add(name);
      continue;
    }
    final old = previousByName[name];
    if (old == null) continue;
    final renamed = refreshed
        .where(
          (node) =>
              !previousByName.containsKey(node.name) &&
              node.server == old.server &&
              node.port == old.port &&
              node.type.toLowerCase() == old.type.toLowerCase(),
        )
        .take(2)
        .toList(growable: false);
    if (renamed.length == 1) result.add(renamed.single.name);
  }
  return result;
}

/// Servers that automatic selection must skip: Nozelt's auto server, the
/// provider's url-test/fallback/load-balance groups (Mihomo), Xray balancers
/// and sing-box urltest outbounds. Manual selection is never affected.
///
/// Group members are matched by [names] when a group lists profile servers
/// by name, and by [endpoints] when a group carries its own copies of the
/// servers (Happ AUTO entries, native Xray and sing-box documents).
class AutoExclusion {
  const AutoExclusion({this.names = const {}, this.endpoints = const {}});

  static const none = AutoExclusion();

  final Set<String> names;

  /// `host:port` keys, host lower-cased.
  final Set<String> endpoints;

  bool get isEmpty => names.isEmpty && endpoints.isEmpty;

  /// Deleted servers of a profile. When nothing else is left, nothing is
  /// excluded: automatic selection then works with the full list rather than
  /// with an empty group (an empty Mihomo group would fall back to DIRECT).
  factory AutoExclusion.forNodes(List<ProxyNode> nodes, Set<String> deleted) {
    if (deleted.isEmpty) return none;
    final removed = <ProxyNode>[];
    final kept = <ProxyNode>[];
    for (final node in nodes) {
      (deleted.contains(node.name) ? removed : kept).add(node);
    }
    if (removed.isEmpty || kept.isEmpty) return none;
    // A server address shared with a kept server stays usable.
    final keptEndpoints = {
      for (final node in kept)
        if (!node.isAutomaticGroup) endpointKey(node.server, node.port),
    };
    return AutoExclusion(
      names: {for (final node in removed) node.name},
      endpoints: {
        for (final node in removed)
          if (!node.isAutomaticGroup &&
              !keptEndpoints.contains(endpointKey(node.server, node.port)))
            endpointKey(node.server, node.port),
      },
    );
  }

  static String endpointKey(Object? host, Object? port) {
    var value = (host ?? '').toString().trim().toLowerCase();
    if (value.startsWith('[') && value.endsWith(']')) {
      value = value.substring(1, value.length - 1);
    }
    return '$value:${int.tryParse((port ?? '').toString().trim()) ?? 0}';
  }

  bool excludesEndpoint(Object? host, Object? port) =>
      endpoints.isNotEmpty && endpoints.contains(endpointKey(host, port));

  /// Removes excluded members, but never empties a group.
  static List<T> keepNonEmpty<T>(List<T> members, bool Function(T) excluded) {
    final kept = members.where((member) => !excluded(member)).toList();
    return kept.isEmpty ? members : kept;
  }

  @override
  bool operator ==(Object other) =>
      other is AutoExclusion &&
      setEquals(other.names, names) &&
      setEquals(other.endpoints, endpoints);

  @override
  int get hashCode => Object.hash(
    Object.hashAllUnordered(names),
    Object.hashAllUnordered(endpoints),
  );
}
