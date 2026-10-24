import 'package:flutter_test/flutter_test.dart';
import 'package:nozelt/src/core/proxy_node.dart';

void main() {
  ProxyNode node(String name) => ProxyNode.fromRaw({
    'name': name,
    'type': 'hysteria2',
    'server': 'vpn.example',
    'port': 443,
  });

  test('extracts and removes leading country flag', () {
    final parsed = node('🇫🇮 Finland VPN');
    expect(parsed.embeddedCountryCode, 'FI');
    expect(parsed.displayName, 'Finland VPN');
    expect(parsed.flagEmoji, '🇫🇮');
  });

  test('extracts a flag token after a space and manual override wins', () {
    final parsed = node(
      'Fast 🇩🇪 Germany',
    ).copyWith(detectedCountryCode: 'NL', countryCodeOverride: 'US');
    expect(parsed.displayName, 'Fast Germany');
    expect(parsed.embeddedCountryCode, 'DE');
    expect(parsed.countryCode, 'US');
    expect(parsed.flagEmoji, '🇺🇸');
  });

  test('persists country metadata but treats latency as volatile', () {
    final original = node('Helsinki').copyWith(
      detectedCountryCode: 'FI',
      lastDelayMs: 123,
      lastDelayAt: DateTime.utc(2026, 7, 13),
    );
    final restored = ProxyNode.fromJson(original.toJson());
    expect(restored.countryCode, 'FI');
    expect(restored.lastDelayMs, isNull);
    expect(restored.lastDelayAt, isNull);
  });

  test('normalizes reserved, duplicate, and empty mihomo names', () {
    ProxyNode node(String name) => ProxyNode(
      name: name,
      type: 'hysteria2',
      server: 'vpn.example',
      port: 443,
      raw: {
        'name': name,
        'type': 'hysteria2',
        'server': 'vpn.example',
        'port': 443,
      },
    );

    final normalized = ProxyNode.normalizeNames([
      node('PROXY'),
      node('Helsinki'),
      node('helsinki'),
      node('  \u0000  '),
    ]);

    expect(normalized.map((value) => value.name), [
      'PROXY (node)',
      'Helsinki',
      'helsinki (2)',
      'Proxy 4',
    ]);
    expect(
      normalized.map((value) => value.raw['name']),
      normalized.map((value) => value.name),
    );
  });

  test('bounds subscription-controlled proxy names', () {
    final node = ProxyNode.fromRaw({
      'name': List.filled(10000, 'x').join(),
      'type': 'direct',
      'server': '127.0.0.1',
      'port': 1,
    });

    final normalized = ProxyNode.normalizeNames([node]).single;
    expect(normalized.name.runes.length, lessThanOrEqualTo(128));
    expect(normalized.raw['name'], normalized.name);
    expect(normalized.isUsableOutbound, isFalse);
  });

  test('rejects pseudo-outbounds and malformed remote endpoints', () {
    expect(
      ProxyNode.fromRaw({
        'name': 'Bypass',
        'type': 'DIRECT',
        'server': '127.0.0.1',
        'port': 1,
      }).isUsableOutbound,
      isFalse,
    );
    expect(
      ProxyNode.fromRaw({
        'name': 'Broken',
        'type': 'hysteria2',
        'server': '',
        'port': 0,
      }).isUsableOutbound,
      isFalse,
    );
    expect(node('Remote').isUsableOutbound, isTrue);
  });

  test('raw mihomo endpoint must agree with validated display fields', () {
    final disguisedDirect = ProxyNode(
      name: 'Disguised bypass',
      type: 'hysteria2',
      server: 'vpn.example',
      port: 443,
      raw: const {
        'name': 'Disguised bypass',
        'type': 'direct',
        'server': 'vpn.example',
        'port': 443,
      },
    );
    final mismatchedEndpoint = ProxyNode(
      name: 'Mismatch',
      type: 'hysteria2',
      server: 'vpn.example',
      port: 443,
      raw: const {
        'name': 'Mismatch',
        'type': 'hysteria2',
        'server': 'other.example',
        'port': 443,
      },
    );

    expect(disguisedDirect.isUsableOutbound, isFalse);
    expect(mismatchedEndpoint.isUsableOutbound, isFalse);
  });
}
