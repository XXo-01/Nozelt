import 'package:alchemist/alchemist.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:nozelt/src/ui/design_system/nozelt_design_system.dart';
import 'package:nozelt/nozelt_design_system_preview.dart';
import 'golden_config.dart';

void main() {
  for (final platform in [TargetPlatform.windows, TargetPlatform.android]) {
    for (final brightness in Brightness.values) {
      final touch = platform == TargetPlatform.android;
      final theme = NozeltTheme.forPlatform(platform, brightness: brightness);
      AlchemistConfig.runWithConfig(
        config: nozeltGoldenConfig(theme),
        run: () {
          for (final entry in <String, (Widget, double)>{
            'buttons': (const NozeltButtonsShowcase(), touch ? 1200 : 620),
            'fields': (const NozeltFieldsShowcase(), touch ? 1000 : 800),
            'switches': (const NozeltSwitchesShowcase(), touch ? 700 : 500),
            'segments': (const NozeltSegmentsShowcase(), touch ? 600 : 420),
            'tokens': (const NozeltTokensShowcase(), 620),
            'settings_field': (
              const NozeltSettingsFieldShowcase(),
              touch ? 480 : 360,
            ),
            'profile_import': (
              const NozeltProfileImportShowcase(),
              touch ? 260 : 220,
            ),
          }.entries) {
            goldenTest(
              '${entry.key} ${platform.name} ${brightness.name}',
              fileName: '${entry.key}_${platform.name}_${brightness.name}',
              pumpBeforeTest: (tester) async {
                await tester.pump();
                await tester.pump(const Duration(milliseconds: 300));
              },
              builder: () => Localizations(
                locale: const Locale('ru'),
                delegates: GlobalMaterialLocalizations.delegates,
                child: SizedBox(
                  width: touch
                      ? 360
                      : entry.key == 'settings_field'
                      ? 900
                      : 640,
                  height: entry.value.$2,
                  child: Builder(
                    builder: (context) => Material(
                      color: Theme.of(context).scaffoldBackgroundColor,
                      child: TickerMode(
                        enabled: true,
                        child: Padding(
                          padding: const EdgeInsets.all(24),
                          child: entry.value.$1,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            );
          }
          goldenTest(
            'Focused input ${platform.name} ${brightness.name}',
            fileName: 'field_focus_${platform.name}_${brightness.name}',
            builder: () => Localizations(
              locale: const Locale('ru'),
              delegates: GlobalMaterialLocalizations.delegates,
              child: SizedBox(
                width: touch ? 360 : 640,
                height: 140,
                child: Material(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: NozeltTextField(
                      label: 'Адрес подписки',
                      initialValue: 'https://example.test',
                      autofocus: true,
                      onChanged: (_) {},
                    ),
                  ),
                ),
              ),
            ),
            pumpBeforeTest: (tester) async {
              await tester.pump();
              await tester.pump(const Duration(milliseconds: 250));
            },
          );
          if (touch) {
            for (final entry in <String, (Widget, double)>{
              'fields': (const NozeltFieldsShowcase(), 1600),
              'segments': (const NozeltSegmentsShowcase(), 1600),
            }.entries) {
              goldenTest(
                '${entry.key} ${brightness.name} at 200%',
                fileName: '${entry.key}_android_${brightness.name}_scale200',
                textScaleFactor: 2,
                builder: () => Localizations(
                  locale: const Locale('ru'),
                  delegates: GlobalMaterialLocalizations.delegates,
                  child: SizedBox(
                    width: 360,
                    height: entry.value.$2,
                    child: Builder(
                      builder: (context) => Material(
                        color: Theme.of(context).scaffoldBackgroundColor,
                        child: Padding(
                          padding: const EdgeInsets.all(24),
                          child: entry.value.$1,
                        ),
                      ),
                    ),
                  ),
                ),
              );
            }
          }
        },
      );
    }
  }
}
