import 'dart:convert';
import 'dart:isolate';

import 'profile.dart';
import 'routing_profile.dart';
import 'split_tunnel_settings.dart';
import 'tun_settings.dart';

/// Encrypted by the Android host and consumed only if native failover restores
/// the matching last-known-good VPN generation after Flutter disappears.
class RuntimeRollbackSnapshot {
  const RuntimeRollbackSnapshot({required this.kind, required this.payload});

  final String kind;
  final String payload;

  factory RuntimeRollbackSnapshot.tun(TunSettings value) =>
      RuntimeRollbackSnapshot(kind: 'tun', payload: value.encode());

  factory RuntimeRollbackSnapshot.split(SplitTunnelSettings value) =>
      RuntimeRollbackSnapshot(kind: 'split', payload: value.encode());

  factory RuntimeRollbackSnapshot.routingProfiles(RoutingProfilesState value) =>
      RuntimeRollbackSnapshot(kind: 'routingProfiles', payload: value.encode());

  static Future<RuntimeRollbackSnapshot> profiles(ProfilesState value) async {
    final payload = await Isolate.run(() => jsonEncode(value.toJson()));
    return RuntimeRollbackSnapshot(kind: 'profiles', payload: payload);
  }
}
