import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'dart:ui' show Tristate;
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nozelt/src/ui/design_system/nozelt_design_system.dart';
import 'package:nozelt/nozelt_design_system_preview.dart';

Widget _app(
  Widget child, {
  TargetPlatform platform = TargetPlatform.windows,
  Brightness brightness = Brightness.dark,
  double scale = 1,
}) => MaterialApp(
  theme: NozeltTheme.forPlatform(platform, brightness: brightness),
  locale: const Locale('ru'),
  supportedLocales: const [Locale('ru'), Locale('en')],
  localizationsDelegates: GlobalMaterialLocalizations.delegates,
  builder: (context, child) => MediaQuery(
    data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(scale)),
    child: child!,
  ),
  home: Scaffold(body: child),
);

double _contrast(Color a, Color b) {
  final x = a.computeLuminance(), y = b.computeLuminance();
  return (math.max(x, y) + 0.05) / (math.min(x, y) + 0.05);
}

void main() {
  testWidgets('Settings help preserves an edited value at 200% text scale', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(360, 800);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final controller = TextEditingController(text: '100');
    addTearDown(controller.dispose);
    const label = 'Ожидание ответа IPv6, мс';
    const help = 'Допустимое время ожидания ответа сервера.';
    await tester.pumpWidget(
      _app(
        SingleChildScrollView(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: NozeltSettingsField(
              label: label,
              help: help,
              child: NozeltTextField(controller: controller),
            ),
          ),
        ),
        platform: TargetPlatform.android,
        brightness: Brightness.light,
        scale: 2,
      ),
    );
    await tester.enterText(find.byType(TextFormField), '250');
    await tester.tap(find.byTooltip(help));
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsOneWidget);
    expect(find.text(help), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.tap(find.text('Закрыть'));
    await tester.pumpAndSettle();
    expect(controller.text, '250');
    expect(find.byType(AlertDialog), findsNothing);
    final caption = tester.getRect(find.text(label));
    final field = tester.getRect(find.byType(TextFormField));
    expect(caption.bottom, lessThanOrEqualTo(field.top));
    expect(field.right, lessThanOrEqualTo(360));
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'Vertical segments fill the width and show complete long captions',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(360, 900);
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        _app(
          const SingleChildScrollView(
            child: Padding(
              padding: EdgeInsets.all(24),
              child: NozeltSegmentsShowcase(),
            ),
          ),
          platform: TargetPlatform.android,
          scale: 2,
        ),
      );
      await tester.pumpAndSettle();
      final label = find.text('Автоматический выбор конфигурации');
      expect(tester.getSize(label).height, greaterThan(50));
      final control = find.ancestor(
        of: label,
        matching: find.byType(NozeltPillTrack<int>),
      );
      final bounds = tester.getRect(control);
      final buttons = find.descendant(
        of: control,
        matching: find.byType(InkWell),
      );
      expect(buttons, findsNWidgets(2));
      for (final element in buttons.evaluate()) {
        final rect = tester.getRect(find.byWidget(element.widget));
        // The pill track keeps a 4 px inset around its options.
        expect(rect.width, closeTo(bounds.width - 8, 1));
        expect(rect.height, closeTo((bounds.height - 8) / 2, 4));
      }
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets('Responsive controls work in intrinsic AlertDialog layout', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(720, 520);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      _app(
        Builder(
          builder: (context) => NozeltButton(
            label: 'Открыть',
            onPressed: () => showDialog<void>(
              context: context,
              builder: (_) => AlertDialog(
                title: const Text('Профиль'),
                content: NozeltDialogBody(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const NozeltTextField(label: 'Название'),
                      NozeltSegmentedControl<int>(
                        segments: const [
                          ButtonSegment(
                            value: 0,
                            label: Text('Автоматический выбор'),
                          ),
                          ButtonSegment(
                            value: 1,
                            label: Text('Настроить вручную'),
                          ),
                        ],
                        value: 0,
                        onChanged: (_) {},
                      ),
                    ],
                  ),
                ),
                actions: [NozeltButton(label: 'Сохранить', onPressed: () {})],
              ),
            ),
          ),
        ),
        scale: 2,
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Открыть'));
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsOneWidget);
    expect(tester.takeException(), isNull);
    tester.view.physicalSize = const Size(360, 800);
    await tester.pumpAndSettle();
    final save = tester.getRect(find.text('Сохранить'));
    expect(save.bottom, lessThanOrEqualTo(800));
    expect(tester.takeException(), isNull);
  });
  testWidgets('Editor keeps actions visible at Windows DPI scales', (
    tester,
  ) async {
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    for (final ratio in [1.0, 1.25, 1.5, 2.0]) {
      tester.view.devicePixelRatio = ratio;
      tester.view.physicalSize = Size(720 * ratio, 520 * ratio);
      await tester.pumpWidget(_app(const NozeltEditorShowcase(), scale: 1.5));
      await tester.pumpAndSettle();
      final save = tester.getRect(find.text('Сохранить'));
      expect(save.bottom, lessThanOrEqualTo(520));
      expect(save.left, greaterThanOrEqualTo(0));
      expect(tester.takeException(), isNull);
    }
  });
  for (final platform in [TargetPlatform.windows, TargetPlatform.android]) {
    for (final brightness in Brightness.values) {
      test('Semantic text contrast $platform $brightness', () {
        final theme = NozeltTheme.forPlatform(platform, brightness: brightness);
        final c = theme.colorScheme;
        final t = theme.extension<NozeltTokens>()!;
        for (final pair in [
          (c.onSurface, c.surface),
          (c.onSurfaceVariant, c.surface),
          (c.primary, c.surface),
          (c.onPrimary, c.primary),
          (c.error, c.surface),
          (t.success, c.surface),
          (t.warning, c.surface),
          (c.primary, theme.scaffoldBackgroundColor),
          (c.primary, c.surfaceContainerHighest),
          (c.onSurfaceVariant, c.surfaceContainerHighest),
          (c.error, c.surfaceContainerHighest),
          (c.onPrimaryContainer, c.primaryContainer),
        ]) {
          expect(_contrast(pair.$1, pair.$2), greaterThanOrEqualTo(4.5));
        }
      });
    }
  }

  testWidgets(
    'Loading/disabled actions cannot fire; focused action accepts Enter',
    (tester) async {
      var calls = 0;
      final focus = FocusNode();
      addTearDown(focus.dispose);
      await tester.pumpWidget(
        _app(
          Column(
            children: [
              NozeltButton(
                label: 'Добавить',
                onPressed: () => calls++,
                focusNode: focus,
              ),
              const NozeltButton(label: 'Недоступно', onPressed: null),
              NozeltButton(
                label: 'Сохранение',
                onPressed: () => calls++,
                loading: true,
              ),
            ],
          ),
        ),
      );
      await tester.pump();
      await tester.tap(find.text('Сохранение'));
      await tester.tap(find.text('Недоступно'));
      expect(calls, 0);
      focus.requestFocus();
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pump();
      expect(calls, 1);
      expect(focus.hasFocus, isTrue);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('Form validation, editing and read-only remain native', (
    tester,
  ) async {
    final form = GlobalKey<FormState>();
    final editable = TextEditingController();
    final locked = TextEditingController(text: 'Nozelt');
    addTearDown(editable.dispose);
    addTearDown(locked.dispose);
    await tester.pumpWidget(
      _app(
        Form(
          key: form,
          child: Column(
            children: [
              NozeltTextField(
                key: const ValueKey('editable'),
                controller: editable,
                label: 'Название',
                validator: (s) => (s ?? '').isEmpty ? 'Введите название' : null,
              ),
              NozeltTextField(
                key: const ValueKey('locked'),
                controller: locked,
                label: 'Только чтение',
                readOnly: true,
              ),
            ],
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(form.currentState!.validate(), isFalse);
    await tester.pumpAndSettle();
    expect(find.text('Введите название'), findsOneWidget);
    await tester.enterText(
      find.byKey(const ValueKey('editable')),
      'Основной профиль',
    );
    expect(form.currentState!.validate(), isTrue);
    await tester.tap(find.byKey(const ValueKey('locked')));
    await tester.sendKeyEvent(LogicalKeyboardKey.backspace);
    expect(locked.text, 'Nozelt');
    expect(editable.text, 'Основной профиль');
  });

  testWidgets(
    'Switch tile exposes a labeled toggled state and keyboard activation',
    (tester) async {
      final semantics = tester.ensureSemantics();
      try {
        var value = false;
        final focus = FocusNode();
        addTearDown(focus.dispose);
        await tester.pumpWidget(
          _app(
            StatefulBuilder(
              builder: (context, set) => NozeltSwitchTile(
                title: const Text('Автоподключение'),
                value: value,
                focusNode: focus,
                onChanged: (v) => set(() => value = v),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        final before = tester.getSemantics(find.byType(Switch));
        expect(
          before.getSemanticsData().flagsCollection.isToggled,
          Tristate.isFalse,
        );
        expect(before.label, contains('Автоподключение'));
        await tester.tap(find.text('Автоподключение'));
        await tester.pumpAndSettle();
        expect(value, isTrue);
        focus.requestFocus();
        await tester.pump();
        await tester.sendKeyEvent(LogicalKeyboardKey.space);
        await tester.pumpAndSettle();
        expect(value, isFalse);
      } finally {
        semantics.dispose();
      }
    },
  );

  testWidgets(
    'Segments resize without infinite height and keep selected value',
    (tester) async {
      var value = 0;
      await tester.pumpWidget(
        _app(
          StatefulBuilder(
            builder: (context, set) => SingleChildScrollView(
              child: NozeltSegmentedControl<int>(
                segments: const [
                  ButtonSegment(value: 0, label: Text('Автоматический выбор')),
                  ButtonSegment(value: 1, label: Text('Настройка вручную')),
                ],
                value: value,
                onChanged: (v) => set(() => value = v),
              ),
            ),
          ),
          scale: 1.5,
        ),
      );
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      tester.view.devicePixelRatio = 1;
      for (final size in [
        const Size(360, 800),
        const Size(720, 520),
        const Size(1180, 760),
        const Size(360, 800),
      ]) {
        tester.view.physicalSize = size;
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        final bounds = tester.getRect(find.byType(NozeltSegmentedControl<int>));
        for (final text in ['Автоматический выбор', 'Настройка вручную']) {
          final caption = tester.getRect(find.text(text));
          expect(caption.left, greaterThanOrEqualTo(bounds.left));
          expect(caption.right, lessThanOrEqualTo(bounds.right));
        }
      }
      await tester.tap(find.text('Настройка вручную'));
      await tester.pumpAndSettle();
      expect(value, 1);
      // Windows draws the capsule track instead of a Material SegmentedButton.
      expect(
        tester
            .widget<NozeltPillTrack<int>>(find.byType(NozeltPillTrack<int>))
            .value,
        1,
      );
    },
  );

  testWidgets('Both themes and densities fit long Russian text at 200%', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    for (final platform in [TargetPlatform.windows, TargetPlatform.android]) {
      for (final brightness in Brightness.values) {
        for (final width in [360.0, 720.0, 1180.0]) {
          tester.view.physicalSize = Size(width, 800);
          await tester.pumpWidget(
            _app(
              SingleChildScrollView(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    children: [
                      NozeltButton(
                        label:
                            'Добавить новый профиль маршрутизации для выбранного сервера',
                        onPressed: () {},
                      ),
                      const SizedBox(height: 16),
                      const NozeltFieldsShowcase(),
                      const SizedBox(height: 16),
                      const NozeltSegmentsShowcase(),
                      const SizedBox(height: 16),
                      const NozeltSwitchesShowcase(),
                    ],
                  ),
                ),
              ),
              platform: platform,
              brightness: brightness,
              scale: 2,
            ),
          );
          await tester.pumpAndSettle();
          expect(
            tester.takeException(),
            isNull,
            reason: '$platform/$brightness/$width',
          );
        }
      }
    }
  });
}
