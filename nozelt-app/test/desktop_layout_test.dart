import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nozelt/main.dart';
import 'package:nozelt/src/core/profile.dart';
import 'package:nozelt/src/core/models.dart';
import 'package:nozelt/src/state/engine_provider.dart';
import 'package:nozelt/src/core/proxy_node.dart';
import 'package:nozelt/src/data/profile_store.dart';
import 'package:nozelt/src/state/settings_provider.dart';
import 'package:nozelt/src/data/app_preferences.dart';
import 'package:nozelt/src/state/profiles_provider.dart';
import 'package:nozelt/src/ui/proxies_tab.dart' show subscriptionClock;

import 'support/ui_audit_fixtures.dart';

class _LayoutEngine extends AuditEngine {
  @override
  Future<List<DesktopConnection>> getConnections() async => [];
  @override
  Stream<LogEntry> logsStream() => const Stream.empty();
  @override
  Stream<Traffic> trafficStream() => const Stream.empty();
}

class _MemoryProfileStore extends ProfileStore {
  const _MemoryProfileStore(this.initial);

  final ProfilesState initial;

  @override
  Future<ProfilesState> load() async => initial;

  @override
  Future<void> save(ProfilesState state) async {}
}

ProxyNode _testNode(String name, String server) => ProxyNode.fromRaw({
  'name': name,
  'type': 'hysteria2',
  'server': server,
  'port': 443,
  'password': 'test-only',
});

ProfilesState _desktopProfilesFixture() {
  final primary = Profile(
    id: 'primary',
    name: 'Очень длинное название основного Windows-профиля Nozelt',
    type: ProfileType.subscription,
    source: 'https://example.test/subscription',
    nodes: [
      _testNode(
        '🇫🇮 Финляндия — очень длинное название сервера для проверки адаптивности',
        'one.example.test',
      ),
      _testNode('🇸🇪 Швеция 6 | обход белых списков', 'two.example.test'),
    ],
    pinned: true,
    selectedNodeName:
        '🇫🇮 Финляндия — очень длинное название сервера для проверки адаптивности',
    subscriptionMetadata: SubscriptionMetadata(
      uploadBytes: 1024 * 1024 * 1024,
      downloadBytes: 12 * 1024 * 1024 * 1024,
      expiresAt: DateTime(2027, 11, 1),
      description: 'Первая строка\nВторая строка описания профиля',
      webPageUrl: 'https://t.me/nozelt_test',
    ),
  );
  final secondary = Profile(
    id: 'secondary',
    name: 'Резервный профиль',
    type: ProfileType.manual,
    source: '',
    nodes: [_testNode('Германия', 'three.example.test')],
  );
  return ProfilesState(profiles: [primary, secondary], activeId: primary.id);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(loadAuditFonts);
  testWidgets('Windows shell keeps routing mode on Home and rules in Routing', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    tester.view.physicalSize = const Size(1180, 760);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    SharedPreferences.setMockInitialValues({});
    final preferences = await SharedPreferences.getInstance();

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          sharedPreferencesProvider.overrideWithValue(preferences),
          nozeltEngineProvider.overrideWithValue(_LayoutEngine()),
        ],
        child: const NozeltApp(),
      ),
    );
    await tester.pump(const Duration(milliseconds: 800));
    await _loadDesktopImages(tester);

    expect(find.text('Подключения'), findsOneWidget);
    expect(find.text('Логи'), findsOneWidget);
    expect(find.text('Глобально'), findsNWidgets(2));
    expect(find.text('По правилам'), findsOneWidget);
    expect(find.text('Добавить правило'), findsNothing);
    expect(find.text('Задержка'), findsOneWidget);
    expect(find.byTooltip('Обновить задержку'), findsOneWidget);
    // Home keeps the Android reading order: server, latency, traffic, routing.
    expect(
      tester.getTopLeft(find.text('Задержка')).dy,
      lessThan(tester.getTopLeft(find.text('Загрузка')).dy),
    );
    expect(
      tester.getTopLeft(find.text('Загрузка')).dy,
      lessThan(tester.getTopLeft(find.text('По правилам')).dy),
    );
    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile('goldens/desktop_home.png'),
    );

    await tester.tap(find.text('Маршрутизация').first);
    await tester.pumpAndSettle();

    expect(find.text('Процессы Windows'), findsOneWidget);
    expect(find.text('Раздельное туннелирование'), findsNothing);
    expect(find.text('Глобально'), findsOneWidget);
    expect(find.text('По правилам'), findsNothing);
    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile('goldens/desktop_routing.png'),
    );

    await tester.tap(find.text('Процессы Windows'));
    await tester.pumpAndSettle();
    expect(find.text('steam.exe\nchrome.exe'), findsNWidgets(3));
    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile('goldens/desktop_routing_advanced.png'),
    );

    tester.state<NavigatorState>(find.byType(Navigator).last).pop();
    await tester.pumpAndSettle();

    await tester.tap(find.text('Подключения'));
    await tester.pump(const Duration(milliseconds: 1100));
    expect(find.text('Активных соединений нет'), findsOneWidget);

    await tester.tap(find.text('Логи'));
    await tester.pump(const Duration(milliseconds: 700));
    expect(find.text('Все уровни'), findsOneWidget);

    await tester.tap(find.text('Настройки'));
    await tester.pumpAndSettle();
    expect(find.text('Основные'), findsOneWidget);
    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile('goldens/desktop_settings.png'),
    );
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('Windows shell remains usable at its minimum window size', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    tester.view.physicalSize = const Size(720, 520);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    SharedPreferences.setMockInitialValues({});
    final preferences = await SharedPreferences.getInstance();

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          sharedPreferencesProvider.overrideWithValue(preferences),
          nozeltEngineProvider.overrideWithValue(_LayoutEngine()),
        ],
        child: const NozeltApp(),
      ),
    );
    await tester.pump(const Duration(milliseconds: 800));
    expect(tester.takeException(), isNull);

    await tester.tap(find.byIcon(Icons.alt_route_rounded).first);
    await tester.pumpAndSettle();
    expect(find.text('Процессы Windows'), findsOneWidget);
    expect(tester.takeException(), isNull);

    await tester.ensureVisible(find.byIcon(Icons.settings_rounded).first);
    await tester.tap(find.byIcon(Icons.settings_rounded).first);
    await tester.pumpAndSettle();
    expect(find.text('Основные'), findsOneWidget);
    expect(tester.takeException(), isNull);
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets(
    'Windows proxy profiles stay responsive at the minimum window size',
    (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);
      tester.view.physicalSize = const Size(720, 520);
      tester.view.devicePixelRatio = 1;
      subscriptionClock = () => DateTime(2026, 10, 22);
      addTearDown(() => subscriptionClock = DateTime.now);
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      SharedPreferences.setMockInitialValues({'onlineGeoIpEnabled': false});
      final preferences = await SharedPreferences.getInstance();

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            nozeltEngineProvider.overrideWithValue(_LayoutEngine()),
            sharedPreferencesProvider.overrideWithValue(preferences),
            profileStoreProvider.overrideWithValue(
              _MemoryProfileStore(_desktopProfilesFixture()),
            ),
          ],
          child: const NozeltApp(),
        ),
      );
      await tester.pump(const Duration(milliseconds: 800));
      await _loadDesktopImages(tester);

      await tester.tap(find.byIcon(Icons.dns_rounded));
      await tester.pumpAndSettle();

      expect(
        find.text('Очень длинное название основного Windows-профиля Nozelt'),
        findsOneWidget,
      );
      expect(find.text('Резервный профиль'), findsOneWidget);
      expect(
        find.text('Первая строка\nВторая строка описания профиля'),
        findsOneWidget,
      );
      // Subscription summary: traffic, days left and Telegram tiles.
      expect(find.text('Осталось'), findsOneWidget);
      expect(find.text('375 дней'), findsOneWidget);
      expect(find.text('01.11.2027'), findsOneWidget);
      expect(find.text('∞'), findsOneWidget);
      expect(find.text('Открыть в'), findsOneWidget);

      // Server-row buttons use the header's gap and share its right column.
      final headerPing = tester.getRect(
        find.byTooltip('Проверить все ноды').first,
      );
      final headerMore = tester.getRect(
        find.byTooltip('Настройки профиля').first,
      );
      final rowPing = tester.getRect(
        find.byTooltip('Проверить задержку').first,
      );
      final rowMore = tester.getRect(find.byTooltip('Настройки прокси').first);
      expect(rowMore.left - rowPing.right, headerMore.left - headerPing.right);
      expect(rowMore.size, headerMore.size);
      expect(rowMore.right, headerMore.right);

      expect(tester.takeException(), isNull);
      await expectLater(
        find.byType(MaterialApp),
        matchesGoldenFile('goldens/desktop_proxies_min.png'),
      );
      debugDefaultTargetPlatformOverride = null;
    },
  );
}

Future<void> _loadDesktopImages(WidgetTester tester) async {
  final context = tester.element(find.byType(MaterialApp));
  await tester.runAsync(() async {
    for (final path in [
      'assets/branding/nozelt_desktop_logo.png',
      'assets/branding/nozelt_new_logo.png',
      'assets/branding/nozelt_new_master_logo.png',
      'assets/flags/FI.png',
      'assets/flags/SE.png',
      'assets/flags/DE.png',
    ]) {
      await precacheImage(AssetImage(path), context);
    }
  });
  await tester.pump();
}
