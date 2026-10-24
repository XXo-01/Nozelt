import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/config_builder.dart';
import '../core/config_error.dart';
import '../core/multi_core_config_builder.dart';
import '../core/models.dart';
import '../core/nozelt_engine.dart';
import '../core/profile.dart';
import '../core/runtime_rollback.dart';
import '../core/split_tunnel_settings.dart';
import '../core/tun_settings.dart';
import '../core/vpn_core.dart';
import '../l10n/nozelt_l10n.dart';
import '../l10n/user_error.dart';
import 'app_lifecycle_provider.dart';
import 'app_settings_provider.dart';
import 'profiles_provider.dart';
import 'routing_profiles_provider.dart';
import 'split_tunnel_provider.dart';

/// Process-wide engine handle. Single instance is fine — both the Go engine
/// and its Kotlin host are singletons too.
final nozeltEngineProvider = Provider<NozeltEngine>((ref) => NozeltEngine());

/// Streams the Kotlin-side TrafficStreamHandler output. Broadcast under the
/// hood so multiple widgets can subscribe.
final trafficStreamProvider = StreamProvider.autoDispose<Traffic>((ref) {
  final engine = ref.watch(nozeltEngineProvider);
  return engine.trafficStream();
});

/// Streams redacted Go-side log lines on demand. The native logger is not
/// installed until a consumer subscribes, keeping normal cold starts cheap.
final logsStreamProvider = StreamProvider.autoDispose<LogEntry>((ref) {
  final engine = ref.watch(nozeltEngineProvider);
  return engine.logsStream();
});

/// Versions reported by `Binding.getVersion`. One-shot — cached forever.
final engineVersionsProvider = FutureProvider<EngineVersions>((ref) {
  final engine = ref.watch(nozeltEngineProvider);
  return engine.getVersion();
});

/// Notifier owning the engine's connection lifecycle and the most recent
/// status snapshot. UI listens to this, calls [connect] / [disconnect].
///
/// Status polling runs only while the app is resumed and connected. There is
/// no push channel for status; the call is cheap and the poller is stopped in
/// the background so cached processes do not accumulate work.
class EngineNotifier extends Notifier<EngineState> {
  Timer? _statusPoller;
  bool _appResumed = true;
  bool _statusPollInFlight = false;
  bool _recoveryInFlight = false;
  bool _nativeRestoreInFlight = false;
  bool _windowsStartupChecked = false;
  int _consecutiveDownPolls = 0;
  int _lifecycleEpoch = 0;
  Future<void> _configurationTail = Future<void>.value();
  int _configurationQueueDepth = 0;

  @override
  EngineState build() {
    _appResumed =
        defaultTargetPlatform == TargetPlatform.windows ||
        ref.read(appResumedProvider);
    final quickSettingsSubscription = _engine
        .quickSettingsConnectRequests()
        .listen((_) => unawaited(_connectFromQuickSettings()));
    ref.listen<bool>(appResumedProvider, (_, resumed) {
      _onAppResumedChanged(resumed);
    });
    ref.onDispose(() {
      _stopPolling();
      quickSettingsSubscription.cancel();
    });
    Future.microtask(_restoreNativeState);
    return const EngineState();
  }

  NozeltEngine get _engine => ref.read(nozeltEngineProvider);

  String _tr(String key, [Map<String, Object> args = const {}]) =>
      NozeltL10n(ref.read(appSettingsProvider).languageCode).text(key, args);

  Future<void> connect() async {
    if (_configurationQueueDepth > 0) return;
    if (state.connection == EngineConnectionState.connecting ||
        state.connection == EngineConnectionState.connected) {
      return;
    }

    // Validate settings before touching the system VPN so a bad value (e.g.
    // out-of-range MTU) blocks the connect with a clear message instead of
    // producing a silently broken tunnel.
    final settings = ref.read(effectiveTunSettingsProvider);
    final validationKey = settings.validationKey();
    if (validationKey != null) {
      state = state.copyWith(
        connection: EngineConnectionState.error,
        errorMessage: _tr(validationKey),
      );
      return;
    }

    final profiles = ref.read(profilesProvider);
    if (profiles.hasError) {
      state = state.copyWith(
        connection: EngineConnectionState.error,
        errorMessage: _tr('profilesUnavailable'),
      );
      return;
    }
    final activeProfile = profiles.value?.active;
    if (activeProfile == null || activeProfile.nodes.isEmpty) {
      state = state.copyWith(
        connection: EngineConnectionState.error,
        errorMessage: _tr('profileRequired'),
      );
      return;
    }

    final epoch = ++_lifecycleEpoch;
    state = state.copyWith(
      connection: EngineConnectionState.connecting,
      clearError: true,
    );

    try {
      final granted = await _engine.prepareVpn();
      if (!ref.mounted || epoch != _lifecycleEpoch) return;
      if (!granted) {
        state = state.copyWith(
          connection: EngineConnectionState.error,
          errorMessage: _tr('vpnPermissionDenied'),
        );
        return;
      }

      // Config is assembled from persisted settings + the active profile's
      // nodes. The fail-closed guard above guarantees at least one proxy.
      // Split-tunnel selection is layered on the VpnService side;
      // mihomo's own sockets are excluded individually with VpnService.protect.
      final split = ref.read(splitTunnelProvider);
      final rendered = await MultiCoreConfigBuilder.buildAsync(
        settings,
        profile: activeProfile,
        desktopNativeTun: defaultTargetPlatform == TargetPlatform.windows,
      );
      final config = rendered.content;
      if (!ref.mounted || epoch != _lifecycleEpoch) return;
      final tunOptions = ConfigBuilder.buildTunOptions(
        settings,
        splitMode: split.mode.wire,
        apps: _sortedApps(split),
      );
      await _syncNotification(activeProfile, updatePing: true);
      if (!ref.mounted || epoch != _lifecycleEpoch) return;
      await _engine.start(
        config,
        tunOptionsJson: jsonEncode(tunOptions),
        core: rendered.core,
      );
      if (!ref.mounted || epoch != _lifecycleEpoch) return;

      // The foreground service establishes the TUN and starts the engine
      // asynchronously, so `running` is not necessarily true the instant
      // start() returns. Poll getStatus briefly until the engine reports up
      // (or give up and surface an error) instead of trusting a single read.
      final status = await _awaitRunning();
      if (!ref.mounted || epoch != _lifecycleEpoch) return;
      if (status == null) {
        final released = await _releaseFailedWindowsStart();
        if (!ref.mounted || epoch != _lifecycleEpoch) return;
        state = state.copyWith(
          connection: EngineConnectionState.error,
          status: released,
          errorMessage: _tr('engineStartFailed'),
        );
        return;
      }
      state = state.copyWith(
        connection: EngineConnectionState.connected,
        status: status,
      );
      _consecutiveDownPolls = 0;
      _startPolling();
      _notifySplitTunnelConnected(split);
    } catch (e) {
      if (kDebugMode) debugPrint('connect failed (${e.runtimeType})');
      if (!ref.mounted || epoch != _lifecycleEpoch) return;
      var failedStatus = state.status;
      if (defaultTargetPlatform == TargetPlatform.windows) {
        failedStatus = await _releaseFailedWindowsStart() ?? failedStatus;
        if (!ref.mounted || epoch != _lifecycleEpoch) return;
      }
      final code = e is NozeltEngineException ? e.code : 'internal';
      state = state.copyWith(
        connection: EngineConnectionState.error,
        status: failedStatus,
        errorMessage: failedStatus.networkGuard
            ? _tr('networkProtectionRetained')
            : e is CoreConfigurationError
            ? _tr(e.l10nKey)
            : code == 'administrator_required'
            ? _tr('administratorRequired')
            : code == 'another_vpn_active'
            ? anotherVpnMessage(
                NozeltL10n(ref.read(appSettingsProvider).languageCode),
                e is NozeltEngineException ? e.details : null,
              )
            : code == 'network_guard_failed'
            ? _tr('networkGuardFailed')
            : code == 'tls_verification_required'
            ? _tr('windowsTlsVerificationRequired')
            : code == 'provider_process_rules_unsupported'
            ? _tr('windowsProviderProcessRulesUnsupported')
            : _tr('vpnOperationFailed', {'code': code}),
      );
    }
  }

  /// A Windows start that did not come up must not leave the network block
  /// behind: internet always works while Nozelt is not connected. The core
  /// already releases it on its own failures; this covers a start that the
  /// core reported as successful but that never reached the running state.
  Future<Status?> _releaseFailedWindowsStart() async {
    if (defaultTargetPlatform != TargetPlatform.windows) return null;
    try {
      var status = await _engine.getStatus();
      if (status.networkGuard && !status.running) {
        await _engine.stop();
        status = await _engine.getStatus();
      }
      return status;
    } catch (_) {
      return null;
    }
  }

  Future<void> disconnect() async {
    if (_configurationQueueDepth > 0) return;
    if (state.connection == EngineConnectionState.disconnected ||
        state.connection == EngineConnectionState.disconnecting) {
      return;
    }

    // Android immediately restarts a stopped Always-on service, and lockdown
    // can block all traffic in between. Preserve the live native state; UI
    // callers direct the user to system VPN settings instead.
    if (await _engine.isAlwaysOnVpn()) return;
    if (!ref.mounted) return;

    final epoch = ++_lifecycleEpoch;
    state = state.copyWith(
      connection: EngineConnectionState.disconnecting,
      clearError: true,
    );
    _stopPolling();

    try {
      await _engine.stop();
      final stopped = await _awaitStopped();
      if (!ref.mounted || epoch != _lifecycleEpoch) return;
      if (!stopped) {
        state = state.copyWith(
          connection: EngineConnectionState.error,
          errorMessage: _tr('vpnStopFailed'),
        );
        return;
      }
      state = state.copyWith(
        connection: EngineConnectionState.disconnected,
        status: Status.idle,
      );
    } catch (e) {
      if (kDebugMode) debugPrint('disconnect failed');
      if (!ref.mounted || epoch != _lifecycleEpoch) return;
      state = state.copyWith(
        connection: EngineConnectionState.error,
        errorMessage: _tr('vpnOperationFailed', {
          'code': e is NozeltEngineException ? e.code : 'internal',
        }),
      );
    }
  }

  /// Hot-applies routing mode and domain/CIDR rules while retaining the TUN.
  /// TUN-shaping fields (MTU/stack/IPv6) continue to require a reconnect.
  Future<void> reloadRouting(
    TunSettings settings, {
    RuntimeRollbackSnapshot? rollback,
  }) {
    if (state.connection == EngineConnectionState.disconnected) {
      return Future<void>.value();
    }
    if (!_canQueueConfigurationChange) {
      throw StateError(_tr('operationBusy'));
    }
    return _enqueueConfiguration(() => _reloadRoutingNow(settings, rollback));
  }

  Future<void> _reloadRoutingNow(
    TunSettings _,
    RuntimeRollbackSnapshot? rollback,
  ) async {
    if (state.connection != EngineConnectionState.connected) {
      throw StateError(_tr('operationBusy'));
    }
    // Another queued controller may have committed a disjoint TUN field after
    // this routing operation was requested. Render the latest complete shared
    // snapshot so a delayed hot reload cannot put old DNS/IPv6 policy back
    // into mihomo while Android and encrypted storage already use the new one.
    final settings = ref.read(effectiveTunSettingsProvider);
    final validationKey = settings.validationKey();
    if (validationKey != null) throw StateError(_tr(validationKey));

    final activeProfile = ref.read(profilesProvider).value?.active;
    if (activeProfile == null || activeProfile.nodes.isEmpty) {
      throw StateError(_tr('profileRequired'));
    }
    final split = ref.read(splitTunnelProvider);
    final rendered = await MultiCoreConfigBuilder.buildAsync(
      settings,
      profile: activeProfile,
      desktopNativeTun: defaultTargetPlatform == TargetPlatform.windows,
    );
    final config = rendered.content;
    if (!ref.mounted) {
      throw StateError('Engine provider was disposed during config rendering.');
    }
    final tunOptions = ConfigBuilder.buildTunOptions(
      settings,
      splitMode: split.mode.wire,
      apps: _sortedApps(split),
    );
    if (rendered.core == VpnCore.mihomo ||
        defaultTargetPlatform == TargetPlatform.windows) {
      await _engine.reloadConfig(
        config,
        tunOptionsJson: jsonEncode(tunOptions),
        rollback: rollback,
        core: rendered.core,
      );
    } else {
      await _engine.restartWithConfig(
        config,
        tunOptionsJson: jsonEncode(tunOptions),
        rollback: rollback,
        core: rendered.core,
      );
    }
    if (!ref.mounted) {
      throw StateError('Engine provider was disposed during routing reload.');
    }

    // A full ApplyConfig rebuilds selector groups. Re-assert the latest
    // persisted selection if a node switch overlapped this rules-only reload.
    final selected = ref
        .read(profilesProvider)
        .value
        ?.active
        ?.effectiveSelectedNodeName;
    if (selected != null && rendered.core == VpnCore.mihomo) {
      await _engine.selectProxy(selected);
    }
    if (!ref.mounted) {
      throw StateError('Engine provider was disposed during selector restore.');
    }

    final status = await _engine.getStatus();
    if (!ref.mounted) {
      throw StateError('Engine provider was disposed during status read.');
    }
    if (!status.running) throw StateError(_tr('vpnStoppedUnexpectedly'));
    if (state.connection == EngineConnectionState.connected) {
      state = state.copyWith(status: status);
    }
  }

  /// Re-establishes VpnService with the latest persisted TUN and per-app
  /// settings. Native code keeps the previous TUN descriptor open until the
  /// replacement starts, and this method waits for a newer service generation.
  Future<void> restartWithCurrentConfiguration({
    bool allowErrorRecovery = false,
    RuntimeRollbackSnapshot? rollback,
  }) {
    if (state.connection == EngineConnectionState.disconnected) {
      return Future<void>.value();
    }
    final requestedFromActiveConfiguration = _canQueueConfigurationChange;
    final explicitErrorRecovery =
        allowErrorRecovery && state.connection == EngineConnectionState.error;
    if (!requestedFromActiveConfiguration && !explicitErrorRecovery) {
      throw StateError(_tr('operationBusy'));
    }
    return _enqueueConfiguration(
      () => _restartWithCurrentConfigurationNow(
        // A request queued while another valid replacement was active must be
        // allowed to rebuild the latest union if that earlier replacement
        // fails first. Otherwise it would be silently reported as applied.
        allowErrorRecovery:
            allowErrorRecovery || requestedFromActiveConfiguration,
        rollback: rollback,
      ),
    );
  }

  Future<void> _restartWithCurrentConfigurationNow({
    required bool allowErrorRecovery,
    required RuntimeRollbackSnapshot? rollback,
  }) async {
    final recoveringFailedReplacement =
        allowErrorRecovery && state.connection == EngineConnectionState.error;
    if (state.connection != EngineConnectionState.connected &&
        !recoveringFailedReplacement) {
      throw StateError(_tr('operationBusy'));
    }

    final settings = ref.read(effectiveTunSettingsProvider);
    final validationKey = settings.validationKey();
    if (validationKey != null) throw StateError(_tr(validationKey));
    final activeProfile = ref.read(profilesProvider).value?.active;
    if (activeProfile == null || activeProfile.nodes.isEmpty) {
      throw StateError(_tr('profileRequired'));
    }
    final split = ref.read(splitTunnelProvider);

    final previousState = state;
    final epoch = ++_lifecycleEpoch;
    _stopPolling();
    state = state.copyWith(
      connection: EngineConnectionState.connecting,
      clearError: true,
    );
    var nativeAttempted = false;
    try {
      final rendered = await MultiCoreConfigBuilder.buildAsync(
        settings,
        profile: activeProfile,
        desktopNativeTun: defaultTargetPlatform == TargetPlatform.windows,
      );
      final config = rendered.content;
      if (!ref.mounted) {
        throw StateError(
          'Engine provider was disposed during config rendering.',
        );
      }
      if (epoch != _lifecycleEpoch) throw StateError(_tr('operationBusy'));
      final tunOptions = ConfigBuilder.buildTunOptions(
        settings,
        splitMode: split.mode.wire,
        apps: _sortedApps(split),
      );
      final tunOptionsJson = jsonEncode(tunOptions);
      var alreadyApplied = false;
      try {
        if (await _engine.matchesRuntimeConfig(
          config,
          tunOptionsJson: tunOptionsJson,
          core: rendered.core,
        )) {
          final currentStatus = await _engine.getStatus();
          if (currentStatus.running) {
            state = state.copyWith(
              connection: EngineConnectionState.connected,
              status: currentStatus,
              clearError: true,
            );
            _consecutiveDownPolls = 0;
            _startPolling();
            _notifySplitTunnelConnected(split);
            alreadyApplied = true;
          }
        }
      } catch (_) {
        // Equality is an optimization and crash-reconciliation guard. A
        // transient comparison failure must fall through to the normal
        // keeper-backed replacement rather than reject a valid user edit.
      }
      if (alreadyApplied) return;
      nativeAttempted = true;
      await _engine.restartWithConfig(
        config,
        tunOptionsJson: tunOptionsJson,
        rollback: rollback,
        core: rendered.core,
      );
      if (!ref.mounted) {
        throw StateError(
          'Engine provider was disposed during VPN replacement.',
        );
      }
      if (epoch != _lifecycleEpoch) {
        throw StateError(_tr('operationBusy'));
      }
      final status = await _engine.getStatus();
      if (!ref.mounted) {
        throw StateError('Engine provider was disposed during status read.');
      }
      if (!status.running) throw StateError(_tr('engineStartFailed'));
      state = state.copyWith(
        connection: EngineConnectionState.connected,
        status: status,
        clearError: true,
      );
      _consecutiveDownPolls = 0;
      _startPolling();
      _notifySplitTunnelConnected(split);
      await _restoreLiveSelector();
    } catch (error) {
      if (kDebugMode) debugPrint('configuration restart failed');
      if (!ref.mounted) rethrow;
      if (epoch != _lifecycleEpoch) rethrow;
      if (!nativeAttempted) {
        // Rendering/validation failed before Android or the encrypted runtime
        // was touched. The old tunnel is still authoritative; restore its UI
        // snapshot and let the owning settings/profile transaction roll back.
        state = previousState;
        if (previousState.connection == EngineConnectionState.connected) {
          _startPolling();
        }
        rethrow;
      }
      state = state.copyWith(
        connection: EngineConnectionState.error,
        status: Status.idle,
        errorMessage: _tr('vpnRecoveryFailed', {
          'error': error is NozeltEngineException ? error.code : 'internal',
        }),
      );
      _stopPolling();
      // Settings/profile controllers need an authoritative failure so they
      // can roll durable state back or keep a pending replacement. Swallowing
      // this exception made a broken native restart look successfully applied.
      rethrow;
    }
  }

  Future<void> _restoreNativeState() async {
    // build(), foreground resume, and an OEM activity recreation can all
    // schedule restoration close together. Only one caller may poll/restart
    // the process-global VPN service; duplicate ACTION_RESTART dispatches
    // would otherwise tear down a session that has just recovered.
    if (_nativeRestoreInFlight || _configurationQueueDepth > 0) return;
    if (state.connection == EngineConnectionState.connecting ||
        state.connection == EngineConnectionState.disconnecting) {
      return;
    }
    _nativeRestoreInFlight = true;
    final epoch = _lifecycleEpoch;
    try {
      // This small Kotlin preference read avoids loading the 40 MB native core
      // on normal disconnected cold starts.
      if (!await _engine.isVpnRequested()) {
        if (!ref.mounted) return;
        if (epoch != _lifecycleEpoch) return;
        final windowsStartup =
            defaultTargetPlatform == TargetPlatform.windows &&
            !_windowsStartupChecked;
        if (defaultTargetPlatform == TargetPlatform.windows) {
          _windowsStartupChecked = true;
          try {
            final retained = await _engine.getStatus();
            if (!ref.mounted || epoch != _lifecycleEpoch) return;
            if (retained.networkGuard && !retained.running) {
              state = state.copyWith(
                connection: EngineConnectionState.error,
                status: retained,
                errorMessage: _tr('networkProtectionRetained'),
              );
            }
          } catch (_) {}
        }
        final requestedFromQuickSettings =
            defaultTargetPlatform == TargetPlatform.android &&
            await _engine.consumeQuickSettingsConnectRequest();
        if (!ref.mounted || epoch != _lifecycleEpoch) return;
        if ((defaultTargetPlatform == TargetPlatform.android ||
                defaultTargetPlatform == TargetPlatform.windows) &&
            (requestedFromQuickSettings ||
                (windowsStartup &&
                    Platform.isWindows &&
                    Platform.environment['NOZELT_CONNECT_ON_START'] == '1') ||
                (ref.read(appSettingsProvider).autoConnectEnabled &&
                    (defaultTargetPlatform != TargetPlatform.windows ||
                        windowsStartup)))) {
          try {
            await ref.read(profilesProvider.future);
            if (!ref.mounted || epoch != _lifecycleEpoch) return;
            await connect();
          } catch (_) {
            if (kDebugMode) debugPrint('requested VPN start failed');
          }
          return;
        }
        if (defaultTargetPlatform == TargetPlatform.windows &&
            state.status.networkGuard) {
          return;
        }
        if (state.connection != EngineConnectionState.disconnected) {
          state = state.copyWith(
            connection: EngineConnectionState.disconnected,
            status: Status.idle,
            clearError: true,
          );
        }
        return;
      }

      if (epoch != _lifecycleEpoch) return;
      if (defaultTargetPlatform == TargetPlatform.android &&
          !ref.read(appSettingsProvider).autoConnectEnabled &&
          !await _engine.isAlwaysOnVpn()) {
        Status? currentStatus;
        try {
          currentStatus = await _engine.getStatus();
        } catch (_) {
          // Treat an unavailable native status as a stopped stale request.
        }
        if (!ref.mounted || epoch != _lifecycleEpoch) return;
        if (currentStatus == null || !currentStatus.running) {
          await _engine.stop();
          await _awaitStopped();
          if (!ref.mounted || epoch != _lifecycleEpoch) return;
          state = state.copyWith(
            connection: EngineConnectionState.disconnected,
            status: Status.idle,
            clearError: true,
          );
          _stopPolling();
          return;
        }
      }
      // A requested native session may currently be in the service's
      // fail-closed recovery window. Replace any stale connected snapshot
      // immediately while we wait for authoritative native status.
      state = state.copyWith(
        connection: EngineConnectionState.connecting,
        clearError: true,
      );

      var status = await _awaitRunning();
      if (!ref.mounted || epoch != _lifecycleEpoch) return;
      if (status == null) {
        // The desired-state flag survives service/OEM eviction and the native
        // service keeps failed replacements fail-closed. If neither its
        // bounded retries nor Android's sticky restart recovered while the UI
        // was backgrounded, foreground resume is a meaningful external event.
        // Render the encrypted durable profile again instead of retrying a
        // possibly malformed legacy runtime snapshot forever. This also
        // migrates selector state written by older builds through JSONObject.
        try {
          await _reseedRequestedRuntimeFromDurableState();
          status = await _awaitRunning();
        } catch (_) {
          if (kDebugMode) {
            debugPrint('foreground VPN recovery dispatch failed');
          }
        }
      }
      if (!ref.mounted || epoch != _lifecycleEpoch) return;
      if (status != null) {
        state = state.copyWith(
          connection: EngineConnectionState.connected,
          status: status,
          clearError: true,
        );
        final runtimeMatches = await _nativeRuntimeMatchesDurableState();
        if (!ref.mounted || epoch != _lifecycleEpoch) return;
        if (!runtimeMatches) {
          // Flutter may have died after committing encrypted settings but
          // before staging their native replacement, or bootstrap may have
          // raced the final milliseconds of a native fallback. Converge the
          // running service to the durable snapshot through the same keeper-
          // backed queue instead of showing a profile/policy that is not live.
          try {
            await restartWithCurrentConfiguration();
          } catch (_) {
            if (kDebugMode) {
              debugPrint('runtime configuration reconciliation failed');
            }
          }
          return;
        }
        _consecutiveDownPolls = 0;
        if (_appResumed) _startPolling();
        _notifySplitTunnelConnected(ref.read(splitTunnelProvider));
        unawaited(_restoreLiveSelector());
      } else {
        // The service is still requested (possibly keeping the previous TUN
        // as a fail-closed black hole), but the native core did not recover
        // within its bounded retry window. Never retain a stale "connected"
        // UI after a long background pause or a process/service restart.
        state = state.copyWith(
          connection: EngineConnectionState.error,
          status: Status.idle,
          errorMessage: _tr('vpnStoppedUnexpectedly'),
        );
        _stopPolling();
      }
    } catch (_) {
      if (kDebugMode) debugPrint('native state restore failed');
      if (!ref.mounted) return;
      // Once the requested-session branch has replaced the initial snapshot
      // with `connecting`, swallowing an unexpected platform/storage error
      // would leave the power button disabled forever. Keep the native
      // fail-closed service untouched, but make the UI truthful and retryable;
      // the next foreground transition runs restoration again.
      if (epoch == _lifecycleEpoch &&
          state.connection == EngineConnectionState.connecting) {
        state = state.copyWith(
          connection: EngineConnectionState.error,
          status: Status.idle,
          errorMessage: _tr('vpnStoppedUnexpectedly'),
        );
        _stopPolling();
      }
    } finally {
      _nativeRestoreInFlight = false;
    }
  }

  Future<void> _restoreLiveSelector() async {
    try {
      final profiles = await ref.read(profilesProvider.future);
      if (!ref.mounted) return;
      final selected = profiles.active?.effectiveSelectedNodeName;
      if (profiles.active?.effectiveCore == VpnCore.mihomo &&
          selected != null &&
          state.connection == EngineConnectionState.connected) {
        await _engine.selectProxy(selected);
      }
    } catch (_) {
      if (kDebugMode) debugPrint('live selector restore failed');
    }
  }

  Future<bool> _nativeRuntimeMatchesDurableState() async {
    try {
      final profiles = await ref.read(profilesProvider.future);
      if (!ref.mounted) return true;
      final active = profiles.active;
      if (active == null || active.nodes.isEmpty) return true;
      final settings = ref.read(effectiveTunSettingsProvider);
      final split = ref.read(splitTunnelProvider);
      final rendered = await MultiCoreConfigBuilder.buildAsync(
        settings,
        profile: active,
        desktopNativeTun: defaultTargetPlatform == TargetPlatform.windows,
      );
      final config = rendered.content;
      if (!ref.mounted) return true;
      final tunOptions = ConfigBuilder.buildTunOptions(
        settings,
        splitMode: split.mode.wire,
        apps: _sortedApps(split),
      );
      return await _engine.matchesRuntimeConfig(
        config,
        tunOptionsJson: jsonEncode(tunOptions),
        core: rendered.core,
      );
    } catch (_) {
      // A transient profile/Keystore read must not tear down a working native
      // tunnel. The next foreground restore retries the comparison.
      return true;
    }
  }

  Future<void> _reseedRequestedRuntimeFromDurableState() async {
    final profiles = await ref.read(profilesProvider.future);
    if (!ref.mounted) return;
    final active = profiles.active;
    if (active == null || active.nodes.isEmpty) {
      throw StateError('Requested VPN has no durable active profile.');
    }
    final settings = ref.read(effectiveTunSettingsProvider);
    if (settings.validationKey() != null) {
      throw StateError('Requested VPN settings are invalid.');
    }
    final split = ref.read(splitTunnelProvider);
    final rendered = await MultiCoreConfigBuilder.buildAsync(
      settings,
      profile: active,
      desktopNativeTun: defaultTargetPlatform == TargetPlatform.windows,
    );
    final config = rendered.content;
    if (!ref.mounted) return;
    final tunOptions = ConfigBuilder.buildTunOptions(
      settings,
      splitMode: split.mode.wire,
      apps: _sortedApps(split),
    );
    await _syncNotification(active, updatePing: true);
    if (!ref.mounted) return;
    await _engine.start(
      config,
      tunOptionsJson: jsonEncode(tunOptions),
      core: rendered.core,
    );
  }

  List<String> _sortedApps(SplitTunnelSettings split) =>
      split.apps.toList(growable: false)..sort();

  Future<void> _syncNotification(
    Profile profile, {
    bool updatePing = false,
  }) async {
    final node = profile.selectedNode;
    if (node == null) return;
    await _engine.updateVpnNotification(
      flag: node.flagEmoji,
      serverName: node.displayName,
      updatePing: updatePing,
    );
  }

  Future<void> _connectFromQuickSettings() async {
    try {
      // Clear the durable Activity-side request so a later normal resume does
      // not unexpectedly reconnect after this live event has been handled.
      await _engine.consumeQuickSettingsConnectRequest();
      await ref.read(profilesProvider.future);
      if (!ref.mounted) return;
      if (state.connection == EngineConnectionState.disconnected ||
          state.connection == EngineConnectionState.error) {
        await connect();
      }
    } catch (_) {
      if (kDebugMode) debugPrint('Quick Settings VPN start failed');
    }
  }

  void _onAppResumedChanged(bool resumed) {
    // The desktop process owns the VPN even while its window is in the tray.
    // Keep recovery, status updates and silent-start autoconnect alive there.
    if (defaultTargetPlatform == TargetPlatform.windows) return;
    _appResumed = resumed;
    if (_appResumed) {
      Future.microtask(_restoreNativeState);
    } else {
      _stopPolling();
    }
  }

  /// Polls getStatus for a bounded wall-clock window while the foreground
  /// service establishes the TUN and calls Binding.start. The deadline, unlike
  /// a fixed attempt count, remains bounded even when an individual native
  /// status request itself times out.
  Future<Status?> _awaitRunning() async {
    final deadline = DateTime.now().add(const Duration(seconds: 16));
    const interval = Duration(milliseconds: 500);
    while (DateTime.now().isBefore(deadline)) {
      if (!ref.mounted) return null;
      try {
        final status = await _engine.getStatus();
        if (status.running) return status;
      } catch (_) {
        if (kDebugMode) debugPrint('await-running poll failed');
      }
      final remaining = deadline.difference(DateTime.now());
      if (remaining <= Duration.zero) break;
      await Future<void>.delayed(remaining < interval ? remaining : interval);
    }
    return null;
  }

  /// Waits for the native shutdown rather than treating delivery of the STOP
  /// Intent as completion. This keeps the UI in "disconnecting" while Go owns
  /// the TUN fd and prevents a rapid reconnect from overlapping teardown.
  Future<bool> _awaitStopped() async {
    final deadline = DateTime.now().add(const Duration(seconds: 20));
    const interval = Duration(milliseconds: 500);
    while (DateTime.now().isBefore(deadline)) {
      if (!ref.mounted) return false;
      try {
        if (!(await _engine.getStatus()).running) return true;
      } catch (_) {
        if (kDebugMode) debugPrint('await-stopped poll failed');
      }
      final remaining = deadline.difference(DateTime.now());
      if (remaining <= Duration.zero) break;
      await Future<void>.delayed(remaining < interval ? remaining : interval);
    }
    return false;
  }

  void _startPolling() {
    if (!_appResumed || state.connection != EngineConnectionState.connected) {
      return;
    }
    _statusPoller?.cancel();
    _statusPoller = Timer.periodic(
      const Duration(seconds: 1),
      (_) => _pollStatus(),
    );
  }

  Future<void> _pollStatus() async {
    if (_statusPollInFlight || !_appResumed) return;
    _statusPollInFlight = true;
    try {
      final status = await _engine.getStatus();
      if (!ref.mounted) return;
      // The native relay owns transport retries while its TUN and persistent
      // guard remain active. Do not tear down that frontend after three polls.
      if (status.recovering && status.networkGuard && status.tun.enabled) {
        _consecutiveDownPolls = 0;
        if (state.connection == EngineConnectionState.connected) {
          state = state.copyWith(status: status);
        }
        return;
      }
      // Only update the snapshot if we're still in a state where status is
      // meaningful — guards against late polls landing after disconnect.
      if (state.connection == EngineConnectionState.connected &&
          status.running) {
        _consecutiveDownPolls = 0;
        state = state.copyWith(status: status);
      } else if (state.connection == EngineConnectionState.connected) {
        _recordDownPoll();
      }
    } catch (_) {
      if (kDebugMode) debugPrint('status poll failed');
      // Platform-channel/native failures are just as authoritative as a
      // decoded `running:false` after several consecutive attempts. Without
      // this path one permanently wedged status call would leave the UI and
      // maintenance timers claiming the VPN is healthy forever.
      _recordDownPoll();
    } finally {
      _statusPollInFlight = false;
    }
  }

  void _recordDownPoll() {
    if (state.connection != EngineConnectionState.connected) return;
    _consecutiveDownPolls++;
    if (_consecutiveDownPolls >= 3 && !_recoveryInFlight) {
      unawaited(_recoverUnexpectedStop());
    }
  }

  void _stopPolling() {
    _statusPoller?.cancel();
    _statusPoller = null;
  }

  Future<void> _recoverUnexpectedStop() async {
    if (_recoveryInFlight) return;
    _recoveryInFlight = true;
    final epoch = ++_lifecycleEpoch;
    try {
      if (!await _engine.isVpnRequested()) {
        if (!ref.mounted) return;
        if (epoch != _lifecycleEpoch) return;
        state = state.copyWith(
          connection: EngineConnectionState.disconnected,
          status: Status.idle,
          clearError: true,
        );
        _stopPolling();
        return;
      }

      state = state.copyWith(
        connection: EngineConnectionState.connecting,
        clearError: true,
      );
      await _engine.restart();
      final recovered = await _awaitRunning();
      if (!ref.mounted || epoch != _lifecycleEpoch) return;
      if (recovered != null) {
        state = state.copyWith(
          connection: EngineConnectionState.connected,
          status: recovered,
          clearError: true,
        );
        _consecutiveDownPolls = 0;
        _startPolling();
        _notifySplitTunnelConnected(ref.read(splitTunnelProvider));
      } else {
        state = state.copyWith(
          connection: EngineConnectionState.error,
          status: Status.idle,
          errorMessage: _tr('vpnStoppedUnexpectedly'),
        );
        _stopPolling();
      }
    } catch (e) {
      if (!ref.mounted || epoch != _lifecycleEpoch) return;
      state = state.copyWith(
        connection: EngineConnectionState.error,
        status: Status.idle,
        errorMessage: _tr('vpnRecoveryFailed', {
          'error': e is NozeltEngineException ? e.code : 'internal',
        }),
      );
      _stopPolling();
    } finally {
      _recoveryInFlight = false;
    }
  }

  bool get _canQueueConfigurationChange =>
      state.connection == EngineConnectionState.connected ||
      (_configurationQueueDepth > 0 &&
          state.connection == EngineConnectionState.connecting);

  Future<T> _enqueueConfiguration<T>(Future<T> Function() operation) {
    final completer = Completer<T>();
    _configurationQueueDepth++;
    _configurationTail = _configurationTail.then((_) async {
      try {
        if (!ref.mounted) {
          throw StateError('Engine provider was disposed before config apply.');
        }
        completer.complete(await operation());
      } catch (error, stackTrace) {
        completer.completeError(error, stackTrace);
      } finally {
        _configurationQueueDepth--;
      }
    });
    return completer.future;
  }

  void _notifySplitTunnelConnected(SplitTunnelSettings applied) {
    // Dispatch after the current EngineNotifier turn has unwound. Reading the
    // split notifier synchronously while connect() itself is reading split
    // state would recreate the circular dependency this event is meant to
    // avoid. Keep the event best-effort for test containers being torn down.
    Future<void>.microtask(() {
      if (!ref.mounted) return;
      try {
        ref.read(splitTunnelProvider.notifier).onEngineConnected(applied);
      } catch (_) {}
    });
  }
}

final engineStateProvider = NotifierProvider<EngineNotifier, EngineState>(
  EngineNotifier.new,
);
