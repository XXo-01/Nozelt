import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nozelt/main.dart';
import 'package:nozelt/src/data/app_preferences.dart';
import 'package:nozelt/src/state/settings_provider.dart';

void main() {
  Future<void> pumpApp(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    SharedPreferences.setMockInitialValues({});
    final preferences = await SharedPreferences.getInstance();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [sharedPreferencesProvider.overrideWithValue(preferences)],
        child: const NozeltApp(),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('mobile routing exposes profiles and the five rule categories', (
    tester,
  ) async {
    await pumpApp(tester);

    await tester.tap(find.text('Маршруты'));
    await tester.pumpAndSettle();

    expect(find.text('Профиль маршрутизации'), findsOneWidget);
    expect(find.text('Основной'), findsOneWidget);
    expect(find.text('Раздельное туннелирование'), findsOneWidget);
    expect(find.text('Доступ к локальной сети'), findsNothing);
    expect(find.text('Определение домена по трафику'), findsNothing);
    expect(find.text('Режим'), findsNothing);
    expect(find.text('Глобально'), findsNothing);

    final settingsTop = tester
        .getTopLeft(find.text('Настройки маршрутизации'))
        .dy;
    final splitTop = tester
        .getTopLeft(find.text('Раздельное туннелирование'))
        .dy;
    expect(settingsTop, lessThan(splitTop));

    for (final title in const [
      'GeoIP и GeoSite',
      'Точный домен',
      'Домен и поддомены',
      'Ключевое слово',
      'IP-сеть (CIDR)',
    ]) {
      await tester.dragUntilVisible(
        find.text(title),
        find.byKey(const PageStorageKey<String>('routing-scroll')),
        const Offset(0, -120),
      );
      await tester.pumpAndSettle();
      expect(find.text(title), findsOneWidget);
    }

    await tester.ensureVisible(find.text('GeoIP и GeoSite'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('GeoIP и GeoSite'));
    await tester.pumpAndSettle();
    expect(find.text('Прокси'), findsOneWidget);
    await tester.ensureVisible(find.text('Напрямую'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('Блокировать'));
    await tester.pumpAndSettle();

    for (final field in tester.widgetList<TextField>(find.byType(TextField))) {
      expect(field.decoration?.hintText, isNull);
    }

    await tester.ensureVisible(find.text('Теги GeoSite'));
    await tester.tap(find.text('Теги GeoSite'));
    await tester.pumpAndSettle();
    expect(find.text('Поиск тегов'), findsOneWidget);

    await tester.enterText(
      find.byKey(const ValueKey('geo-tag-search')),
      'telegram',
    );
    await tester.pumpAndSettle();
    expect(find.widgetWithText(ActionChip, 'telegram'), findsOneWidget);
    expect(find.text('youtube'), findsNothing);
  });

  testWidgets(
    'routing-wide switches live in Settings and ping can be disabled',
    (tester) async {
      await pumpApp(tester);

      await tester.tap(find.text('Настройки'));
      await tester.pumpAndSettle();
      final scrollable = find.byType(Scrollable).first;

      await tester.scrollUntilVisible(
        find.text('Доступ к локальной сети'),
        180,
        scrollable: scrollable,
      );
      expect(find.text('Доступ к локальной сети'), findsOneWidget);
      expect(find.text('Определение домена по трафику'), findsOneWidget);

      await tester.scrollUntilVisible(
        find.text('Интервал проверки пинга'),
        -180,
        scrollable: scrollable,
      );
      await tester.tap(find.text('1 мин'));
      await tester.pumpAndSettle();
      expect(find.text('Никогда'), findsOneWidget);
    },
  );
}
