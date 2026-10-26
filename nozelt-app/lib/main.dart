import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'src/data/secure_settings_store.dart';
import 'src/data/app_preferences.dart';
import 'src/data/sensitive_settings_repository.dart';
import 'src/data/runtime_rollback_journal.dart';
import 'src/core/models.dart';
import 'src/core/app_settings.dart';
import 'src/core/windows_shell_bridge.dart';
import 'src/core/tun_settings.dart';
import 'src/state/routing_config_controller.dart';
import 'src/state/app_settings_provider.dart';
import 'src/state/app_update_provider.dart';
import 'src/state/engine_provider.dart';
import 'src/state/geo_data_update_provider.dart';
import 'src/state/routing_link_provider.dart';
import 'src/state/nozelt_auto_provider.dart';
import 'src/state/settings_provider.dart';
import 'src/ui/home_screen.dart';
import 'src/ui/nozelt_theme.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // This platform call does not affect dependency loading. Let the first
  // Flutter frame race it instead of showing the native launch screen longer.
  unawaited(SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge));
  SystemChrome.setSystemUIOverlayStyle(
    const SystemUiOverlayStyle(
      statusBarColor: Colors.transparent,
      statusBarIconBrightness: Brightness.light,
      systemNavigationBarColor: NozeltColors.background,
      systemNavigationBarIconBrightness: Brightness.light,
    ),
  );
  // Paint a real Flutter frame immediately. Android Keystore can take longer
  // to become available after device unlock; waiting here would leave the
  // native launch screen looking frozen even though the process is healthy.
  runApp(const _NozeltBootstrap());
}

class _BootstrapData {
  const _BootstrapData(this.preferences, this.sensitiveSettings);

  final SharedPreferences preferences;
  final SensitiveSettingsRepository sensitiveSettings;
}

class _NozeltBootstrap extends StatefulWidget {
  const _NozeltBootstrap();

  @override
  State<_NozeltBootstrap> createState() => _NozeltBootstrapState();
}

class _NozeltBootstrapState extends State<_NozeltBootstrap> {
  late Future<_BootstrapData> _future = _load();

  Future<_BootstrapData> _load() async {
    // Android preferences and Keystore data are independent platform reads.
    // Starting both before awaiting either removes one native round trip from
    // the critical startup chain.
    final preferencesFuture = SharedPreferences.getInstance();
    final startupValues = await Future.wait<Object?>([
      loadSensitiveSettingsRepository(preferencesFuture),
      if (defaultTargetPlatform == TargetPlatform.android)
        readNativeRuntimeRollback()
      else
        Future<Map<String, dynamic>?>.value(),
    ]);
    final sensitiveSettings = startupValues[0] as SensitiveSettingsRepository;
    final preferences = await preferencesFuture;
    if (defaultTargetPlatform == TargetPlatform.android) {
      await restoreNativeRuntimeRollback(
        sensitiveSettings,
        initialJournal: startupValues[1] as Map<String, dynamic>?,
        initialJournalWasRead: true,
      );
    }
    return _BootstrapData(preferences, sensitiveSettings);
  }

  void _retry() => setState(() => _future = _load());

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<_BootstrapData>(
      future: _future,
      builder: (context, snapshot) {
        final data = snapshot.data;
        if (data != null) {
          return ProviderScope(
            overrides: [
              sharedPreferencesProvider.overrideWithValue(data.preferences),
              sensitiveSettingsRepositoryProvider.overrideWithValue(
                data.sensitiveSettings,
              ),
            ],
            child: const NozeltApp(),
          );
        }
        return MaterialApp(
          debugShowCheckedModeBanner: false,
          themeMode: ThemeMode.dark,
          theme: NozeltTheme.dark,
          darkTheme: NozeltTheme.dark,
          home: Scaffold(
            backgroundColor: NozeltColors.background,
            body: Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Image.asset(
                    'assets/branding/nozelt_new_logo.png',
                    width: 120,
                    height: 120,
                    errorBuilder: (_, _, _) => const Icon(
                      Icons.shield_rounded,
                      size: 72,
                      color: NozeltColors.primary,
                    ),
                  ),
                  const SizedBox(height: 24),
                  if (snapshot.hasError)
                    Column(
                      children: [
                        Text(
                          WidgetsBinding
                                      .instance
                                      .platformDispatcher
                                      .locale
                                      .languageCode ==
                                  'ru'
                              ? 'Не удалось восстановить состояние VPN'
                              : 'Could not restore VPN state',
                          textAlign: TextAlign.center,
                        ),
                        const SizedBox(height: 12),
                        IconButton.filledTonal(
                          tooltip: 'Retry',
                          onPressed: _retry,
                          icon: const Icon(Icons.refresh_rounded),
                        ),
                      ],
                    )
                  else
                    const SizedBox.square(
                      dimension: 24,
                      child: CircularProgressIndicator(strokeWidth: 2.5),
                    ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

class NozeltApp extends ConsumerWidget {
  const NozeltApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    ref.watch(geoDataUpdateCoordinatorProvider);
    ref.watch(routingLinkCoordinatorProvider);
    // Kept alive without rebuilding the app when a measurement starts.
    ref.listen(nozeltAutoServerProvider, (_, _) {});
    // Checks GitHub Releases on start and every few hours.
    ref.listen(appUpdateProvider, (_, _) {});
    // Only locale and appearance need to rebuild MaterialApp. Ping intervals,
    // autoconnect and other settings stay below the root navigator.
    final languageCode = ref.watch(
      appSettingsProvider.select((settings) => settings.languageCode),
    );
    final appearance = ref.watch(
      appSettingsProvider.select((settings) => settings.themeMode),
    );
    return MaterialApp(
      title: 'Nozelt',
      debugShowCheckedModeBanner: false,
      themeMode: switch (appearance) {
        AppThemePreference.dark => ThemeMode.dark,
        AppThemePreference.light => ThemeMode.light,
        AppThemePreference.system => ThemeMode.system,
      },
      theme: NozeltTheme.light,
      darkTheme: NozeltTheme.dark,
      locale: Locale(languageCode),
      builder: (context, child) {
        final dark = Theme.of(context).brightness == Brightness.dark;
        return AnnotatedRegion<SystemUiOverlayStyle>(
          value: SystemUiOverlayStyle(
            statusBarColor: Colors.transparent,
            statusBarIconBrightness: dark ? Brightness.light : Brightness.dark,
            systemNavigationBarColor: Theme.of(context).scaffoldBackgroundColor,
            systemNavigationBarIconBrightness: dark
                ? Brightness.light
                : Brightness.dark,
          ),
          child: child!,
        );
      },
      supportedLocales: const [Locale('ru'), Locale('en')],
      localizationsDelegates: const [
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      home: const _WindowsShellCoordinator(child: HomeScreen()),
    );
  }
}

class _WindowsShellCoordinator extends ConsumerStatefulWidget {
  const _WindowsShellCoordinator({required this.child});

  final Widget child;

  @override
  ConsumerState<_WindowsShellCoordinator> createState() =>
      _WindowsShellCoordinatorState();
}

class _WindowsShellCoordinatorState
    extends ConsumerState<_WindowsShellCoordinator> {
  @override
  void initState() {
    super.initState();
    if (defaultTargetPlatform == TargetPlatform.windows) {
      WidgetsBinding.instance.addPostFrameCallback((_) async {
        await WindowsShellBridge.instance.initialize(
          onToggleRequested: _toggleTun,
          onExitRequested: _exit,
          onRestartRequested: _restart,
          onRoutingModeRequested: (mode) => ref
              .read(routingConfigControllerProvider)
              .setMode(
                mode == 'global' ? RoutingMode.global : RoutingMode.rule,
              ),
        );
        await _syncTray();
      });
    }
  }

  Future<void> _toggleTun() async {
    final state = ref.read(engineStateProvider);
    final connection = state.connection;
    final notifier = ref.read(engineStateProvider.notifier);
    if (connection == EngineConnectionState.connected ||
        connection == EngineConnectionState.connecting ||
        state.status.networkGuard) {
      await notifier.disconnect();
    } else if (connection != EngineConnectionState.disconnecting) {
      await notifier.connect();
    }
  }

  Future<void> _exit() async {
    await stopVpnForExit(ref.read);
    await WindowsShellBridge.instance.requestExit();
  }

  Future<void> _restart() async {
    final engine = ref.read(nozeltEngineProvider);
    final status = await engine.getStatus();
    final resume = status.running || status.networkGuard;
    await engine.prepareWindowsAppRestart();
    try {
      await WindowsShellBridge.instance.requestRestart(resumeTun: resume);
    } catch (_) {
      if (resume) await engine.restart();
    }
  }

  Future<void> _syncTray() => WindowsShellBridge.instance.update(
    protectionActive: ref.read(engineStateProvider).status.networkGuard,
    connected:
        ref.read(engineStateProvider).connection ==
        EngineConnectionState.connected,
    clickAction: ref.read(appSettingsProvider).trayClickAction.wire,
    languageCode: ref.read(appSettingsProvider).languageCode,
    routingMode: ref.read(tunSettingsProvider).routingMode.name,
  );

  @override
  Widget build(BuildContext context) {
    if (defaultTargetPlatform == TargetPlatform.windows) {
      ref.listen(
        tunSettingsProvider.select((value) => value.routingMode),
        (_, _) => _syncTray(),
      );
      ref.listen(
        engineStateProvider.select((value) => value.connection),
        (_, _) => _syncTray(),
      );
      ref.listen(
        appSettingsProvider.select(
          (value) => (value.trayClickAction, value.languageCode),
        ),
        (_, _) => _syncTray(),
      );
    }
    return widget.child;
  }
}
