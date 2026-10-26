import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/models.dart';
import '../core/profile.dart';
import '../core/vpn_core.dart';
import 'engine_provider.dart';
import 'node_health_provider.dart';
import 'profiles_provider.dart';

/// Nozelt's own automatic server, independent of any core's built-in groups.
///
/// While "Авто (Nozelt)" is selected and the VPN is connected, it measures
/// every server of the profile with the same delay test as the ping button,
/// then moves the connection to the fastest one. It works the same for Mihomo,
/// Xray and sing-box because the core only ever sees one ordinary server.
/// The state is true while a measurement is running.
class NozeltAutoServer extends Notifier<bool> {
  Timer? _timer;

  /// Re-checks on a phone less often: every check wakes the radio for all
  /// servers.
  static Duration get interval =>
      defaultTargetPlatform == TargetPlatform.android
      ? const Duration(minutes: 10)
      : const Duration(minutes: 5);

  @override
  bool build() {
    ref.listen<EngineConnectionState>(
      engineStateProvider.select((value) => value.connection),
      (previous, next) =>
          _reschedule(evaluateNow: next == EngineConnectionState.connected),
    );
    ref.listen<String?>(
      profilesProvider.select((value) => _signature(value.value?.active)),
      (previous, next) => _reschedule(evaluateNow: previous != next),
    );
    ref.onDispose(() => _timer?.cancel());
    Future.microtask(() {
      if (ref.mounted) _reschedule(evaluateNow: true);
    });
    return false;
  }

  /// Turning the auto server on, a refreshed server list or another core
  /// starts a new measurement; latency and selection metadata do not.
  static String? _signature(Profile? profile) =>
      profile == null || !profile.autoSelected
      ? null
      : '${profile.id}:${profile.topologyRevision}:${profile.effectiveCore.wireName}';

  Profile? get _activeAutoProfile {
    if (ref.read(engineStateProvider).connection !=
        EngineConnectionState.connected) {
      return null;
    }
    final profile = ref.read(profilesProvider).value?.active;
    return profile != null && profile.autoSelected ? profile : null;
  }

  void _reschedule({bool evaluateNow = false}) {
    if (!ref.mounted) return;
    _timer?.cancel();
    _timer = null;
    if (_activeAutoProfile == null) return;
    if (evaluateNow) unawaited(evaluate());
    _timer = Timer.periodic(interval, (_) => unawaited(evaluate()));
  }

  /// Measures every server now and switches if a clearly faster one exists.
  Future<void> evaluate() async {
    if (state) return;
    final profile = _activeAutoProfile;
    if (profile == null) return;
    state = true;
    try {
      await ref.read(nodeHealthProvider.notifier).pingAll(profile);
      if (!ref.mounted) return;
      final latest = _activeAutoProfile;
      if (latest == null || latest.id != profile.id) return;
      final health = ref.read(nodeHealthProvider);
      final pick = choose(
        latest,
        (name) => health.delay(latest.id, name)?.milliseconds,
      );
      if (pick != null) {
        await ref.read(profilesProvider.notifier).setAutoPick(latest.id, pick);
      }
    } catch (_) {
      // A failed check keeps the current server; the next interval retries.
    } finally {
      if (ref.mounted) state = false;
    }
  }

  /// Picks the server to move to, or null to stay. A server that stopped
  /// answering is always replaced. Otherwise the move must be clearly worth
  /// it: Mihomo switches without reconnecting, Xray and sing-box restart, so
  /// they need a bigger gain before dropping open connections.
  static String? choose(Profile profile, int? Function(String name) delayOf) {
    String? bestName;
    int? best;
    // Deleted servers stay selectable by hand but never by the auto server.
    for (final node in profile.autoCandidates) {
      final delay = delayOf(node.name);
      if (delay == null || delay <= 0) continue;
      if (best == null || delay < best) {
        best = delay;
        bestName = node.name;
      }
    }
    if (bestName == null || best == null) return null;
    final current = profile.autoPick;
    if (current == null || current.name == bestName) {
      return current == null ? bestName : null;
    }
    final currentDelay = delayOf(current.name);
    if (currentDelay == null || currentDelay <= 0) return bestName;
    final instant = profile.effectiveCore == VpnCore.mihomo;
    final ratio = instant ? 0.75 : 0.6;
    final minimumGain = instant ? 40 : 80;
    return best <= currentDelay * ratio && currentDelay - best >= minimumGain
        ? bestName
        : null;
  }
}

final nozeltAutoServerProvider = NotifierProvider<NozeltAutoServer, bool>(
  NozeltAutoServer.new,
);
