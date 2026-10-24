import 'dart:async';
import 'dart:convert';

import '../core/split_tunnel_settings.dart';
import '../core/tun_settings.dart';
import '../core/routing_profile.dart';
import 'app_preferences.dart';

const legacyTunSettingsKey = 'tun_settings_v1';
const legacySplitTunnelKey = 'split_tunnel_v1';
const legacyRoutingProfilesKey = 'routing_profiles_v1';

typedef SensitiveSettingsWriter = Future<void> Function(String encoded);

class SensitiveSettingsStoreException implements Exception {
  const SensitiveSettingsStoreException();

  @override
  String toString() => 'SensitiveSettingsStoreException';
}

/// Complete encrypted-at-rest snapshot of settings that can reveal domains,
/// installed applications, DNS policy, or routing intent.
class SensitiveSettingsSnapshot {
  const SensitiveSettingsSnapshot({
    required this.tun,
    required this.split,
    RoutingProfilesState? routingProfiles,
  }) : _routingProfiles = routingProfiles;

  final TunSettings tun;
  final SplitTunnelSettings split;
  final RoutingProfilesState? _routingProfiles;

  RoutingProfilesState get routingProfiles =>
      _routingProfiles ?? RoutingProfilesState.fromLegacy(tun, split);

  String encode() => jsonEncode({
    'version': 2,
    'tun': tun.encode(),
    'split': split.encode(),
    'routingProfiles': routingProfiles.encode(),
  });

  static SensitiveSettingsSnapshot decode(String encoded) {
    final root = jsonDecode(encoded);
    if (root is! Map<String, dynamic> ||
        (root['version'] != 1 && root['version'] != 2)) {
      throw const FormatException('Unsupported sensitive settings format.');
    }
    final tun = root['tun'];
    final split = root['split'];
    if (tun is! String || split is! String) {
      throw const FormatException('Incomplete sensitive settings snapshot.');
    }
    final routingProfiles = root['routingProfiles'];
    return SensitiveSettingsSnapshot(
      tun: TunSettings.decode(tun),
      split: SplitTunnelSettings.decode(split),
      routingProfiles: routingProfiles is String
          ? RoutingProfilesState.decode(routingProfiles)
          : null,
    );
  }

  static SensitiveSettingsSnapshot fromLegacy(SharedPreferences preferences) {
    TunSettings tun = const TunSettings();
    SplitTunnelSettings split = const SplitTunnelSettings();
    try {
      final value = preferences.getString(legacyTunSettingsKey);
      if (value != null) tun = TunSettings.decode(value);
    } catch (_) {
      // Corrupt legacy data is intentionally not copied into secure storage.
    }
    try {
      final value = preferences.getString(legacySplitTunnelKey);
      if (value != null) split = SplitTunnelSettings.decode(value);
    } catch (_) {
      // Corrupt legacy data is intentionally not copied into secure storage.
    }
    RoutingProfilesState? routingProfiles;
    try {
      final value = preferences.getString(legacyRoutingProfilesKey);
      if (value != null) routingProfiles = RoutingProfilesState.decode(value);
    } catch (_) {
      // Corrupt legacy routing profiles fall back to migrated global policy.
    }
    return SensitiveSettingsSnapshot(
      tun: tun,
      split: split,
      routingProfiles: routingProfiles,
    );
  }
}

/// Process-wide serialized coordinator. Both providers write one complete
/// snapshot so concurrent TUN and per-app edits cannot overwrite each other.
class SensitiveSettingsRepository {
  SensitiveSettingsRepository({
    required SensitiveSettingsSnapshot initial,
    required SensitiveSettingsWriter writer,
  }) : _snapshot = initial,
       _writer = writer;

  factory SensitiveSettingsRepository.legacy(SharedPreferences preferences) {
    return SensitiveSettingsRepository(
      initial: SensitiveSettingsSnapshot.fromLegacy(preferences),
      writer: (encoded) async {
        final snapshot = SensitiveSettingsSnapshot.decode(encoded);
        final results = await Future.wait([
          preferences.setString(legacyTunSettingsKey, snapshot.tun.encode()),
          preferences.setString(legacySplitTunnelKey, snapshot.split.encode()),
          preferences.setString(
            legacyRoutingProfilesKey,
            snapshot.routingProfiles.encode(),
          ),
        ]);
        if (results.any((saved) => !saved)) {
          throw StateError('Could not persist sensitive settings.');
        }
      },
    );
  }

  SensitiveSettingsSnapshot _snapshot;
  final SensitiveSettingsWriter _writer;
  Future<void> _tail = Future<void>.value();

  TunSettings get tun => _snapshot.tun;
  SplitTunnelSettings get split => _snapshot.split;
  RoutingProfilesState get routingProfiles => _snapshot.routingProfiles;
  String get encoded => _snapshot.encode();

  Future<void> saveTun(TunSettings value) => _enqueue(
    (committed) => SensitiveSettingsSnapshot(
      tun: value,
      split: committed.split,
      routingProfiles: committed.routingProfiles,
    ),
  );

  Future<void> saveSplit(SplitTunnelSettings value) => _enqueue((committed) {
    final routing = committed.routingProfiles;
    final active = routing.active.copyWith(split: value);
    return SensitiveSettingsSnapshot(
      tun: committed.tun,
      split: value,
      routingProfiles: routing.replace(active),
    );
  });

  Future<void> saveRoutingProfiles(RoutingProfilesState value) => _enqueue(
    (committed) => SensitiveSettingsSnapshot(
      tun: committed.tun.copyWith(
        routingMode: value.active.routingMode,
        customRules: value.active.orderedRules,
        geoUpdateIntervalHours: value.active.settings.geoUpdateIntervalHours,
      ),
      split: value.active.split,
      routingProfiles: value,
    ),
  );

  Future<void> persistCurrent() => _enqueue((committed) => committed);

  Future<void> _enqueue(
    SensitiveSettingsSnapshot Function(SensitiveSettingsSnapshot committed)
    mutation,
  ) {
    // Build at execution time from the latest *successfully committed*
    // snapshot. If a TUN write fails while a split-policy write is queued (or
    // vice versa), the latter must not accidentally persist the rejected
    // optimistic value from the other provider.
    final operation = _tail.then((_) async {
      final next = mutation(_snapshot);
      await _writer(next.encode());
      _snapshot = next;
    });
    _tail = operation.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return operation;
  }
}
