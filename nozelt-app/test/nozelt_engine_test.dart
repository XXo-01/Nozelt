import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nozelt/src/core/nozelt_engine.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('dev.nozelt.nozelt/engine-test');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  tearDown(() {
    messenger.setMockMethodCallHandler(channel, null);
  });

  test('native document picker returns a bounded typed config file', () async {
    final expected = Uint8List.fromList([1, 2, 3, 4]);
    messenger.setMockMethodCallHandler(channel, (call) async {
      expect(call.method, 'pickConfigFile');
      return <String, Object>{'name': 'profile.yaml', 'bytes': expected};
    });

    final picked = await NozeltEngine(methodChannel: channel).pickConfigFile();

    expect(picked?.name, 'profile.yaml');
    expect(picked?.bytes, expected);
  });

  test('cancelled native document picker returns null', () async {
    messenger.setMockMethodCallHandler(channel, (_) async => null);

    final picked = await NozeltEngine(methodChannel: channel).pickConfigFile();

    expect(picked, isNull);
  });

  test(
    'document picker platform errors keep only a safe crash string',
    () async {
      messenger.setMockMethodCallHandler(channel, (_) async {
        throw PlatformException(
          code: 'file_read_failed',
          message: 'https://user:secret@provider.example/private',
        );
      });

      final operation = NozeltEngine(methodChannel: channel).pickConfigFile();

      await expectLater(
        operation,
        throwsA(
          isA<NozeltEngineException>()
              .having((error) => error.code, 'code', 'file_read_failed')
              .having(
                (error) => error.toString(),
                'safe string',
                'NozeltEngineException(pickConfigFile, file_read_failed)',
              ),
        ),
      );
    },
  );

  test('malformed document picker payload is rejected', () async {
    messenger.setMockMethodCallHandler(channel, (_) async {
      return <String, Object>{'name': 'profile.yaml', 'bytes': 'not bytes'};
    });

    expect(
      NozeltEngine(methodChannel: channel).pickConfigFile(),
      throwsFormatException,
    );
  });

  test('app icons cross the platform channel as raw bytes', () async {
    final expected = Uint8List.fromList([0x89, 0x50, 0x4e, 0x47]);
    messenger.setMockMethodCallHandler(channel, (call) async {
      expect(call.method, 'getAppIcon');
      return expected;
    });

    final bytes = await NozeltEngine(
      methodChannel: channel,
    ).getAppIcon('org.example.app');

    expect(bytes, expected);
  });

  test('background latency cancellation crosses the native channel', () async {
    messenger.setMockMethodCallHandler(channel, (call) async {
      expect(call.method, 'cancelDelayTests');
      return true;
    });

    expect(
      await NozeltEngine(methodChannel: channel).cancelProxyDelayTests(),
      isTrue,
    );
  });

  test(
    'notification latency includes its measurement time and lifetime',
    () async {
      final measuredAt = DateTime.utc(2026, 8, 25, 12, 30);
      messenger.setMockMethodCallHandler(channel, (call) async {
        expect(call.method, 'updateVpnNotification');
        expect(call.arguments, {
          'flag': '🇱🇻',
          'serverName': 'Latvia',
          'pingMs': 87,
          'pingMeasuredAtMs': measuredAt.millisecondsSinceEpoch,
          'pingMaxAgeMs': const Duration(minutes: 2).inMilliseconds,
        });
        return true;
      });

      expect(
        await NozeltEngine(methodChannel: channel).updateVpnNotification(
          flag: '🇱🇻',
          serverName: 'Latvia',
          pingMs: 87,
          updatePing: true,
          pingMeasuredAt: measuredAt,
          pingMaxAge: const Duration(minutes: 2),
        ),
        isTrue,
      );
    },
  );

  test(
    'subscription envelopes decode off-isolate into normalized nodes',
    () async {
      messenger.setMockMethodCallHandler(channel, (call) async {
        expect(call.method, 'parseSubscription');
        return jsonEncode({
          'ok': true,
          'profileName': '☠️ KRAKEN VPN',
          'description': 'Service news',
          'webPageUrl': 'https://t.me/kraken_vpn',
          'proxies': [
            {
              'name': 'Node',
              'type': 'hysteria2',
              'server': 'one.example',
              'port': 443,
            },
            {
              'name': 'Node',
              'type': 'vless',
              'server': 'two.example',
              'port': 443,
            },
          ],
        });
      });

      final parsed = await NozeltEngine(
        methodChannel: channel,
      ).parseSubscriptionDocument('credential-bearing input');

      expect(parsed.nodes.map((node) => node.name), ['Node', 'Node (2)']);
      expect(parsed.metadata.title, '☠️ KRAKEN VPN');
      expect(parsed.metadata.description, 'Service news');
      expect(parsed.metadata.telegramUrl, 'https://t.me/kraken_vpn');
    },
  );
}
