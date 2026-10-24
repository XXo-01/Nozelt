import 'dart:ui' show PointerDeviceKind;
import 'package:alchemist/alchemist.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nozelt/nozelt_design_system.dart';
import 'package:nozelt/nozelt_design_system_preview.dart';
import 'golden_config.dart';

void main() {
  for (final brightness in Brightness.values) {
    AlchemistConfig.runWithConfig(
      config: nozeltGoldenConfig(
        NozeltTheme.forPlatform(TargetPlatform.windows, brightness: brightness),
      ),
      run: () {
        for (final target in [
          'primary',
          'primary-pressed',
          'secondary',
          'tertiary',
          'icon',
          'surface',
          'surface-pressed',
          'first-row',
          'last-row',
          'popup',
          'popup-first',
          'popup-last',
          'dropdown-first',
          'dropdown-last',
          'segments',
        ]) {
          goldenTest(
            'Windows $target hover ${brightness.name}',
            fileName: 'hover_${target}_${brightness.name}',
            builder: () => Localizations(
              locale: const Locale('ru'),
              delegates: GlobalMaterialLocalizations.delegates,
              child: const SizedBox(
                width: 640,
                height: 620,
                child: Scaffold(
                  body: Padding(
                    padding: EdgeInsets.all(24),
                    child: NozeltInteractionShowcase(),
                  ),
                ),
              ),
            ),
            whilePerforming: (tester) async {
              await tester.pumpAndSettle();
              final pressed = target.endsWith('-pressed');
              final key = pressed
                  ? target.replaceFirst('-pressed', '')
                  : target;
              var finder = find.byKey(ValueKey('interaction-$key'));
              if (target.startsWith('popup-')) {
                await tester.tap(
                  find.byKey(const ValueKey('interaction-popup')),
                );
                await tester.pumpAndSettle();
                finder = find.byType(PopupMenuItem<String>);
                finder = target.endsWith('first') ? finder.first : finder.last;
              } else if (target.startsWith('dropdown-')) {
                await tester.tap(
                  find.byKey(const ValueKey('interaction-dropdown')),
                );
                await tester.pumpAndSettle();
                finder = find
                    .text(target.endsWith('first') ? 'Тёмная' : 'Системная')
                    .last;
              }
              final mouse = await tester.createGesture(
                kind: PointerDeviceKind.mouse,
              );
              await mouse.addPointer(location: const Offset(1, 1));
              await mouse.moveTo(tester.getCenter(finder));
              if (pressed) await mouse.down(tester.getCenter(finder));
              await tester.pump();
              await tester.pump(const Duration(milliseconds: 250));
              expect(tester.takeException(), isNull);
              return () async {
                if (pressed) await mouse.up();
                await mouse.removePointer();
              };
            },
          );
        }
      },
    );
  }
}
