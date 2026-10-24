import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:nozelt/nozelt_design_system.dart';
import 'package:nozelt/src/core/nozelt_engine.dart';
import 'package:nozelt/src/core/profile.dart';
import 'package:nozelt/src/core/subscription_client.dart';
import 'package:nozelt/src/data/profile_store.dart';
import 'package:nozelt/src/state/engine_provider.dart';
import 'package:nozelt/src/state/profiles_provider.dart';
import 'package:nozelt/src/ui/add_profile_screen.dart';
import 'support/ui_audit_fixtures.dart';

class _Store extends ProfileStore {
  ProfilesState saved = const ProfilesState(profiles: []);
  @override
  Future<ProfilesState> load() async => saved;
  @override
  Future<void> save(ProfilesState value) async {
    saved = value;
  }
}

class _Engine extends AuditEngine {
  final parsed = <String>[];
  @override
  Future<ParsedSubscription> parseSubscriptionDocument(String content) async {
    parsed.add(content);
    return ParsedSubscription(
      nodes: auditProfiles().profiles.first.nodes,
      metadata: const SubscriptionMetadata(),
    );
  }
}

void main() {
  testWidgets(
    'Opening the form never reads the clipboard; invalid paste stays local',
    (tester) async {
      final store = _Store(), engine = _Engine();
      var reads = 0, requests = 0;
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          if (call.method == 'Clipboard.getData') {
            reads++;
            return {'text': 'private unrelated content'};
          }
          return null;
        },
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          null,
        ),
      );
      await _boot(
        tester,
        store,
        engine,
        MockClient((_) async {
          requests++;
          return http.Response('', 200);
        }),
      );
      expect(reads, 0);
      await tester.tap(find.text('Из буфера'));
      await tester.pumpAndSettle();
      expect(reads, 1);
      expect(requests, 0);
      expect(engine.parsed, isEmpty);
      expect(store.saved.profiles, isEmpty);
      expect(
        find.text('Нужна HTTPS-ссылка подписки или ссылка прокси.'),
        findsOneWidget,
      );
      expect(find.textContaining('User-Agent'), findsNothing);
      expect(find.text('Название (опционально)'), findsOneWidget);
      expect(
        find.text('Оставьте пустым для автоматического названия'),
        findsNothing,
      );
    },
  );
  for (final subscription in [false, true]) {
    testWidgets(
      'One click imports ${subscription ? 'subscription' : 'share link'} and does not duplicate pending work',
      (tester) async {
        final store = _Store(), engine = _Engine();
        final clipboard = Completer<Map<String, dynamic>>();
        var reads = 0, requests = 0;
        tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          (call) async {
            if (call.method == 'Clipboard.getData') {
              reads++;
              return clipboard.future;
            }
            return null;
          },
        );
        addTearDown(
          () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
            SystemChannels.platform,
            null,
          ),
        );
        await _boot(
          tester,
          store,
          engine,
          MockClient((request) async {
            requests++;
            return http.Response('vless://server', 200);
          }),
        );
        final action = tester.widget<NozeltProfileImportActions>(
          find.byType(NozeltProfileImportActions),
        );
        action.onPaste!();
        action.onPaste!();
        expect(reads, 1);
        clipboard.complete({
          'text': subscription ? 'https://example.test/sub' : 'vless://server',
        });
        await tester.pumpAndSettle();
        expect(store.saved.profiles, hasLength(1));
        expect(engine.parsed, subscription ? isNotEmpty : hasLength(1));
        expect(requests, subscription ? greaterThanOrEqualTo(1) : 0);
        expect(tester.takeException(), isNull);
      },
    );
  }
  testWidgets('Closing the form while clipboard access is pending is safe', (
    tester,
  ) async {
    final clipboard = Completer<Map<String, dynamic>>();
    final store = _Store(), engine = _Engine();
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async =>
          call.method == 'Clipboard.getData' ? clipboard.future : null,
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      ),
    );
    await _boot(
      tester,
      store,
      engine,
      MockClient((_) async => http.Response('', 200)),
    );
    await tester.tap(find.text('Из буфера'));
    await tester.pumpWidget(const SizedBox.shrink());
    clipboard.complete({'text': 'vless://server'});
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(store.saved.profiles, isEmpty);
  });
}

Future<void> _boot(
  WidgetTester tester,
  _Store store,
  _Engine engine,
  http.Client client,
) async {
  final container = ProviderContainer(
    overrides: [
      profileStoreProvider.overrideWithValue(store),
      nozeltEngineProvider.overrideWithValue(engine),
      subscriptionClientProvider.overrideWithValue(
        SubscriptionClient(client: client),
      ),
    ],
  );
  addTearDown(container.dispose);
  await container.read(profilesProvider.future);
  final navigator = GlobalKey<NavigatorState>();
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        navigatorKey: navigator,
        theme: NozeltTheme.forPlatform(TargetPlatform.windows),
        locale: const Locale('ru'),
        supportedLocales: const [Locale('ru'), Locale('en')],
        localizationsDelegates: GlobalMaterialLocalizations.delegates,
        home: const Scaffold(body: Text('Profiles')),
      ),
    ),
  );
  navigator.currentState!.push(
    MaterialPageRoute<void>(builder: (_) => const AddProfileScreen()),
  );
  await tester.pumpAndSettle();
}
