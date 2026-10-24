import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nozelt/nozelt_design_system.dart';
import 'package:nozelt/src/data/app_preferences.dart';
import 'package:nozelt/src/state/engine_provider.dart';
import 'package:nozelt/src/state/settings_provider.dart';
import 'package:nozelt/src/ui/add_profile_screen.dart';
import 'support/ui_audit_fixtures.dart';

void main() {
  setUpAll(loadAuditFonts);
  for (final platform in [TargetPlatform.windows, TargetPlatform.android]) {
    for (final mode in ['Подписка', 'Ссылки', 'Файл']) {
      testWidgets('Import $mode on ${platform.name}', (tester) async {
        debugDefaultTargetPlatformOverride = platform;
        addTearDown(() => debugDefaultTargetPlatformOverride = null);
        try {
          final size = platform == TargetPlatform.windows
              ? const Size(720, 520)
              : const Size(360, 800);
          tester.view.physicalSize = size;
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.resetPhysicalSize);
          addTearDown(tester.view.resetDevicePixelRatio);
          SharedPreferences.setMockInitialValues({});
          final preferences = await SharedPreferences.getInstance();
          final boundaryKey = GlobalKey();
          await tester.pumpWidget(
            ProviderScope(
              overrides: [
                sharedPreferencesProvider.overrideWithValue(preferences),
                nozeltEngineProvider.overrideWithValue(AuditEngine()),
              ],
              child: MaterialApp(
                theme: NozeltTheme.forPlatform(platform),
                locale: const Locale('ru'),
                supportedLocales: const [Locale('ru'), Locale('en')],
                localizationsDelegates: GlobalMaterialLocalizations.delegates,
                home: RepaintBoundary(
                  key: boundaryKey,
                  child: const AddProfileScreen(),
                ),
              ),
            ),
          );
          await tester.tap(find.text(mode).first);
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull);
          expect(find.text('Добавить профиль'), findsWidgets);
          expect(find.textContaining('User-Agent'), findsNothing);
          expect(find.text('Название (опционально)'), findsOneWidget);
          expect(
            find.text('По QR-коду'),
            platform == TargetPlatform.android ? findsOneWidget : findsNothing,
          );
          final output = Platform.environment['NOZELT_PROFILE_CAPTURE'];
          if (output != null && output.isNotEmpty) {
            final name = {
              'Подписка': 'subscription',
              'Ссылки': 'links',
              'Файл': 'file',
            }[mode];
            Directory(output).createSync(recursive: true);
            await expectLater(
              find.byKey(boundaryKey),
              matchesGoldenFile(File('$output/${platform.name}_$name.png').uri),
            );
          }
        } finally {
          debugDefaultTargetPlatformOverride = null;
        }
      });
    }
  }
  testWidgets('Quick actions stay aligned at 200% with long Russian captions', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(360, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        theme: NozeltTheme.forPlatform(TargetPlatform.android),
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: TextScaler.linear(2)),
          child: child!,
        ),
        home: Scaffold(
          body: Padding(
            padding: const EdgeInsets.all(16),
            child: NozeltProfileImportActions(
              pasteLabel: 'Из буфера обмена',
              scanLabel: 'Сканировать QR-код',
              showQr: true,
              onPaste: () {},
              onScan: () {},
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final buttons = find.byType(OutlinedButton);
    expect(
      tester.getSize(buttons.at(0)).height,
      tester.getSize(buttons.at(1)).height,
    );
    expect(tester.takeException(), isNull);
  });
}
