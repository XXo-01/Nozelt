import 'package:flutter/foundation.dart';
import 'dart:ui' show PointerDeviceKind;
import 'package:flutter/services.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nozelt/main.dart';
import 'package:nozelt/src/core/app_settings.dart';
import 'package:nozelt/src/data/app_preferences.dart';
import 'package:nozelt/src/state/engine_provider.dart';
import 'package:nozelt/src/state/profiles_provider.dart';
import 'package:nozelt/src/state/node_health_provider.dart';
import 'package:nozelt/src/state/settings_provider.dart';
import 'package:nozelt/src/ui/desktop/desktop_shell.dart';
import 'package:nozelt/src/ui/desktop/logs_tab.dart';
import 'package:nozelt/src/ui/routing_profile_config_screen.dart';
import 'package:nozelt/src/ui/geo_tags_screen.dart';
import 'package:nozelt/src/ui/diagnostics_screen.dart';
import 'package:nozelt/src/ui/proxies_tab.dart' show subscriptionClock;
import 'package:nozelt/src/ui/add_profile_screen.dart';
import 'package:nozelt/src/ui/always_on_vpn_screen.dart';
import 'package:nozelt/src/ui/domain_rule_screen.dart';
import 'package:nozelt/src/ui/network_settings_screen.dart';
import 'package:nozelt/src/ui/routing_profile_settings_screen.dart';
import 'package:nozelt/src/ui/split_tunnel_screen.dart';

import 'support/ui_audit_fixtures.dart';

class _VisualAuditBinding extends AutomatedTestWidgetsFlutterBinding {
  @override
  bool get disableShadows => false;
}

void main() {
  _VisualAuditBinding();
  setUpAll(loadAuditFonts);

  Future<void> boot(
    WidgetTester tester,
    Size size, {
    TargetPlatform platform = TargetPlatform.windows,
    bool connected = true,
    double textScale = 1,
    AppThemePreference appearance = AppThemePreference.dark,
  }) async {
    debugDefaultTargetPlatformOverride = platform;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    // Pins "days left" so subscription renders do not change every day.
    subscriptionClock = () => DateTime(2026, 10, 22);
    addTearDown(() => subscriptionClock = DateTime.now);
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    tester.platformDispatcher.textScaleFactorTestValue = textScale;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    SharedPreferences.setMockInitialValues({
      'app_settings_v1': AppSettings(
        themeMode: appearance,
        pingIntervalSeconds: 0,
      ).encode(),
      'onlineGeoIpEnabled': false,
      'pingIntervalSeconds': 0,
    });
    final preferences = await SharedPreferences.getInstance();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          sharedPreferencesProvider.overrideWithValue(preferences),
          profileStoreProvider.overrideWithValue(const AuditProfileStore()),
          nozeltEngineProvider.overrideWithValue(AuditEngine()),
          engineStateProvider.overrideWith(() => AuditEngineState(connected)),
          nodeHealthProvider.overrideWith(AuditNodeHealth.new),
        ],
        child: const NozeltApp(),
      ),
    );
    await tester.pump(const Duration(milliseconds: 800));
    await loadAuditImages(tester);
  }

  Future<void> snapshot(WidgetTester tester, String name) async {
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    // Multiple toImage captures can retain text-field/FittedBox layers from
    // earlier frames. Repaint the real widget tree before exporting each state.
    void repaint(RenderObject object) {
      object.markNeedsPaint();
      object.visitChildren(repaint);
    }

    for (final view in tester.binding.renderViews) {
      repaint(view);
    }
    await tester.pump();
    expect(tester.takeException(), isNull, reason: name);
    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile('goldens/audit/$name.png'),
    );
  }

  Future<void> tab(WidgetTester tester, IconData icon) async {
    final finder = find
        .descendant(of: find.byType(DesktopShell), matching: find.byIcon(icon))
        .first;
    await tester.ensureVisible(finder);
    await tester.tap(finder);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));
  }

  Future<void> push(WidgetTester tester, Widget page) async {
    tester
        .state<NavigatorState>(find.byType(Navigator).last)
        .push(MaterialPageRoute<void>(builder: (_) => page));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));
  }

  for (final entry in {
    'normal': const Size(1180, 760),
    'compact': const Size(720, 520),
    'light_normal': const Size(1180, 760),
    'light_compact': const Size(720, 520),
  }.entries) {
    testWidgets('Visual audit of every Windows page (${entry.key})', (
      tester,
    ) async {
      await boot(
        tester,
        entry.value,
        appearance: entry.key.startsWith('light_')
            ? AppThemePreference.light
            : AppThemePreference.dark,
      );
      await snapshot(tester, '${entry.key}_home');
      final versionsTooltip = find.byWidgetPredicate(
        (widget) =>
            widget is Tooltip &&
            (widget.message?.startsWith('Nozelt ') ?? false),
      );
      tester.state<TooltipState>(versionsTooltip).ensureTooltipVisible();
      await snapshot(tester, '${entry.key}_versions_tooltip');
      Tooltip.dismissAllToolTips();
      await tester.pump(const Duration(milliseconds: 400));
      if (entry.key == 'compact') {
        tester
            .state<TooltipState>(
              find.byWidgetPredicate(
                (widget) => widget is Tooltip && widget.message == 'Настройки',
              ),
            )
            .ensureTooltipVisible();
        await snapshot(tester, 'compact_navigation_tooltip');
        Tooltip.dismissAllToolTips();
        await tester.pump(const Duration(milliseconds: 400));
      }
      await tab(tester, Icons.dns_rounded);
      await snapshot(tester, '${entry.key}_proxies');
      await tester.tap(find.byTooltip('Настройки профиля').first);
      await snapshot(tester, '${entry.key}_profile_menu');
      await tester.tap(find.text('Редактировать профиль'));
      await snapshot(tester, '${entry.key}_profile_dialog');
      await tester.tap(find.text('Отмена'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      await tester.tap(find.text('Добавить профиль').first);
      await tester.pump(const Duration(milliseconds: 400));
      await snapshot(tester, '${entry.key}_add_profile');
      await tester.tap(find.text('Ссылки').first);
      await snapshot(tester, '${entry.key}_add_links');
      await tab(tester, Icons.dns_rounded);
      await tester.tap(find.byTooltip('Настройки прокси').first);
      await tester.pump(const Duration(milliseconds: 400));
      await snapshot(tester, '${entry.key}_proxy_settings');
      await tab(tester, Icons.alt_route_rounded);
      await snapshot(tester, '${entry.key}_routing');
      await tester.tap(find.byTooltip('Действия с профилем'));
      await snapshot(tester, '${entry.key}_routing_menu');
      await tester.tapAt(const Offset(300, 10));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Процессы Windows'));
      await snapshot(tester, '${entry.key}_process_rules');
      // The persistent sidebar must also navigate away from a pushed editor.
      await tab(tester, Icons.alt_route_rounded);
      expect(find.text('steam.exe\nchrome.exe'), findsNothing);
      await tester.tap(find.text('Настройки').last);
      await snapshot(tester, '${entry.key}_routing_settings');
      await tab(tester, Icons.alt_route_rounded);
      await push(tester, const RoutingProfileConfigScreen());
      await snapshot(tester, '${entry.key}_routing_config');
      await tab(tester, Icons.alt_route_rounded);
      await push(tester, const GeoTagsScreen(kind: GeoTagKind.geoIp));
      await snapshot(tester, '${entry.key}_geo_tags');
      await tester.enterText(
        find.byKey(const ValueKey('geo-tag-search')),
        'no-such-country',
      );
      await snapshot(tester, '${entry.key}_geo_tags_empty');
      expect(find.text('Ничего не найдено'), findsOneWidget);
      await tab(tester, Icons.language_rounded);
      await snapshot(tester, '${entry.key}_connections');
      await tester.tap(find.text('chrome.exe').first);
      await snapshot(tester, '${entry.key}_connections_expanded');
      await tester.tap(find.text('Все подключения'));
      await snapshot(tester, '${entry.key}_connection_details');
      await tester.enterText(find.byType(TextField).first, 'no-match');
      await snapshot(tester, '${entry.key}_connections_filtered');
      await tab(tester, Icons.subject_rounded);
      await snapshot(tester, '${entry.key}_logs');
      await tester.enterText(
        find.descendant(
          of: find.byType(DesktopLogsTab),
          matching: find.byType(TextField),
        ),
        'no-such-message',
      );
      await snapshot(tester, '${entry.key}_logs_filtered');
      expect(find.text('Ничего не найдено'), findsOneWidget);
      await tester.tap(find.byTooltip('Очистить поиск'));
      await tester.pump();
      expect(find.text('Ничего не найдено'), findsNothing);
      await tab(tester, Icons.settings_rounded);
      await snapshot(tester, '${entry.key}_settings');
      await tester.tap(
        find.text(entry.key.startsWith('light') ? 'Светлая' : 'Тёмная').first,
      );
      await tester.pumpAndSettle();
      final menuMouse = await tester.createGesture(
        kind: PointerDeviceKind.mouse,
      );
      await menuMouse.addPointer(location: const Offset(1, 1));
      await menuMouse.moveTo(
        tester.getCenter(find.byType(PopupMenuItem<AppThemePreference>).first),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 250));
      await snapshot(tester, '${entry.key}_settings_menu_hover');
      await menuMouse.removePointer();
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(find.byType(PopupMenuItem<AppThemePreference>), findsNothing);
      final settingsScroll = find.byKey(
        const PageStorageKey<String>('settings-scroll'),
      );
      await tester.drag(settingsScroll, const Offset(0, -650));
      await tester.pump(const Duration(milliseconds: 500));
      await snapshot(tester, '${entry.key}_settings_lower');
      await tester.scrollUntilVisible(
        find.text('Настройки TUN'),
        200,
        scrollable: find
            .descendant(of: settingsScroll, matching: find.byType(Scrollable))
            .first,
      );
      await tester.tap(find.text('Настройки TUN'));
      await snapshot(tester, '${entry.key}_tun_settings');
      await tester.tap(find.text('Отмена'));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('Настройки DNS'));
      await tester.tap(find.text('Настройки DNS'));
      await snapshot(tester, '${entry.key}_dns_settings');
      await tester.tap(find.text('Отмена'));
      await push(tester, const DiagnosticsScreen());
      await snapshot(tester, '${entry.key}_diagnostics');
      await tester.pumpWidget(const SizedBox());
      debugDefaultTargetPlatformOverride = null;
    });
  }

  testWidgets('Sidebar navigation stays visible through window resize', (
    tester,
  ) async {
    await boot(tester, const Size(1180, 760));
    for (final size in [
      const Size(720, 520),
      const Size(1180, 760),
      const Size(959, 520),
      const Size(960, 520),
      const Size(720, 520),
    ]) {
      tester.view.physicalSize = size;
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 600));
      for (final icon in [
        Icons.home_rounded,
        Icons.dns_rounded,
        Icons.alt_route_rounded,
        Icons.language_rounded,
        Icons.subject_rounded,
        Icons.settings_rounded,
      ]) {
        final button = find
            .descendant(
              of: find.byType(DesktopShell),
              matching: find.byIcon(icon),
            )
            .first;
        expect(button.hitTestable(), findsOneWidget, reason: '$icon at $size');
      }
      expect(tester.takeException(), isNull);
      // Capture the actual retained sidebar layer after resizing, without the
      // forced full-tree repaint used by the general screenshot exporter.
      final label = switch (size.width.toInt()) {
        720 => 'minimum',
        1180 => 'wide',
        959 => 'before_breakpoint',
        _ => 'after_breakpoint',
      };
      await expectLater(
        find.byKey(const ValueKey('desktop-sidebar')),
        matchesGoldenFile('goldens/audit/resize_sidebar_$label.png'),
      );
    }
    await tester.pumpWidget(const SizedBox());
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('Desktop large text and high DPI layout', (tester) async {
    await boot(tester, const Size(1440, 960), textScale: 1.25);
    tester.view.devicePixelRatio = 1.25;
    await snapshot(tester, 'scaled_home');
    for (final page in [
      (Icons.dns_rounded, 'proxies'),
      (Icons.alt_route_rounded, 'routing'),
      (Icons.language_rounded, 'connections'),
      (Icons.subject_rounded, 'logs'),
      (Icons.settings_rounded, 'settings'),
    ]) {
      await tab(tester, page.$1);
      await snapshot(tester, 'scaled_${page.$2}');
    }
    await tester.pumpWidget(const SizedBox());
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('Minimum window remains usable with enlarged text', (
    tester,
  ) async {
    await boot(tester, const Size(720, 520), textScale: 1.25);
    await snapshot(tester, 'text_home');
    for (final page in [
      (Icons.dns_rounded, 'proxies'),
      (Icons.alt_route_rounded, 'routing'),
      (Icons.language_rounded, 'connections'),
      (Icons.subject_rounded, 'logs'),
      (Icons.settings_rounded, 'settings'),
    ]) {
      await tab(tester, page.$1);
      await snapshot(tester, 'text_${page.$2}');
    }
    await tester.pumpWidget(const SizedBox());
    debugDefaultTargetPlatformOverride = null;
  });

  for (final appearance in [
    AppThemePreference.dark,
    AppThemePreference.light,
  ]) {
    testWidgets(
      'Android visual reference for the shared screens ${appearance.name}',
      (tester) async {
        await boot(
          tester,
          const Size(412, 915),
          platform: TargetPlatform.android,
          connected: false,
          appearance: appearance,
        );
        final prefix = appearance == AppThemePreference.light
            ? 'light_android'
            : 'android';
        await snapshot(tester, '${prefix}_home');
        for (final page in [
          (Icons.dns_rounded, 'proxies'),
          (Icons.alt_route_rounded, 'routing'),
          (Icons.settings_rounded, 'settings'),
        ]) {
          await tester.tap(find.byIcon(page.$1).first);
          await tester.pump(const Duration(milliseconds: 400));
          await snapshot(tester, '${prefix}_${page.$2}');
        }
        if (appearance == AppThemePreference.dark) {
          // Secondary Android screens, so phone-only controls are reviewed
          // with the same design pass as Windows.
          for (final page in <(String, Widget)>[
            ('add_profile', const AddProfileScreen()),
            ('always_on', const AlwaysOnVpnScreen()),
            ('diagnostics', const DiagnosticsScreen()),
            ('domain_rule', const DomainRuleScreen()),
            ('dns_settings', const NetworkSettingsScreen(dns: true)),
            ('tun_settings', const NetworkSettingsScreen(dns: false)),
            ('routing_settings', const RoutingProfileSettingsScreen()),
            ('split_tunnel', const SplitTunnelScreen()),
          ]) {
            await push(tester, page.$2);
            await snapshot(tester, 'android_${page.$1}');
            tester.state<NavigatorState>(find.byType(Navigator).last).pop();
            await tester.pump();
            await tester.pump(const Duration(milliseconds: 600));
          }
        }
        await tester.pumpWidget(const SizedBox());
        debugDefaultTargetPlatformOverride = null;
      },
    );
  }
}
