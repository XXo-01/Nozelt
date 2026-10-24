import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/models.dart';
import 'engine_provider.dart';
import 'routing_config_controller.dart';
import 'routing_profiles_provider.dart';

/// Schedules per-routing-profile GeoIP/GeoSite refreshes while a tunnel is
/// available. Native assets are verified before replacement; a failed update
/// leaves the previous database and timestamp intact.
class GeoDataUpdateCoordinator extends Notifier<void> {
  Timer? _timer;
  bool _updating = false;

  @override
  void build() {
    ref.onDispose(() => _timer?.cancel());
    ref.listen(
      engineStateProvider.select((value) => value.connection),
      (_, _) => _schedule(),
    );
    ref.listen(routingProfilesProvider, (_, _) => _schedule());
    Future.microtask(_schedule);
  }

  void _schedule() {
    if (!ref.mounted) return;
    _timer?.cancel();
    _timer = null;
    if (ref.read(engineStateProvider).connection !=
        EngineConnectionState.connected) {
      return;
    }
    final settings = ref.read(routingProfilesProvider).active.settings;
    final hours = settings.geoUpdateIntervalHours;
    if (hours <= 0) return;
    final now = DateTime.now().toUtc();
    final last = settings.lastGeoUpdateEpochSeconds == null
        ? null
        : DateTime.fromMillisecondsSinceEpoch(
            settings.lastGeoUpdateEpochSeconds! * 1000,
            isUtc: true,
          );
    final due =
        last?.add(Duration(hours: hours)) ??
        now.add(const Duration(seconds: 5));
    final delay = due.difference(now);
    _timer = Timer(delay.isNegative ? Duration.zero : delay, _runUpdate);
  }

  Future<void> _runUpdate() async {
    if (_updating || !ref.mounted) return;
    if (ref.read(engineStateProvider).connection !=
        EngineConnectionState.connected) {
      _schedule();
      return;
    }
    _updating = true;
    try {
      await ref.read(routingConfigControllerProvider).markGeoDataUpdated();
    } catch (_) {
      // Preserve the verified old databases and retry after a bounded delay.
      if (ref.mounted) {
        _timer = Timer(const Duration(hours: 1), _runUpdate);
      }
      return;
    } finally {
      _updating = false;
    }
    if (ref.mounted) _schedule();
  }
}

final geoDataUpdateCoordinatorProvider =
    NotifierProvider<GeoDataUpdateCoordinator, void>(
      GeoDataUpdateCoordinator.new,
    );
