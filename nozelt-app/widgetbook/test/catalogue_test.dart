import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nozelt/nozelt_design_system_preview.dart';
import 'package:nozelt_widgetbook/main.dart';

void main() {
  for (final entry in <String, Type>{
    'foundations/tokens/colors-and-typography': NozeltTokensShowcase,
    'controls/buttons/variants-and-states': NozeltButtonsShowcase,
    'controls/fields/input-states': NozeltFieldsShowcase,
    'controls/switches/selection-and-disabled': NozeltSwitchesShowcase,
    'controls/segments/responsive-selection': NozeltSegmentsShowcase,
    'patterns/editor/form-and-save-bar': NozeltEditorShowcase,
    'patterns/profile-import/quick-actions': NozeltProfileImportShowcase,
    'patterns/settings/responsive-fields': NozeltSettingsFieldShowcase,
    'patterns/interactions/rounded-ink-and-menus': NozeltInteractionShowcase,
  }.entries) {
    testWidgets('Catalogue opens ${entry.key}', (tester) async {
      await tester.binding.setSurfaceSize(const Size(1440, 1000));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
        NozeltWidgetbook(initialRoute: '/?path=${entry.key}'),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      expect(find.byType(entry.value), findsOneWidget);
      expect(tester.takeException(), isNull);
      // Loading examples intentionally animate; dispose instead of settling.
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
    });
  }
}
