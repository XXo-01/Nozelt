import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// One process-wide view of whether Flutter is in the foreground. Sharing a
/// single listener keeps status polling, latency timers, and traffic events in
/// sync and avoids retaining several WidgetsBinding observers for app life.
class AppResumedNotifier extends Notifier<bool> {
  AppLifecycleListener? _listener;

  @override
  bool build() {
    _listener = AppLifecycleListener(
      onStateChange: (value) {
        if (!ref.mounted) return;
        final resumed = value == AppLifecycleState.resumed;
        if (state != resumed) state = resumed;
      },
    );
    ref.onDispose(() => _listener?.dispose());
    final current = WidgetsBinding.instance.lifecycleState;
    return current == null || current == AppLifecycleState.resumed;
  }
}

final appResumedProvider = NotifierProvider<AppResumedNotifier, bool>(
  AppResumedNotifier.new,
);
