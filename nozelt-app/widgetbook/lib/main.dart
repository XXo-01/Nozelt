import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:nozelt/nozelt_design_system.dart';
import 'package:nozelt/nozelt_design_system_preview.dart';
import 'package:widgetbook/widgetbook.dart';

void main() => runApp(const NozeltWidgetbook());

class NozeltWidgetbook extends StatelessWidget {
  const NozeltWidgetbook({this.initialRoute = '/', super.key});
  final String initialRoute;

  @override
  Widget build(BuildContext context) => Widgetbook.material(
    initialRoute: initialRoute,
    themeMode: ThemeMode.dark,
    lightTheme: NozeltTheme.forPlatform(
      TargetPlatform.windows,
      brightness: Brightness.light,
    ),
    darkTheme: NozeltTheme.forPlatform(TargetPlatform.windows),
    header: const Padding(
      padding: EdgeInsets.all(16),
      child: Text('Nozelt · Design System'),
    ),
    directories: [
      WidgetbookFolder(
        name: 'Foundations',
        children: [
          WidgetbookComponent(
            name: 'Tokens',
            useCases: [
              WidgetbookUseCase(
                name: 'Colors and typography',
                builder: (_) => _page(const NozeltTokensShowcase()),
              ),
            ],
          ),
        ],
      ),
      WidgetbookFolder(
        name: 'Controls',
        children: [
          WidgetbookComponent(
            name: 'Buttons',
            useCases: [
              WidgetbookUseCase(
                name: 'Variants and states',
                builder: (_) => _page(const NozeltButtonsShowcase()),
              ),
            ],
          ),
          WidgetbookComponent(
            name: 'Fields',
            useCases: [
              WidgetbookUseCase(
                name: 'Input states',
                builder: (_) => _page(const NozeltFieldsShowcase()),
              ),
            ],
          ),
          WidgetbookComponent(
            name: 'Switches',
            useCases: [
              WidgetbookUseCase(
                name: 'Selection and disabled',
                builder: (_) => _page(const NozeltSwitchesShowcase()),
              ),
            ],
          ),
          WidgetbookComponent(
            name: 'Segments',
            useCases: [
              WidgetbookUseCase(
                name: 'Responsive selection',
                builder: (_) => _page(const NozeltSegmentsShowcase()),
              ),
            ],
          ),
        ],
      ),
      WidgetbookFolder(
        name: 'Patterns',
        children: [
          WidgetbookComponent(
            name: 'Interactions',
            useCases: [
              WidgetbookUseCase(
                name: 'Rounded ink and menus',
                builder: (_) => _page(const NozeltInteractionShowcase()),
              ),
            ],
          ),
          WidgetbookComponent(
            name: 'Settings',
            useCases: [
              WidgetbookUseCase(
                name: 'Responsive fields',
                builder: (_) => _page(const NozeltSettingsFieldShowcase()),
              ),
            ],
          ),
          WidgetbookComponent(
            name: 'Profile import',
            useCases: [
              WidgetbookUseCase(
                name: 'Quick actions',
                builder: (_) => _page(const NozeltProfileImportShowcase()),
              ),
            ],
          ),
          WidgetbookComponent(
            name: 'Editor',
            useCases: [
              WidgetbookUseCase(
                name: 'Form and save bar',
                builder: (_) => const NozeltEditorShowcase(),
              ),
            ],
          ),
        ],
      ),
    ],
    addons: [
      ViewportAddon(const [
        ViewportData(
          name: 'Windows · 720 × 520',
          width: 720,
          height: 520,
          pixelRatio: 1,
          platform: TargetPlatform.windows,
        ),
        ViewportData(
          name: 'Windows · 1180 × 760',
          width: 1180,
          height: 760,
          pixelRatio: 1,
          platform: TargetPlatform.windows,
        ),
        ViewportData(
          name: 'Android · 360 × 800',
          width: 360,
          height: 800,
          pixelRatio: 1,
          platform: TargetPlatform.android,
        ),
        ViewportData(
          name: 'Android · 412 × 915',
          width: 412,
          height: 915,
          pixelRatio: 1,
          platform: TargetPlatform.android,
        ),
      ]),
      ThemeAddon<ThemeData>(
        themes: [
          for (final platform in [
            TargetPlatform.windows,
            TargetPlatform.android,
          ])
            for (final brightness in [Brightness.dark, Brightness.light])
              WidgetbookTheme(
                name: '${platform.name} · ${brightness.name}',
                data: NozeltTheme.forPlatform(platform, brightness: brightness),
              ),
        ],
        themeBuilder: (_, theme, child) => Theme(data: theme, child: child),
      ),
      LocalizationAddon(
        locales: const [Locale('ru'), Locale('en')],
        localizationsDelegates: GlobalMaterialLocalizations.delegates,
      ),
      TextScaleAddon(min: 1, max: 2, divisions: 4, initialScale: 1),
    ],
  );

  static Widget _page(Widget child) => Scaffold(
    body: SingleChildScrollView(
      padding: const EdgeInsets.all(NozeltSpacing.xxl),
      child: child,
    ),
  );
}
