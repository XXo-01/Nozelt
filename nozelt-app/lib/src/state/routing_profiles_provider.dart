import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/routing_profile.dart';
import '../core/split_tunnel_settings.dart';
import '../core/tun_settings.dart';
import 'settings_provider.dart';

class RoutingProfilesNotifier extends Notifier<RoutingProfilesState> {
  Future<void> _persistTail = Future<void>.value();

  @override
  RoutingProfilesState build() =>
      ref.watch(sensitiveSettingsRepositoryProvider).routingProfiles;

  Future<void> updatePersisted(RoutingProfilesState next) async {
    final error = next.validate();
    if (error != null) throw ArgumentError(error);
    final previous = state;
    state = next;
    _syncTunMirror(next.active);
    final repository = ref.read(sensitiveSettingsRepositoryProvider);
    final operation = _persistTail.then(
      (_) => repository.saveRoutingProfiles(next),
    );
    _persistTail = operation.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    try {
      await operation;
    } catch (_) {
      if (ref.mounted && identical(state, next)) {
        state = previous;
        _syncTunMirror(previous.active);
      }
      rethrow;
    }
  }

  Future<void> updateActivePersisted(
    RoutingProfile Function(RoutingProfile current) transform,
  ) => updatePersisted(state.replace(transform(state.active)));

  /// Mirrors split-picker edits in the active profile. Persistence remains
  /// owned by SplitTunnelNotifier so one encrypted snapshot commits both the
  /// compatibility mirror and the profile value atomically.
  void syncActiveSplit(SplitTunnelSettings split) {
    state = state.replace(state.active.copyWith(split: split));
  }

  void _syncTunMirror(RoutingProfile profile) {
    ref
        .read(tunSettingsProvider.notifier)
        .syncRoutingMirror(
          mode: profile.routingMode,
          rules: profile.orderedRules,
          geoUpdateIntervalHours: profile.settings.geoUpdateIntervalHours,
        );
  }
}

final routingProfilesProvider =
    NotifierProvider<RoutingProfilesNotifier, RoutingProfilesState>(
      RoutingProfilesNotifier.new,
    );

/// The engine consumes global network/privacy settings combined with the
/// active routing profile's mode and explicitly ordered rules.
final effectiveTunSettingsProvider = Provider<TunSettings>((ref) {
  final tun = ref.watch(tunSettingsProvider);
  final profile = ref.watch(routingProfilesProvider).active;
  return tun.copyWith(
    routingMode: profile.routingMode,
    customRules: profile.orderedRules,
    geoUpdateIntervalHours: profile.settings.geoUpdateIntervalHours,
  );
});
