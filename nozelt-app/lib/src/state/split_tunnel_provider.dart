import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/app_info.dart';
import '../core/models.dart';
import '../core/runtime_rollback.dart';
import '../core/split_tunnel_settings.dart';
import 'engine_provider.dart';
import 'routing_profiles_provider.dart';
import 'settings_provider.dart';

/// Owns the persisted [SplitTunnelSettings] (mode + selected packages). Loads
/// once from the shared sensitive-settings repository.
class SplitTunnelNotifier extends Notifier<SplitTunnelSettings> {
  Future<void> _persistTail = Future<void>.value();
  Future<void> _latestPersist = Future<void>.value();
  Timer? _applyTimer;
  int _settingsRevision = 0;
  bool _nativeApplyPending = false;
  bool _nativeApplyInFlight = false;
  late SplitTunnelSettings _durableState;
  late SplitTunnelSettings _liveState;

  @override
  SplitTunnelSettings build() {
    ref.onDispose(() => _applyTimer?.cancel());
    final initial = ref
        .watch(sensitiveSettingsRepositoryProvider)
        .routingProfiles
        .active
        .split;
    _durableState = initial;
    _liveState = initial;
    return initial;
  }

  /// Called after EngineNotifier has completed a connection/recovery turn.
  /// Keeping this as an event instead of watching engineStateProvider avoids
  /// a provider cycle: EngineNotifier must read the latest split policy while
  /// assembling the very configuration that transitions it to connected.
  void onEngineConnected(SplitTunnelSettings applied) {
    if (!ref.mounted) return;
    _liveState = applied;
    _nativeApplyPending = state != applied;
    if (_nativeApplyPending) _scheduleNativeApply();
  }

  Future<void> setMode(SplitMode mode) => _update(state.copyWith(mode: mode));

  Future<void> toggleApp(String packageName, bool selected) =>
      _update(state.toggleApp(packageName, selected));

  Future<void> _update(SplitTunnelSettings next) {
    if (next == state) return Future<void>.value();
    state = next;
    ref.read(routingProfilesProvider.notifier).syncActiveSplit(next);
    _settingsRevision++;
    final revision = _settingsRevision;
    final connection = ref.read(engineStateProvider).connection;
    // A disconnected future Start reads this latest state directly. Any
    // in-flight/live native session may already have captured older Builder
    // options and therefore needs a tracked apply after it becomes connected.
    _nativeApplyPending =
        connection != EngineConnectionState.disconnected && next != _liveState;
    _scheduleNativeApply();
    final repository = ref.read(sensitiveSettingsRepositoryProvider);
    final operation = _persistTail.then((_) => repository.saveSplit(next));
    _latestPersist = operation;
    unawaited(
      operation.then<void>(
        (_) {
          _durableState = next;
        },
        onError: (Object error, StackTrace stackTrace) async {
          if (!ref.mounted) return;
          // Do not leave the picker showing policy that neither encrypted
          // storage nor the live Android Builder accepted. Only roll back if
          // no newer user revision has superseded this failed write.
          if (_settingsRevision != revision) return;
          _settingsRevision++;
          state = _durableState;
          ref
              .read(routingProfilesProvider.notifier)
              .syncActiveSplit(_durableState);
          _nativeApplyPending =
              ref.read(engineStateProvider).connection !=
                  EngineConnectionState.disconnected &&
              state != _liveState;
          _scheduleNativeApply();
        },
      ),
    );
    _persistTail = operation.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    // UI controls intentionally keep their synchronous feel. A storage
    // failure must not become an unhandled zone exception; the in-memory
    // state remains usable for the current process.
    return _persistTail;
  }

  /// Loads the split policy that belongs to a newly activated routing
  /// profile. The routing-profile controller owns the ensuing full restart.
  void loadActiveProfile(SplitTunnelSettings next) {
    _applyTimer?.cancel();
    _settingsRevision++;
    state = next;
    _durableState = next;
    _nativeApplyPending =
        ref.read(engineStateProvider).connection !=
            EngineConnectionState.disconnected &&
        next != _liveState;
  }

  void _scheduleNativeApply() {
    if (!ref.mounted) return;
    _applyTimer?.cancel();
    if (!_nativeApplyPending || _nativeApplyInFlight) return;
    if (ref.read(engineStateProvider).connection !=
        EngineConnectionState.connected) {
      return;
    }
    // App pickers commonly emit many changes in quick succession. Coalesce
    // them into one full Builder/TUN replacement instead of restarting once
    // per checkbox.
    _applyTimer = Timer(const Duration(milliseconds: 700), () {
      if (ref.mounted) unawaited(_applyLatest());
    });
  }

  Future<void> _applyLatest() async {
    if (!ref.mounted) return;
    if (_nativeApplyInFlight || !_nativeApplyPending) return;
    _nativeApplyInFlight = true;
    int? applyingRevision;
    try {
      // Updates can arrive while an earlier encrypted write is completing.
      // Wait until the persisted revision catches the latest in-memory one;
      // the native TUN must never get ahead of durable split policy.
      while (true) {
        final waitingRevision = _settingsRevision;
        final persist = _latestPersist;
        try {
          await persist;
          if (!ref.mounted) return;
        } catch (_) {
          if (!ref.mounted) return;
          // Preserve the running TUN rather than applying policy that cannot
          // survive process/service restart. A later user edit retries.
          _nativeApplyPending =
              ref.read(engineStateProvider).connection !=
                  EngineConnectionState.disconnected &&
              state != _liveState;
          return;
        }
        if (waitingRevision == _settingsRevision) break;
      }
      if (ref.read(engineStateProvider).connection !=
          EngineConnectionState.connected) {
        return;
      }
      applyingRevision = _settingsRevision;
      final applyingState = state;
      await ref
          .read(engineStateProvider.notifier)
          .restartWithCurrentConfiguration(
            rollback: RuntimeRollbackSnapshot.split(_liveState),
          );
      if (!ref.mounted) return;
      if (ref.read(engineStateProvider).connection ==
          EngineConnectionState.connected) {
        _liveState = applyingState;
        _nativeApplyPending =
            _settingsRevision != applyingRevision || state != applyingState;
      }
    } catch (_) {
      if (!ref.mounted) return;
      // Timer callbacks are detached from the widget that initiated the edit.
      // Native recovery already moves EngineState to an error state; never let
      // the same failure escape as an uncaught zone error and destabilize the
      // Flutter process after the app has been backgrounded. Recover the last
      // known live app policy transactionally when this was still the latest
      // requested edit.
      await _recoverFailedNativeApply(applyingRevision);
    } finally {
      _nativeApplyInFlight = false;
      if (ref.mounted &&
          _nativeApplyPending &&
          ref.read(engineStateProvider).connection ==
              EngineConnectionState.connected) {
        _scheduleNativeApply();
      }
    }
  }

  Future<void> _recoverFailedNativeApply(int? failedRevision) async {
    // An edit can arrive during the up-to-16-second native replacement. If it
    // did, retry exactly that latest durable union once from EngineState.error
    // instead of rolling the user's newer choice back with the failed one.
    if (failedRevision == null || _settingsRevision != failedRevision) {
      await _retryLatestFromError();
      return;
    }

    final rollback = _liveState;
    final repository = ref.read(sensitiveSettingsRepositoryProvider);
    final operation = _persistTail.then((_) => repository.saveSplit(rollback));
    _latestPersist = operation;
    _persistTail = operation.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    try {
      await operation;
      if (!ref.mounted) return;
      _durableState = rollback;
    } catch (_) {
      // With both native apply and encrypted rollback unavailable, retain the
      // requested durable/UI policy and the keeper-backed error state. Guessing
      // a successful policy here would be less safe than remaining fail closed.
      return;
    }

    if (_settingsRevision != failedRevision) {
      await _retryLatestFromError();
      return;
    }

    _settingsRevision++;
    state = rollback;
    ref.read(routingProfilesProvider.notifier).syncActiveSplit(rollback);
    _nativeApplyPending = false;
    try {
      await ref
          .read(engineStateProvider.notifier)
          .restartWithCurrentConfiguration(allowErrorRecovery: true);
      if (!ref.mounted) return;
      if (ref.read(engineStateProvider).connection ==
          EngineConnectionState.connected) {
        _liveState = rollback;
      }
    } catch (_) {
      // EngineNotifier exposes the failed rollback and retains the TUN keeper.
    }
  }

  Future<void> _retryLatestFromError() async {
    while (true) {
      final revision = _settingsRevision;
      final persist = _latestPersist;
      try {
        await persist;
        if (!ref.mounted) return;
      } catch (_) {
        return;
      }
      if (revision != _settingsRevision) continue;
      final desired = state;
      try {
        await ref
            .read(engineStateProvider.notifier)
            .restartWithCurrentConfiguration(allowErrorRecovery: true);
        if (!ref.mounted) return;
        if (ref.read(engineStateProvider).connection ==
            EngineConnectionState.connected) {
          _liveState = desired;
          _nativeApplyPending =
              revision != _settingsRevision || state != desired;
        }
      } catch (_) {
        // One bounded recovery attempt is enough; further automatic retries
        // could loop forever on an OEM Builder error. A later user edit or
        // foreground/native recovery remains a meaningful retry trigger.
      }
      return;
    }
  }
}

final splitTunnelProvider =
    NotifierProvider<SplitTunnelNotifier, SplitTunnelSettings>(
      SplitTunnelNotifier.new,
    );

/// One-shot load of the installed-app list. Kept alive so re-opening the
/// picker does not re-query PackageManager.
final installedAppsProvider = FutureProvider<List<AppInfo>>((ref) {
  return ref.watch(nozeltEngineProvider).getInstalledApps();
});

/// Lazily-loaded, per-package icon bytes. A short keepalive smooths scroll-back
/// without retaining every installed-app PNG for the whole process lifetime.
/// Null means "no icon" (show a placeholder).
final appIconProvider = FutureProvider.autoDispose.family<Uint8List?, String>((
  ref,
  pkg,
) {
  final link = ref.keepAlive();
  final timer = Timer(const Duration(seconds: 30), link.close);
  ref.onDispose(timer.cancel);
  return ref.watch(nozeltEngineProvider).getAppIcon(pkg);
});
