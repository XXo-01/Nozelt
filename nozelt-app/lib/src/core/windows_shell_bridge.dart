import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Small, dependency-free bridge to the Win32 runner. The runner owns the
/// notification-area icon so it remains responsive even while Flutter is
/// rebuilding a large page.
class WindowsShellBridge {
  WindowsShellBridge._();

  static final WindowsShellBridge instance = WindowsShellBridge._();
  static const _channel = MethodChannel('dev.nozelt.nozelt/windows_shell');

  Future<void> initialize({
    required Future<void> Function() onToggleRequested,
    required Future<void> Function() onExitRequested,
    Future<void> Function()? onRestartRequested,
    Future<void> Function(String mode)? onRoutingModeRequested,
  }) async {
    if (defaultTargetPlatform != TargetPlatform.windows) return;
    _channel.setMethodCallHandler((call) async {
      switch (call.method) {
        case 'trayToggleRequested':
          await onToggleRequested();
        case 'trayExitRequested':
          await onExitRequested();
        case 'trayRestartRequested':
          await onRestartRequested?.call();
        case 'trayRoutingModeRequested':
          if (call.arguments is String) {
            await onRoutingModeRequested?.call(call.arguments as String);
          }
      }
    });
  }

  Future<void> update({
    required bool connected,
    bool protectionActive = false,
    required String clickAction,
    required String languageCode,
    String routingMode = 'rule',
  }) async {
    if (defaultTargetPlatform != TargetPlatform.windows) return;
    try {
      await _channel.invokeMethod<void>('setState', {
        'connected': connected,
        'protectionActive': protectionActive,
        'clickAction': clickAction,
        'languageCode': languageCode,
        'routingMode': routingMode,
      });
    } on MissingPluginException {
      // Unit/widget tests do not host the Win32 runner.
    }
  }

  Future<void> configureStartup({
    required bool enabled,
    required bool silent,
  }) async {
    if (defaultTargetPlatform != TargetPlatform.windows) return;
    await _channel.invokeMethod<void>('configureStartup', {
      'enabled': enabled,
      'silent': silent,
    });
  }

  Future<void> requestRestart({bool resumeTun = false}) async {
    if (defaultTargetPlatform != TargetPlatform.windows) return;
    await _channel.invokeMethod<void>('requestRestart', {
      'resumeTun': resumeTun,
    });
  }

  Future<void> requestExit() async {
    if (defaultTargetPlatform != TargetPlatform.windows) return;
    try {
      await _channel.invokeMethod<void>('requestExit');
    } on MissingPluginException {
      // No native host in tests.
    }
  }
}
