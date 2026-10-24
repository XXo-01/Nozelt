import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/app_settings.dart';
import '../core/windows_shell_bridge.dart';
import 'settings_provider.dart';

const _key = 'app_settings_v1';
const _nativeChannel = MethodChannel('dev.nozelt.nozelt/engine');

class AppSettingsNotifier extends Notifier<AppSettings> {
  Future<void> _persistTail = Future<void>.value();
  Future<void> _nativeTail = Future<void>.value();
  int _settingsRevision = 0;
  Future<void> _startupTail = Future<void>.value();

  @override
  AppSettings build() {
    final raw = ref.watch(sharedPreferencesProvider).getString(_key);
    AppSettings value;
    if (raw == null) {
      value = const AppSettings();
    } else {
      try {
        value = AppSettings.decode(raw);
      } catch (_) {
        value = const AppSettings();
      }
    }
    if (defaultTargetPlatform == TargetPlatform.android) {
      value = value.copyWith(
        pingIntervalSeconds:
            value.pingIntervalSeconds > 0 && value.pingIntervalSeconds < 10
            ? 60
            : value.pingIntervalSeconds,
        onlineGeoIpEnabled: true,
      );
    } else if (defaultTargetPlatform == TargetPlatform.windows) {
      value = value.copyWith(
        pingIntervalSeconds: AppSettings.normalizeDesktopPingInterval(
          value.pingIntervalSeconds,
        ),
      );
    }
    unawaited(_enqueueNativeLanguage(value.languageCode));
    return value;
  }

  Future<void> setLanguage(String code) async {
    final next = state.copyWith(languageCode: code == 'en' ? 'en' : 'ru');
    await _update(next);
    if (!ref.mounted) return;
    // Synchronize the language that actually survived persistence. A failed
    // SharedPreferences write rolls state back below, so the foreground
    // service must not keep a different notification locale until restart.
    await _enqueueNativeLanguage(state.languageCode);
  }

  Future<void> setThemeMode(AppThemePreference value) async {
    await _update(state.copyWith(themeMode: value));
  }

  Future<void> _enqueueNativeLanguage(String code) {
    final operation = _nativeTail.then((_) => _syncNativeLanguage(code));
    _nativeTail = operation.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    return operation;
  }

  Future<void> _syncNativeLanguage(String code) async {
    if (defaultTargetPlatform != TargetPlatform.android) return;
    try {
      await _nativeChannel.invokeMethod<bool>('setPreferredLanguage', {
        'code': code,
      });
    } catch (_) {
      // Unit tests and non-embedded startup can have no platform handler.
    }
  }

  Future<void> setPingInterval(int seconds) async {
    final normalized = switch (defaultTargetPlatform) {
      TargetPlatform.android =>
        seconds == 0
            ? 0
            : seconds < 10
            ? 10
            : AppSettings.normalizePingInterval(seconds),
      TargetPlatform.windows => AppSettings.normalizeDesktopPingInterval(
        seconds,
      ),
      _ => AppSettings.normalizePingInterval(seconds),
    };
    await _update(state.copyWith(pingIntervalSeconds: normalized));
  }

  Future<void> setOnlineGeoIp(bool enabled) async {
    await _update(state.copyWith(onlineGeoIpEnabled: enabled));
  }

  Future<void> setAutoConnect(bool enabled) async {
    await _update(state.copyWith(autoConnectEnabled: enabled));
  }

  Future<void> setTrayClickAction(TrayClickAction action) async {
    await _update(state.copyWith(trayClickAction: action));
  }

  Future<void> setStartWithWindows(bool enabled) =>
      _setStartup(enabled: enabled);
  Future<void> setSilentStart(bool enabled) => _setStartup(silent: enabled);

  Future<void> _setStartup({bool? enabled, bool? silent}) {
    final operation = _startupTail.then((_) async {
      if (!ref.mounted) return;
      final previous = state;
      final next = previous.copyWith(
        startWithWindows: enabled,
        silentStart: silent,
      );
      await WindowsShellBridge.instance.configureStartup(
        enabled: next.startWithWindows,
        silent: next.silentStart,
      );
      if (!ref.mounted ||
          !await _update(
            state.copyWith(
              startWithWindows: next.startWithWindows,
              silentStart: next.silentStart,
            ),
          )) {
        await WindowsShellBridge.instance.configureStartup(
          enabled: previous.startWithWindows,
          silent: previous.silentStart,
        );
        throw StateError('Could not persist startup settings.');
      }
    });
    _startupTail = operation.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    return operation;
  }

  Future<bool> _update(AppSettings next) {
    final previous = state;
    final preferences = ref.read(sharedPreferencesProvider);
    state = next;
    final revision = ++_settingsRevision;
    final operation = _persistTail.then((_) async {
      try {
        final saved = await preferences.setString(_key, next.encode());
        if (!saved) throw StateError('Could not persist app settings.');
        return true;
      } catch (_) {
        // UI callbacks intentionally do not await these futures. Contain the
        // storage failure here and restore only if no newer user edit has
        // superseded this snapshot.
        if (ref.mounted && _settingsRevision == revision) {
          _settingsRevision++;
          state = previous;
        }
        return false;
      }
    });
    _persistTail = operation.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    return operation;
  }
}

final appSettingsProvider = NotifierProvider<AppSettingsNotifier, AppSettings>(
  AppSettingsNotifier.new,
);
