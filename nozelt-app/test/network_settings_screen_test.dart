import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nozelt/src/core/advanced_network_settings.dart';
import 'package:nozelt/src/data/app_preferences.dart';
import 'package:nozelt/src/state/settings_provider.dart';
import 'package:nozelt/src/state/engine_provider.dart';
import 'package:nozelt/src/ui/network_settings_screen.dart';
import 'package:nozelt/src/ui/nozelt_theme.dart';
import 'support/ui_audit_fixtures.dart';

void networkTest(String name, Future<void> Function(WidgetTester) body) {
  testWidgets(name, (tester) async {
    try {
      await body(tester);
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(loadAuditFonts);

  Future<ProviderContainer> open(
    WidgetTester tester, {
    required bool dns,
    Size size = const Size(720, 520),
    String language = 'ru',
    bool light = false,
    double scale = 1,
  }) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final container = ProviderContainer(
      overrides: [
        sharedPreferencesProvider.overrideWithValue(prefs),
        nozeltEngineProvider.overrideWithValue(AuditEngine()),
      ],
    );
    addTearDown(container.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: light ? NozeltTheme.light : NozeltTheme.dark,
          locale: Locale(language),
          supportedLocales: const [Locale('ru'), Locale('en')],
          localizationsDelegates: GlobalMaterialLocalizations.delegates,
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(textScaler: TextScaler.linear(scale)),
            child: child!,
          ),
          home: NetworkSettingsScreen(dns: dns),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return container;
  }

  for (final light in [false, true]) {
    for (final dns in [true, false]) {
      for (final size in [const Size(720, 520), const Size(1180, 760)]) {
        networkTest(
          '${dns ? 'DNS' : 'TUN'} pages fit $size light=$light and do not apply drafts',
          (tester) async {
            final container = await open(
              tester,
              dns: dns,
              size: size,
              light: light,
            );
            final before = container.read(tunSettingsProvider).encode();
            final tabs = dns
                ? ['Основные', 'Fake-IP', 'Правила и hosts', 'Резервный DNS']
                : ['Интерфейс', 'Трафик', 'Защита'];
            for (var i = 0; i < tabs.length; i++) {
              await tester.tap(find.text(tabs[i]).first);
              await tester.pumpAndSettle();
              expect(tester.takeException(), isNull);
              await expectLater(
                find.byType(MaterialApp),
                matchesGoldenFile(
                  'goldens/network/${dns ? 'dns' : 'tun'}_${size.width.toInt()}_$i${light ? '_light' : ''}.png',
                ),
              );
            }
            expect(container.read(tunSettingsProvider).encode(), before);
          },
        );
      }
    }
  }

  networkTest('DNS and TUN forms fit English enlarged text', (tester) async {
    for (final dns in [true, false]) {
      await open(tester, dns: dns, language: 'en', scale: 1.4);
      final titles = dns
          ? ['General', 'Fake-IP', 'Policies and hosts', 'Fallback']
          : ['Interface', 'Traffic', 'Protection'];
      for (final title in titles) {
        await tester.ensureVisible(find.text(title).first);
        await tester.tap(find.text(title).first);
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
      }
      await tester.pumpWidget(const SizedBox());
    }
  });

  networkTest(
    'invalid DNS draft is rejected without touching stored settings',
    (tester) async {
      final c = await open(tester, dns: true);
      await tester.enterText(
        find.byKey(const ValueKey('network-nameservers')),
        'system',
      );
      await tester.tap(find.text('Сохранить'));
      await tester.pumpAndSettle();
      expect(
        find.text('Разрешены только защищённые DNS: DoH, DoT или DoQ'),
        findsOneWidget,
      );
      expect(
        c.read(tunSettingsProvider).nameservers.first,
        'https://1.1.1.1/dns-query',
      );
    },
  );

  networkTest('valid DNS save persists the entire staged category', (
    tester,
  ) async {
    final c = await open(tester, dns: true);
    await tester.enterText(
      find.byKey(const ValueKey('network-nameservers')),
      'https://9.9.9.9/dns-query',
    );
    await tester.tap(find.text('Fake-IP').first);
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('network-fakeIpTtl')),
      '42',
    );
    await tester.tap(find.text('Сохранить'));
    await tester.pumpAndSettle();
    expect(c.read(tunSettingsProvider).dns.fakeIpTtl, 42);
    expect(c.read(tunSettingsProvider).nameservers, [
      'https://9.9.9.9/dns-query',
    ]);
    expect(
      c.read(tunSettingsProvider).desktop.toMap(),
      const DesktopTunSettings().toMap(),
    );
  });
}
