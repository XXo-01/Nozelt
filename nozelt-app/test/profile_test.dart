import 'package:flutter_test/flutter_test.dart';
import 'package:nozelt/src/core/profile.dart';
import 'package:nozelt/src/core/proxy_node.dart';

void main() {
  test('profile names are bounded and stripped of control characters', () {
    final input = '  Unsafe\u0000 ${List.filled(200, 'x').join()}  ';
    final normalized = normalizeProfileName(input);

    expect(normalized, isNot(contains('\u0000')));
    expect(normalized.runes.length, lessThanOrEqualTo(maxProfileNameRunes));
  });

  test('repairs UTF-8 profile names decoded as Windows-1251', () {
    const mojibake = '\u0432\u0098\u00a0\u043f\u0451\u040f KRAKEN VPN';

    expect(normalizeProfileName(mojibake), '☠️ KRAKEN VPN');
  });

  test(
    'legacy subscription host names remain eligible for provider titles',
    () {
      final profile = Profile.fromJson({
        'id': 'legacy',
        'name': 'panel.example',
        'type': 'subscription',
        'source': 'https://panel.example/sub/token',
        'nodes': const [],
      });

      expect(profile.nameCustomized, isFalse);
    },
  );

  test('topology revision survives persistence and metadata copies', () {
    const node = ProxyNode(
      name: 'Helsinki',
      type: 'hysteria2',
      server: 'vpn.example',
      port: 443,
      raw: {
        'name': 'Helsinki',
        'type': 'hysteria2',
        'server': 'vpn.example',
        'port': 443,
      },
    );
    const profile = Profile(
      id: 'profile',
      name: 'Finland',
      type: ProfileType.manual,
      source: '',
      nodes: [node],
      topologyRevision: 7,
    );

    expect(profile.copyWith(name: 'Renamed').topologyRevision, 7);
    expect(Profile.fromJson(profile.toJson()).topologyRevision, 7);
  });

  test('pinned state survives persistence and metadata copies', () {
    const profile = Profile(
      id: 'profile',
      name: 'Finland',
      type: ProfileType.manual,
      source: '',
      nodes: [],
    );

    final pinned = profile.copyWith(pinned: true);

    expect(pinned.pinned, isTrue);
    expect(Profile.fromJson(pinned.toJson()).pinned, isTrue);
  });

  test('migrates hourly refresh and preserves the 30-minute preset', () {
    final legacy = Profile.fromJson({
      'id': 'legacy',
      'name': 'Legacy',
      'type': 'subscription',
      'source': 'https://example.com/sub',
      'nodes': const [],
      'autoUpdateHours': 6,
    });
    expect(legacy.autoUpdateMinutes, 360);

    const halfHourly = Profile(
      id: 'half-hour',
      name: 'Half hour',
      type: ProfileType.subscription,
      source: 'https://example.com/sub',
      nodes: [],
      autoUpdateMinutes: 30,
    );
    expect(Profile.fromJson(halfHourly.toJson()).autoUpdateMinutes, 30);
  });

  test('subscription refresh inherits metadata only for the same node', () {
    final checkedAt = DateTime.utc(2026, 7, 13);
    final previous = ProxyNode(
      name: 'Helsinki',
      type: 'hysteria2',
      server: 'old.example',
      port: 443,
      raw: const {
        'name': 'Helsinki',
        'type': 'hysteria2',
        'server': 'old.example',
        'port': 443,
      },
      detectedCountryCode: 'FI',
      countryCodeOverride: 'SE',
      lastDelayMs: 42,
      lastDelayAt: checkedAt,
    );
    const same = ProxyNode(
      name: 'Helsinki',
      type: 'hysteria2',
      server: 'old.example',
      port: 443,
      raw: {
        'name': 'Helsinki',
        'type': 'hysteria2',
        'server': 'old.example',
        'port': 443,
        'password': 'rotated',
      },
    );
    const replacement = ProxyNode(
      name: 'Helsinki',
      type: 'hysteria2',
      server: 'new.example',
      port: 443,
      raw: {
        'name': 'Helsinki',
        'type': 'hysteria2',
        'server': 'new.example',
        'port': 443,
      },
    );

    final inherited = inheritProxyMetadata([previous], [same]).single;
    final clean = inheritProxyMetadata([previous], [replacement]).single;

    expect(inherited.countryCodeOverride, 'SE');
    expect(inherited.lastDelayMs, 42);
    expect(inherited.lastDelayAt, checkedAt);
    expect(inherited.raw['password'], 'rotated');
    expect(clean.countryCodeOverride, isNull);
    expect(clean.lastDelayMs, isNull);
  });
}
