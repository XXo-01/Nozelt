import 'package:flutter_test/flutter_test.dart';
import 'package:nozelt/src/ui/profile_import_payload.dart';

void main() {
  test(
    'HTTPS subscriptions keep credentials and accept surrounding whitespace',
    () {
      final parsed = ProfileImportPayload.parse(
        '  https://example.test/sub/token?a=b\n',
      );
      expect(parsed.kind, ProfileImportKind.subscription);
      expect(parsed.text, 'https://example.test/sub/token?a=b');
    },
  );
  test('Share links are identified without touching the network', () {
    for (final scheme in [
      'vless',
      'vmess',
      'trojan',
      'ss',
      'ssr',
      'tuic',
      'hysteria',
      'hysteria2',
      'hy2',
      'anytls',
      'socks',
      'socks5',
      'socks4',
    ]) {
      expect(
        ProfileImportPayload.parse('$scheme://opaque-value').kind,
        ProfileImportKind.links,
      );
    }
    expect(
      ProfileImportPayload.parse('vless://one\r\n\nss://two').text,
      'vless://one\nss://two',
    );
  });
  test('Reject unrelated clipboard content without leaking it in errors', () {
    for (final text in [
      null,
      '',
      ' ',
      'secret unrelated text',
      'file:///secret',
      'javascript:alert(1)',
      'vless://',
      'https://',
      'https://example.test/a b',
      'https://example.test\nvless://one',
    ]) {
      expect(
        () => ProfileImportPayload.parse(text),
        throwsA(isA<ProfileImportException>()),
      );
    }
    expect(
      () => ProfileImportPayload.parse('http://example.test/secret'),
      throwsA(
        isA<ProfileImportException>().having(
          (e) => e.messageKey,
          'safe error key',
          'subscriptionHttpsRequired',
        ),
      ),
    );
  });
  test('Keep existing import bounds for both URL and share links', () {
    expect(
      () => ProfileImportPayload.parse('https://example.test/${'a' * 8192}'),
      throwsA(isA<ProfileImportException>()),
    );
    expect(
      () => ProfileImportPayload.parse(
        'vless://${'a' * ProfileImportPayload.maxCharacters}',
      ),
      throwsA(
        isA<ProfileImportException>().having(
          (e) => e.messageKey,
          'limit',
          'proxyDataTooLarge',
        ),
      ),
    );
  });
}
