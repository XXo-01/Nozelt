import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:nozelt/src/core/subscription_client.dart';

void main() {
  test('sends the standard x-hwid header with subscription requests', () async {
    late http.Request captured;
    final client = MockClient((request) async {
      captured = request;
      return http.Response('hysteria2://example', 200);
    });
    final subscriptions = SubscriptionClient(
      client: client,
      hwidLoader: () async => '4139def9-6877-4771-b313-49e3119ba158',
    );

    await subscriptions.download('https://panel.example/sub/token');

    expect(captured.headers['x-hwid'], '4139def9-6877-4771-b313-49e3119ba158');
  });

  test('omits malformed HWID values instead of injecting headers', () async {
    late http.Request captured;
    final client = MockClient((request) async {
      captured = request;
      return http.Response('hysteria2://example', 200);
    });
    final subscriptions = SubscriptionClient(
      client: client,
      hwidLoader: () async => 'bad\r\nInjected: value',
    );

    await subscriptions.download('https://panel.example/sub/token');

    expect(captured.headers, isNot(contains('x-hwid')));
  });

  test('captures standard subscription metadata headers', () async {
    final client = MockClient(
      (_) async => http.Response(
        'hysteria2://example',
        200,
        headers: {
          'profile-title': 'KRAKEN VPN',
          'subscription-userinfo':
              'upload=1024; download=2048; total=1073741824; expire=1784246400',
          'profile-description': 'Service news',
          'profile-web-page-url': 'https://t.me/kraken_vpn',
        },
      ),
    );

    final document = await SubscriptionClient(
      client: client,
    ).downloadDocument('https://panel.example/sub/token');

    expect(document.metadata.title, 'KRAKEN VPN');
    expect(document.metadata.usedBytes, 3072);
    expect(document.metadata.totalBytes, 1073741824);
    expect(document.metadata.expiresAt, isNotNull);
    expect(document.metadata.description, 'Service news');
    expect(document.metadata.telegramUrl, 'https://t.me/kraken_vpn');
  });

  test('preserves multiline base64 announcements', () async {
    final announcement = base64.encode(
      utf8.encode('Первая строка\nВторая строка\nТретья строка'),
    );
    final client = MockClient(
      (_) async => http.Response(
        'hysteria2://example',
        200,
        headers: {'announce': 'base64:$announcement'},
      ),
    );

    final document = await SubscriptionClient(
      client: client,
    ).downloadDocument('https://panel.example/sub/token');

    expect(
      document.metadata.description,
      'Первая строка\nВторая строка\nТретья строка',
    );
  });

  test('reads Happ metadata comments from the subscription body', () async {
    final announcement = base64.encode(utf8.encode('Строка 1\nСтрока 2'));
    final client = MockClient(
      (_) async => http.Response(
        '#profile-title: examplevpn\n'
        '#subscription-userinfo: upload=1073741824; download=536870912; total=0; expire=1784246400\n'
        '#support-url: https://t.me/examplevpn_bot\n'
        '#announce: base64:$announcement\n'
        'hysteria2://example',
        200,
      ),
    );

    final document = await SubscriptionClient(
      client: client,
    ).downloadDocument('https://panel.example/sub/token');

    expect(document.metadata.title, 'examplevpn');
    expect(document.metadata.usedBytes, 1610612736);
    expect(document.metadata.totalBytes, isNull);
    expect(document.metadata.description, 'Строка 1\nСтрока 2');
    expect(document.metadata.telegramUrl, 'https://t.me/examplevpn_bot');
  });

  test('rejects plaintext subscription URLs before network access', () async {
    const client = SubscriptionClient();

    await expectLater(
      client.download('http://panel.example/sub/secret-token'),
      throwsA(
        isA<SubscriptionException>()
            .having(
              (error) => error.message,
              'message',
              isNot(contains('secret-token')),
            )
            .having(
              (error) => error.l10nKey,
              'localization key',
              'subscriptionHttpsRequired',
            ),
      ),
    );
  });

  test('rejects HTTPS to HTTP redirect without exposing URL token', () async {
    var calls = 0;
    final client = MockClient((request) async {
      calls++;
      return http.Response(
        '',
        302,
        headers: {'location': 'http://unsafe.example/sub/secret-token'},
      );
    });
    final subscriptions = SubscriptionClient(client: client);

    await expectLater(
      subscriptions.download('https://panel.example/sub/secret-token'),
      throwsA(
        isA<SubscriptionException>()
            .having((error) => error.message, 'message', contains('insecure'))
            .having(
              (error) => error.message,
              'redacted message',
              isNot(contains('secret-token')),
            )
            .having(
              (error) => error.l10nKey,
              'localization key',
              'subscriptionRedirectInsecure',
            ),
      ),
    );
    expect(calls, 1);
  });

  test('rejects oversized decompressed subscription body', () async {
    final client = MockClient((_) async => http.Response('123456789', 200));
    final subscriptions = SubscriptionClient(
      client: client,
      maxResponseBytes: 8,
    );

    await expectLater(
      subscriptions.download('https://panel.example/sub/token'),
      throwsA(
        isA<SubscriptionException>()
            .having((error) => error.message, 'message', contains('size limit'))
            .having(
              (error) => error.l10nKey,
              'localization key',
              'subscriptionTooLarge',
            ),
      ),
    );
  });

  test('rejects control characters in a custom user agent', () async {
    const subscriptions = SubscriptionClient();

    await expectLater(
      subscriptions.download(
        'https://panel.example/sub/token',
        userAgent: 'Nozelt\r\nInjected: value',
      ),
      throwsA(
        isA<SubscriptionException>().having(
          (error) => error.l10nKey,
          'localization key',
          'subscriptionInvalidUserAgent',
        ),
      ),
    );
  });
}
