import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nozelt/main.dart';
import 'package:nozelt/nozelt_design_system.dart';
import 'package:nozelt/src/core/app_settings.dart';
import 'package:nozelt/src/core/models.dart';
import 'package:nozelt/src/data/app_preferences.dart';
import 'package:nozelt/src/state/engine_provider.dart';
import 'package:nozelt/src/state/node_health_provider.dart';
import 'package:nozelt/src/state/profiles_provider.dart';
import 'package:nozelt/src/state/settings_provider.dart';
import 'package:nozelt/src/ui/settings_tab.dart';
import 'package:nozelt/src/ui/add_profile_screen.dart';
import 'support/ui_audit_fixtures.dart';

void main() {
  test(
    'Legacy appearance stays dark; theme survives round trip without touching connection options',
    () {
      expect(AppSettings.decode('{}').themeMode, AppThemePreference.dark);
      expect(
        AppSettings.decode('{"themeMode":"unknown"}').themeMode,
        AppThemePreference.dark,
      );
      final settings = const AppSettings(
        autoConnectEnabled: true,
        silentStart: true,
      ).copyWith(themeMode: AppThemePreference.light);
      final restored = AppSettings.decode(settings.encode());
      expect(restored.themeMode, AppThemePreference.light);
      expect(restored.autoConnectEnabled, isTrue);
      expect(restored.silentStart, isTrue);
    },
  );
  for (final connected in [false, true]) {
    testWidgets(
      'Actual Settings switches appearance and saves it (VPN=$connected)',
      (tester) async {
        SharedPreferences.setMockInitialValues({});
        final preferences = await SharedPreferences.getInstance();
        final container = ProviderContainer(
          overrides: [
            sharedPreferencesProvider.overrideWithValue(preferences),
            profileStoreProvider.overrideWithValue(const AuditProfileStore()),
            nozeltEngineProvider.overrideWithValue(AuditEngine()),
            engineStateProvider.overrideWith(() => AuditEngineState(connected)),
            nodeHealthProvider.overrideWith(AuditNodeHealth.new),
          ],
        );
        addTearDown(container.dispose);
        await tester.pumpWidget(
          UncontrolledProviderScope(
            container: container,
            child: const NozeltApp(),
          ),
        );
        await tester.pumpAndSettle();
        final navigator = tester.state<NavigatorState>(
          find.byType(Navigator).last,
        );
        navigator.push(
          MaterialPageRoute<void>(
            builder: (_) => const Scaffold(body: SettingsTab()),
          ),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.text('Тёмная').first);
        await tester.pumpAndSettle();
        await tester.tap(find.text('Светлая').last);
        await tester.pumpAndSettle();
        expect(
          Theme.of(tester.element(find.byType(SettingsTab))).brightness,
          Brightness.light,
        );
        expect(
          AppSettings.decode(
            preferences.getString('app_settings_v1')!,
          ).themeMode,
          AppThemePreference.light,
        );
        expect(
          container.read(engineStateProvider).connection,
          connected
              ? EngineConnectionState.connected
              : EngineConnectionState.disconnected,
        );
        await tester.tap(find.text('Светлая').first);
        await tester.pumpAndSettle();
        await tester.tap(find.text('Системная').last);
        await tester.pumpAndSettle();
        tester.platformDispatcher.platformBrightnessTestValue = Brightness.dark;
        await tester.pumpAndSettle();
        expect(
          Theme.of(tester.element(find.byType(SettingsTab))).brightness,
          Brightness.dark,
        );
        tester.platformDispatcher.platformBrightnessTestValue =
            Brightness.light;
        await tester.pumpAndSettle();
        expect(
          Theme.of(tester.element(find.byType(SettingsTab))).brightness,
          Brightness.light,
        );
        tester.platformDispatcher.clearPlatformBrightnessTestValue();
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );
  }
  for (final platform in [TargetPlatform.windows, TargetPlatform.android]) {
    testWidgets('Input borders match core segments on ${platform.name}', (
      tester,
    ) async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      await tester.pumpWidget(
        ProviderScope(
          overrides: [sharedPreferencesProvider.overrideWithValue(prefs)],
          child: MaterialApp(
            theme: NozeltTheme.forPlatform(platform),
            locale: const Locale('ru'),
            supportedLocales: const [Locale('ru'), Locale('en')],
            localizationsDelegates: GlobalMaterialLocalizations.delegates,
            home: const AddProfileScreen(),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final goal = platform == TargetPlatform.windows ? 44.0 : 48.0;
      for (final element in find.byType(EditableText).evaluate()) {
        final box = InputDecorator.containerOf(element)!;
        expect(
          box.size.height,
          closeTo(goal, 1),
          reason: 'Actual painted input container, not outer widget bounds',
        );
      }
      final dropdown = tester.element(find.text('Ежедневно').first);
      expect(
        InputDecorator.containerOf(dropdown)!.size.height,
        closeTo(goal, 1),
      );
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }
}
