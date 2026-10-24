import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nozelt/src/data/app_preferences.dart';

import 'package:nozelt/main.dart';
import 'package:nozelt/src/state/settings_provider.dart';

void main() {
  testWidgets('NozeltApp boots into HomeScreen', (WidgetTester tester) async {
    SharedPreferences.setMockInitialValues({});
    final preferences = await SharedPreferences.getInstance();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [sharedPreferencesProvider.overrideWithValue(preferences)],
        child: const NozeltApp(),
      ),
    );
    expect(find.text('Nozelt'), findsOneWidget);
    expect(find.text('Подключить'), findsOneWidget);
    expect(find.text('Главная'), findsOneWidget);
    expect(find.text('Прокси'), findsOneWidget);
    expect(find.text('1.0.0'), findsOneWidget);
    await tester.scrollUntilVisible(
      find.text('Глобально'),
      300,
      scrollable: find.byType(Scrollable).first,
    );
    expect(find.text('Глобально'), findsOneWidget);
    expect(find.text('По правилам'), findsOneWidget);
    expect(find.text('Время подключения'), findsNothing);
    expect(find.text('VPN ВЫКЛЮЧЕН'), findsNothing);

    await tester.tap(find.text('Настройки'));
    await tester.pumpAndSettle();

    final alwaysOn = find.text('Постоянный VPN и блокировка утечек');
    await tester.scrollUntilVisible(
      alwaysOn,
      250,
      scrollable: find.byType(Scrollable).first,
    );
    expect(find.text('Онлайн-определение страны'), findsNothing);
    await tester.tap(alwaysOn);
    await tester.pumpAndSettle();

    expect(alwaysOn, findsOneWidget);
    expect(find.text('Открыть настройки VPN'), findsOneWidget);
    expect(find.byIcon(Icons.arrow_back_rounded), findsOneWidget);
  });
}
