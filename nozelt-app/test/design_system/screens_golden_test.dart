import 'package:alchemist/alchemist.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nozelt/src/data/app_preferences.dart';
import 'package:nozelt/src/state/engine_provider.dart';
import 'package:nozelt/src/state/settings_provider.dart';
import 'package:nozelt/src/ui/add_profile_screen.dart';
import 'package:nozelt/src/ui/settings_tab.dart';
import 'package:nozelt/src/ui/network_settings_screen.dart';
import 'package:nozelt/src/ui/design_system/nozelt_design_system.dart';
import '../support/ui_audit_fixtures.dart';
import 'package:nozelt/nozelt_design_system_preview.dart';
import 'golden_config.dart';

void main() {
  late SharedPreferences preferences;
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    preferences = await SharedPreferences.getInstance();
  });
  tearDown(() => debugDefaultTargetPlatformOverride = null);

  for (final platform in [TargetPlatform.windows, TargetPlatform.android]) {
    for (final brightness in Brightness.values) {
      AlchemistConfig.runWithConfig(
        config: nozeltGoldenConfig(
          NozeltTheme.forPlatform(platform, brightness: brightness),
        ),
        run: () {
          for (final size
              in platform == TargetPlatform.windows
                  ? [const Size(720, 520), const Size(1180, 760)]
                  : [const Size(360, 800)]) {
            for (final mode in ['subscription', 'links', 'file']) {
              goldenTest(
                'Add profile ${platform.name} ${brightness.name} ${size.width}',
                fileName:
                    'add_profile_${platform.name}_${brightness.name}_${size.width.toInt()}${mode == 'subscription' ? '' : '_$mode'}',
                builder: () {
                  debugDefaultTargetPlatformOverride = platform;
                  return Localizations(
                    locale: const Locale('ru'),
                    delegates: GlobalMaterialLocalizations.delegates,
                    child: SizedBox.fromSize(
                      size: size,
                      child: ProviderScope(
                        overrides: [
                          sharedPreferencesProvider.overrideWithValue(
                            preferences,
                          ),
                          nozeltEngineProvider.overrideWithValue(AuditEngine()),
                        ],
                        child: const AddProfileScreen(),
                      ),
                    ),
                  );
                },
                whilePerforming: (tester) async {
                  if (mode != 'subscription') {
                    await tester.tap(
                      find.text(mode == 'links' ? 'Ссылки' : 'Файл').first,
                    );
                    await tester.pumpAndSettle();
                  }
                  expect(tester.takeException(), isNull);
                  return () async {
                    debugDefaultTargetPlatformOverride = null;
                  };
                },
              );
            }
          }
        },
      );
    }
  }
  AlchemistConfig.runWithConfig(
    config: nozeltGoldenConfig(NozeltTheme.forPlatform(TargetPlatform.windows)),
    run: () {
      for (final entry in {
        'settings': const SettingsTab(),
        'dns': const NetworkSettingsScreen(dns: true),
        'tun': const NetworkSettingsScreen(dns: false),
      }.entries) {
        goldenTest(
          'Windows ${entry.key} screen',
          fileName: '${entry.key}_windows_dark_720',
          builder: () {
            debugDefaultTargetPlatformOverride = TargetPlatform.windows;
            return Localizations(
              locale: const Locale('ru'),
              delegates: GlobalMaterialLocalizations.delegates,
              child: SizedBox(
                width: 720,
                height: 520,
                child: ProviderScope(
                  overrides: [
                    sharedPreferencesProvider.overrideWithValue(preferences),
                    nozeltEngineProvider.overrideWithValue(AuditEngine()),
                    engineStateProvider.overrideWith(
                      () => AuditEngineState(false),
                    ),
                  ],
                  child: Scaffold(body: entry.value),
                ),
              ),
            );
          },
          whilePerforming: (tester) async {
            expect(tester.takeException(), isNull);
            return () async {
              debugDefaultTargetPlatformOverride = null;
            };
          },
        );
      }
      goldenTest(
        'Responsive editor at 150%',
        fileName: 'editor_windows_dark_720_scale150',
        textScaleFactor: 1.5,
        builder: () => Localizations(
          locale: const Locale('ru'),
          delegates: GlobalMaterialLocalizations.delegates,
          child: const SizedBox(
            width: 720,
            height: 520,
            child: NozeltEditorShowcase(),
          ),
        ),
      );
    },
  );
  AlchemistConfig.runWithConfig(
    config: nozeltGoldenConfig(
      NozeltTheme.forPlatform(
        TargetPlatform.windows,
        brightness: Brightness.light,
      ),
    ),
    run: () {
      for (final dns in [true, false]) {
        goldenTest(
          'Windows ${dns ? 'DNS' : 'TUN'} light form',
          fileName: '${dns ? 'dns' : 'tun'}_windows_light_720',
          builder: () {
            debugDefaultTargetPlatformOverride = TargetPlatform.windows;
            return Localizations(
              locale: const Locale('ru'),
              delegates: GlobalMaterialLocalizations.delegates,
              child: SizedBox(
                width: 720,
                height: 520,
                child: ProviderScope(
                  overrides: [
                    sharedPreferencesProvider.overrideWithValue(preferences),
                    nozeltEngineProvider.overrideWithValue(AuditEngine()),
                    engineStateProvider.overrideWith(
                      () => AuditEngineState(false),
                    ),
                  ],
                  child: NetworkSettingsScreen(dns: dns),
                ),
              ),
            );
          },
          whilePerforming: (tester) async {
            expect(tester.takeException(), isNull);
            return () async {
              debugDefaultTargetPlatformOverride = null;
            };
          },
        );
      }
    },
  );
}
