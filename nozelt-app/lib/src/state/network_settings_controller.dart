import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/models.dart';
import '../core/runtime_rollback.dart';
import '../core/tun_settings.dart';
import '../core/advanced_network_settings.dart';
import '../core/multi_core_config_builder.dart';
import 'profiles_provider.dart';
import 'engine_provider.dart';
import 'settings_provider.dart';

final networkSettingsControllerProvider = Provider<NetworkSettingsController>(
  NetworkSettingsController.new,
);

/// Serializes TUN-shaping edits across preferences and a fail-closed native
/// replacement. Unlike domain rules, these settings affect VpnService.Builder
/// and therefore require a fresh Android interface rather than hot reload.
class NetworkSettingsController {
  NetworkSettingsController(this.ref);

  final Ref ref;
  Future<void> _tail = Future<void>.value();

  Future<void> setStack(TunStack stack) =>
      _mutate((current) => current.copyWith(stack: stack));

  Future<void> setMtu(int mtu) =>
      _mutate((current) => current.copyWith(mtu: mtu));

  Future<void> setIpv6(bool enabled) =>
      _mutate((current) => current.copyWith(ipv6: enabled));

  Future<void> setDns({
    required String fakeIpRange,
    required List<String> nameservers,
  }) => _mutate(
    (current) =>
        current.copyWith(fakeIpRange: fakeIpRange, nameservers: nameservers),
  );

  Future<void> setAdvancedDns({
    required AdvancedDnsSettings dns,
    required String fakeIpRange,
    required List<String> nameservers,
  }) => _mutate(
    (s) => s.copyWith(
      dns: dns,
      fakeIpRange: fakeIpRange,
      nameservers: nameservers,
    ),
    preflight: true,
  );

  Future<void> setDesktopTun({
    required DesktopTunSettings desktop,
    required TunStack stack,
    required int mtu,
    required bool ipv6,
  }) => _mutate(
    (s) => s.copyWith(desktop: desktop, stack: stack, mtu: mtu, ipv6: ipv6),
    preflight: true,
  );

  Future<void> _mutate(
    TunSettings Function(TunSettings current) transform, {
    bool preflight = false,
  }) {
    final completer = Completer<void>();
    _tail = _tail.then((_) async {
      TunSettings? previous;
      var updated = false;
      try {
        if (!ref.mounted) {
          throw StateError('Network settings controller was disposed.');
        }
        final notifier = ref.read(tunSettingsProvider.notifier);
        final engineNotifier = ref.read(engineStateProvider.notifier);
        final before = ref.read(tunSettingsProvider);
        previous = before;
        final next = transform(before);
        final validationKey = next.validationKey();
        if (validationKey != null) throw ArgumentError(validationKey);
        // Windows validates offline; Android relies on the protected
        // restart below, which rolls back a configuration Mihomo rejects.
        if (preflight &&
            defaultTargetPlatform == TargetPlatform.windows &&
            ref.exists(profilesProvider)) {
          final profile = ref.read(profilesProvider).value?.active;
          if (profile != null && profile.nodes.isNotEmpty) {
            // Reject unsupported native DNS/filter syntax before persisting,
            // even while disconnected. This path never applies a TUN.
            final candidate = await MultiCoreConfigBuilder.buildAsync(
              next,
              profile: profile,
              desktopNativeTun: true,
            );
            await ref
                .read(nozeltEngineProvider)
                .validateWindowsConfiguration(candidate);
          }
        }
        updated = true;
        await notifier.updatePersisted(next);
        if (!ref.mounted) {
          throw StateError('Network settings controller was disposed.');
        }
        await engineNotifier.restartWithCurrentConfiguration(
          rollback: RuntimeRollbackSnapshot.tun(before),
        );
        completer.complete();
      } catch (error, stackTrace) {
        if (!ref.mounted) {
          completer.completeError(error, stackTrace);
          return;
        }
        final nativeReplacementFailed =
            ref.read(engineStateProvider).connection ==
            EngineConnectionState.error;
        var rollbackPersisted = false;
        if (updated && previous != null) {
          try {
            await ref
                .read(tunSettingsProvider.notifier)
                .updatePersisted(previous);
            rollbackPersisted = true;
          } catch (_) {
            // Preserve the original persistence/restart failure.
          }
        }
        if (nativeReplacementFailed && rollbackPersisted) {
          try {
            // restartWithConfig may already have stopped the old core while
            // Android's keeper holds traffic fail closed. Rebuild from the
            // now-restored settings so the rollback also becomes the live and
            // encrypted runtime configuration, not just a UI preference.
            await ref
                .read(engineStateProvider.notifier)
                .restartWithCurrentConfiguration(allowErrorRecovery: true);
          } catch (_) {
            // Keep the original apply failure. EngineNotifier exposes any
            // rollback-recovery failure through its own truthful error state.
          }
        }
        completer.completeError(error, stackTrace);
      }
    });
    return completer.future;
  }
}
