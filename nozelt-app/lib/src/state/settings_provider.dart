import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/sensitive_settings_repository.dart';
import '../data/app_preferences.dart';
import '../core/routing_rule.dart';
import '../core/tun_settings.dart';

/// Holds the [SharedPreferences] instance. Overridden in `main()` with the
/// value loaded before `runApp`, so every provider can read/write settings
/// synchronously instead of threading a Future through the tree.
final sharedPreferencesProvider = Provider<SharedPreferences>((ref) {
  throw UnimplementedError(
    'sharedPreferencesProvider must be overridden in main()',
  );
});

final sensitiveSettingsRepositoryProvider =
    Provider<SensitiveSettingsRepository>((ref) {
      return SensitiveSettingsRepository.legacy(
        ref.watch(sharedPreferencesProvider),
      );
    });

/// Owns the persisted [TunSettings]. Android overrides the repository with a
/// Keystore-backed implementation before the first frame.
class TunSettingsNotifier extends Notifier<TunSettings> {
  Future<void> _persistTail = Future<void>.value();

  @override
  TunSettings build() => ref.watch(sensitiveSettingsRepositoryProvider).tun;

  /// The only mutation primitive. NetworkSettingsController and
  /// RoutingConfigController add validation plus native apply/rollback around
  /// it, preventing UI code from changing durable policy without updating the
  /// process-global VPN configuration.
  Future<void> updatePersisted(TunSettings next) async {
    state = next;
    await _enqueuePersist(next);
  }

  /// Compatibility mirror for code that still observes TunSettings directly.
  /// RoutingProfilesNotifier persists the same values in one encrypted write.
  void syncRoutingMirror({
    required RoutingMode mode,
    required List<RoutingRule> rules,
    required int geoUpdateIntervalHours,
  }) {
    state = state.copyWith(
      routingMode: mode,
      customRules: rules,
      geoUpdateIntervalHours: geoUpdateIntervalHours,
    );
  }

  Future<void> _enqueuePersist(TunSettings value) {
    final repository = ref.read(sensitiveSettingsRepositoryProvider);
    final operation = _persistTail.then((_) => repository.saveTun(value));
    // A failed write must be reported to its caller, but must not poison the
    // queue and prevent every later settings update from being persisted.
    _persistTail = operation.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    return operation;
  }
}

final tunSettingsProvider = NotifierProvider<TunSettingsNotifier, TunSettings>(
  TunSettingsNotifier.new,
);
