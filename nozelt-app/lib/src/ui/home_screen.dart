import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/models.dart';
import '../state/app_lifecycle_provider.dart';
import '../state/engine_provider.dart';
import '../state/profiles_provider.dart';
import 'home_tab.dart';
import 'desktop/connections_tab.dart';
import 'desktop/desktop_home_tab.dart';
import 'desktop/desktop_shell.dart';
import 'desktop/logs_tab.dart';
import 'proxies_tab.dart';
import 'routing_tab.dart';
import 'settings_tab.dart';
import 'widgets/nozelt_ui.dart';

/// Root application shell. The IndexedStack keeps tab state alive while the
/// floating bottom bar mirrors Telegram's compact Android navigation pattern.
class HomeScreen extends ConsumerStatefulWidget {
  const HomeScreen({super.key});

  @override
  ConsumerState<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends ConsumerState<HomeScreen> {
  int _index = 0;
  final Set<int> _builtTabs = {0};
  String? _lastShownError;
  Timer? _staleRefreshTimer;
  Timer? _subscriptionMaintenanceTimer;

  bool get _desktop => defaultTargetPlatform == TargetPlatform.windows;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      // Subscription refresh is maintenance work, not a first-frame
      // prerequisite. Deferring it prevents network/native initialization from
      // competing with a cold start.
      _scheduleStaleRefresh();
      _subscriptionMaintenanceTimer = Timer.periodic(
        const Duration(minutes: 15),
        (_) {
          if (!mounted) return;
          if (ref.read(appResumedProvider)) _runStaleRefresh();
        },
      );
    });
  }

  @override
  void dispose() {
    _staleRefreshTimer?.cancel();
    _subscriptionMaintenanceTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    ref.listen<bool>(appResumedProvider, (previous, resumed) {
      if (resumed && previous == false) _scheduleStaleRefresh();
    });
    ref.listen(
      engineStateProvider.select(
        (state) =>
            (connection: state.connection, errorMessage: state.errorMessage),
      ),
      (previous, next) {
        if (next.connection == EngineConnectionState.connected &&
            previous?.connection != EngineConnectionState.connected) {
          // Background subscription maintenance is privacy-sensitive: wait for
          // Nozelt's own UID to be inside the VPN instead of contacting the
          // provider directly during a disconnected cold start.
          _scheduleStaleRefresh();
        }
        if (next.connection == EngineConnectionState.error &&
            next.errorMessage != null &&
            next.errorMessage != _lastShownError) {
          _lastShownError = next.errorMessage;
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(SnackBar(content: Text(next.errorMessage!)));
        } else if (next.connection != EngineConnectionState.error) {
          _lastShownError = null;
        }
      },
    );

    final tabs = IndexedStack(
      index: _index,
      children: List.generate(_desktop ? 6 : 4, _buildTab),
    );
    if (_desktop) {
      return Scaffold(
        body: DesktopShell(index: _index, onChanged: _select, child: tabs),
      );
    }
    return Scaffold(
      extendBody: true,
      body: tabs,
      bottomNavigationBar: NozeltBottomBar(index: _index, onChanged: _select),
    );
  }

  void _scheduleStaleRefresh() {
    if (!mounted) return;
    _staleRefreshTimer?.cancel();
    _staleRefreshTimer = Timer(const Duration(seconds: 2), _runStaleRefresh);
  }

  Future<void> _runStaleRefresh() async {
    if (!mounted) return;
    if (ref.read(engineStateProvider).connection !=
        EngineConnectionState.connected) {
      return;
    }
    try {
      await ref.read(profilesProvider.future);
      if (!mounted) return;
      await ref.read(profilesProvider.notifier).refreshStale();
    } catch (_) {
      // Best-effort subscription refresh; offline startup/resume is valid.
    }
  }

  void _select(int value) {
    if (_index == value) return;
    setState(() {
      _index = value;
      _builtTabs.add(value);
    });
  }

  Widget _buildTab(int index) {
    if (!_builtTabs.contains(index)) return const SizedBox.shrink();
    if (_desktop) {
      return switch (index) {
        0 => DesktopHomeTab(onOpenProxies: () => _select(1)),
        1 => const ProxiesTab(),
        2 => RoutingTab(isVisible: _index == 2),
        3 => DesktopConnectionsTab(isVisible: _index == 3),
        4 => DesktopLogsTab(isVisible: _index == 4),
        _ => const SettingsTab(),
      };
    }
    return switch (index) {
      0 => HomeTab(onOpenProxies: () => _select(1), isVisible: _index == 0),
      1 => ProxiesTab(isVisible: _index == 1),
      2 => RoutingTab(isVisible: _index == 2),
      _ => SettingsTab(isVisible: _index == 3),
    };
  }
}
