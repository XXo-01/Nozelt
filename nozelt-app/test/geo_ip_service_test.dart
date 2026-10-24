import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:nozelt/src/core/geo_ip_service.dart';
import 'package:nozelt/src/core/proxy_node.dart';

void main() {
  test('resolves the displayed server IP through encrypted DNS', () async {
    final requested = <Uri>[];
    final client = MockClient((request) async {
      requested.add(request.url);
      return http.Response(
        jsonEncode({
          'Status': 0,
          'Answer': [
            {'name': 'node.example', 'type': 1, 'data': '203.0.113.7'},
          ],
        }),
        200,
      );
    });

    final address = await GeoIpService(
      client: client,
    ).resolveServerAddress('node.example');

    expect(address, '203.0.113.7');
    expect(requested, hasLength(1));
    expect(requested.single.host, '1.1.1.1');
    expect(requested.single.queryParameters['type'], 'A');
  });

  test('displaying a literal server IP performs no DNS request', () async {
    var requested = false;
    final client = MockClient((request) async {
      requested = true;
      return http.Response('{}', 500);
    });

    final address = await GeoIpService(
      client: client,
    ).resolveServerAddress('2001:db8::7');

    expect(address, '2001:db8::7');
    expect(requested, isFalse);
  });

  test(
    'resolves hostname through DoH before geolocating the real IP',
    () async {
      final requested = <Uri>[];
      final client = MockClient((request) async {
        requested.add(request.url);
        if (request.url.host == '1.1.1.1') {
          expect(request.headers['accept'], 'application/dns-json');
          return http.Response(
            jsonEncode({
              'Status': 0,
              'Answer': [
                {'name': 'node.example', 'type': 1, 'data': '8.8.8.8'},
              ],
            }),
            200,
          );
        }
        expect(request.url.host, 'ipwho.is');
        expect(request.url.path, '/8.8.8.8');
        return http.Response(
          jsonEncode({'success': true, 'country_code': 'FI'}),
          200,
        );
      });
      final service = GeoIpService(client: client);
      final node = ProxyNode.fromRaw({
        'name': 'Helsinki',
        'type': 'hysteria2',
        'server': 'node.example',
        'port': 443,
        'password': 'not-logged',
      });

      expect(await service.detectCountry(node), 'FI');
      expect(requested, hasLength(2));
    },
  );

  test('does not disclose a private proxy address to GeoIP', () async {
    final requested = <Uri>[];
    final client = MockClient((request) async {
      requested.add(request.url);
      return http.Response('{}', 500);
    });
    final service = GeoIpService(client: client);
    final node = ProxyNode.fromRaw({
      'name': 'LAN gateway',
      'type': 'hysteria2',
      'server': '192.168.1.10',
      'port': 443,
    });

    expect(await service.detectCountry(node), isNull);
    expect(requested, isEmpty);
  });
}
