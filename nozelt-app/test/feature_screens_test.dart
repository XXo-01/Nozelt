import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nozelt/main.dart';
import 'package:nozelt/src/core/app_metadata.dart';
import 'package:nozelt/src/core/app_settings.dart';
import 'package:nozelt/src/core/app_update.dart';
import 'package:nozelt/src/core/profile.dart';
import 'package:nozelt/src/data/app_preferences.dart';
import 'package:nozelt/src/data/profile_store.dart';
import 'package:nozelt/src/state/app_update_provider.dart';
import 'package:nozelt/src/state/engine_provider.dart';
import 'package:nozelt/src/state/node_health_provider.dart';
import 'package:nozelt/src/state/profiles_provider.dart';
import 'package:nozelt/src/state/settings_provider.dart';
import 'package:nozelt/src/ui/proxies_tab.dart' show subscriptionClock;

import 'support/ui_audit_fixtures.dart';

/// Reference screens of the 1.1.0 features: the server menu, the "Deleted"
/// section and the update banners, on Windows and Android, dark and light.

class _Binding extends AutomatedTestWidgetsFlutterBinding {
  @override
  bool get disableShadows => false;
}

class _MarkedProfileStore extends ProfileStore {
  const _MarkedProfileStore();

  @override
  Future<ProfilesState> load() async {
    final base = auditProfiles();
    final primary = base.profiles.first;
    return base.copyWith(
      profiles: [
        primary.copyWith(
          pinnedNodeNames: {primary.nodes[2].name},
          deletedNodeNames: {primary.nodes[1].name},
        ),
        ...base.profiles.skip(1),
      ],
    );
  }

  @override
  Future<void> save(ProfilesState state) async {}
}

class _AvailableUpdate extends AppUpdateNotifier {
  @override
  AppUpdateState build() => AppUpdateState(
    release: AppRelease.fromGitHubJson(const {
      'tag_name': 'v1.2.0',
      'html_url': 'https://github.com/XXo-01/Nozelt/releases/tag/v1.2.0',
      'assets': [],
    }),
  );
}

void main() {
  _Binding();
  setUpAll(loadAuditFonts);

  Future<void> boot(
    WidgetTester tester,
    Size size,
    TargetPlatform platform,
    AppThemePreference appearance,
  ) async {
    debugDefaultTargetPlatformOverride = platform;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    subscriptionClock = () => DateTime(2026, 10, 22);
    addTearDown(() => subscriptionClock = DateTime.now);
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    SharedPreferences.setMockInitialValues({
      'app_settings_v1': AppSettings(
        themeMode: appearance,
        pingIntervalSeconds: 0,
      ).encode(),
    });
    final preferences = await SharedPreferences.getInstance();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          sharedPreferencesProvider.overrideWithValue(preferences),
          profileStoreProvider.overrideWithValue(const _MarkedProfileStore()),
          nozeltEngineProvider.overrideWithValue(AuditEngine()),
          engineStateProvider.overrideWith(() => AuditEngineState(false)),
          nodeHealthProvider.overrideWith(AuditNodeHealth.new),
          appUpdateProvider.overrideWith(_AvailableUpdate.new),
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
    expect(tester.takeException(), isNull, reason: name);
    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile('goldens/v110/$name.png'),
    );
  }

  for (final platform in [TargetPlatform.windows, TargetPlatform.android]) {
    for (final appearance in [
      AppThemePreference.dark,
      AppThemePreference.light,
    ]) {
      final windows = platform == TargetPlatform.windows;
      final prefix = '${windows ? 'windows' : 'android'}_${appearance.name}';
      testWidgets('1.1.0 screens $prefix', (tester) async {
        await boot(
          tester,
          windows ? const Size(1180, 760) : const Size(412, 915),
          platform,
          appearance,
        );
        expect(find.text('Доступна версия 1.2.0'), findsOneWidget);
        expect(find.text('Не предлагать обновления'), findsOneWidget);
        await snapshot(tester, '${prefix}_home_banner');

        await tester.tap(find.byIcon(Icons.dns_rounded).first);
        await tester.pump(const Duration(milliseconds: 600));
        // The deleted server is hidden until the section is opened.
        expect(find.text('Финляндия | Хельсинки'), findsNothing);
        await tester.scrollUntilVisible(
          find.text('Удалённые'),
          200,
          scrollable: find.byType(Scrollable).first,
        );
        await tester.tap(find.text('Удалённые'));
        await tester.pump(const Duration(milliseconds: 400));
        await tester.scrollUntilVisible(
          find.text('Финляндия | Хельсинки'),
          200,
          scrollable: find.byType(Scrollable).first,
        );
        await tester.pump(const Duration(milliseconds: 400));
        await snapshot(tester, '${prefix}_proxies_deleted');

        // The menu of the deleted server: the button on its row.
        final rowY = tester.getCenter(find.text('Финляндия | Хельсинки')).dy;
        final menus = find.byTooltip('Действия с прокси');
        var closest = 0;
        for (var i = 0; i < menus.evaluate().length; i++) {
          final dy = (tester.getCenter(menus.at(i)).dy - rowY).abs();
          if (dy < (tester.getCenter(menus.at(closest)).dy - rowY).abs()) {
            closest = i;
          }
        }
        await tester.tap(menus.at(closest));
        await tester.pump(const Duration(milliseconds: 600));
        expect(find.text('Настройки прокси'), findsOneWidget);
        expect(find.text('Закрепить'), findsOneWidget);
        expect(find.text('Восстановить'), findsOneWidget);
        await snapshot(tester, '${prefix}_proxy_menu');
        await tester.sendKeyEvent(LogicalKeyboardKey.escape);
        await tester.pump(const Duration(milliseconds: 600));

        await tester.tap(find.byIcon(Icons.settings_rounded).first);
        await tester.pump(const Duration(milliseconds: 600));
        await tester.scrollUntilVisible(
          find.text('Версия ${AppMetadata.version}'),
          300,
          scrollable: find.byType(Scrollable).first,
        );
        await tester.drag(find.byType(Scrollable).first, const Offset(0, -400));
        await tester.pump(const Duration(milliseconds: 600));
        expect(find.text('Обновить'), findsOneWidget);
        await snapshot(tester, '${prefix}_settings_banner');

        await tester.pumpWidget(const SizedBox());
        debugDefaultTargetPlatformOverride = null;
      });
    }
  }
}
