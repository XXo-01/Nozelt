import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import 'proxy_node.dart';

class GeoIpService {
  const GeoIpService({http.Client? client}) : _client = client;

  final http.Client? _client;

  static const int _maxJsonBytes = 64 * 1024;

  /// Resolves the proxy endpoint through the same encrypted DNS path used by
  /// country detection. Literal IPv4/IPv6 endpoints never cause a network
  /// request. This is display metadata only and is not persisted.
  Future<String?> resolveServerAddress(String server) async {
    final hostname = server.trim();
    if (hostname.isEmpty) return null;
    final literal = InternetAddress.tryParse(hostname);
    if (literal != null) return literal.address;

    final client = _client ?? http.Client();
    final ownsClient = _client == null;
    try {
      return (await _resolveHostname(client, hostname)).address;
    } catch (_) {
      return null;
    } finally {
      if (ownsClient) client.close();
    }
  }

  /// Uses encrypted DNS for hostnames, then asks ipwho.is only for the ISO
  /// country code. Callers persist the result so a node normally costs one
  /// lookup. This path is opt-in in privacy settings.
  Future<String?> detectCountry(ProxyNode node) async {
    if (node.embeddedCountryCode != null ||
        node.countryCodeOverride != null ||
        node.detectedCountryCode != null) {
      return node.countryCode;
    }

    final client = _client ?? http.Client();
    final ownsClient = _client == null;
    try {
      final ip =
          InternetAddress.tryParse(node.server) ??
          await _resolveHostname(client, node.server);
      // Never send LAN, loopback, link-local, documentation, benchmark, or
      // multicast addresses to the external GeoIP provider. Apart from having
      // no useful country, doing so would disclose private network structure
      // for an opt-in feature that is meant to reveal only a public exit host.
      if (!_isPublicInternetAddress(ip)) return null;
      final uri = Uri.https('ipwho.is', '/${ip.address}', {
        'fields': 'success,country_code',
      });
      final json = await _getJson(client, uri);
      if (json['success'] != true) return null;
      final code = json['country_code']?.toString().trim().toUpperCase();
      return code != null && RegExp(r'^[A-Z]{2}$').hasMatch(code) ? code : null;
    } catch (_) {
      return null;
    } finally {
      if (ownsClient) client.close();
    }
  }

  static bool _isPublicInternetAddress(InternetAddress address) {
    final bytes = address.rawAddress;
    if (address.type == InternetAddressType.IPv4 && bytes.length == 4) {
      final value = bytes.fold<int>(0, (result, byte) => (result << 8) | byte);
      bool inCidr(int network, int prefix) {
        final mask = prefix == 0
            ? 0
            : (0xffffffff << (32 - prefix)) & 0xffffffff;
        return value & mask == network & mask;
      }

      return !inCidr(0x00000000, 8) &&
          !inCidr(0x0a000000, 8) &&
          !inCidr(0x64400000, 10) &&
          !inCidr(0x7f000000, 8) &&
          !inCidr(0xa9fe0000, 16) &&
          !inCidr(0xac100000, 12) &&
          !inCidr(0xc0000000, 24) &&
          !inCidr(0xc0000200, 24) &&
          !inCidr(0xc0a80000, 16) &&
          !inCidr(0xc6120000, 15) &&
          !inCidr(0xc6336400, 24) &&
          !inCidr(0xcb007100, 24) &&
          !inCidr(0xe0000000, 4) &&
          !inCidr(0xf0000000, 4);
    }
    if (address.type == InternetAddressType.IPv6 && bytes.length == 16) {
      final allZero = bytes.every((byte) => byte == 0);
      final loopback =
          bytes.take(15).every((byte) => byte == 0) && bytes[15] == 1;
      final uniqueLocal = bytes[0] & 0xfe == 0xfc;
      final linkLocal = bytes[0] == 0xfe && bytes[1] & 0xc0 == 0x80;
      final multicast = bytes[0] == 0xff;
      final documentation =
          bytes[0] == 0x20 &&
          bytes[1] == 0x01 &&
          bytes[2] == 0x0d &&
          bytes[3] == 0xb8;
      final globalUnicast = bytes[0] & 0xe0 == 0x20;
      return globalUnicast &&
          !allZero &&
          !loopback &&
          !uniqueLocal &&
          !linkLocal &&
          !multicast &&
          !documentation;
    }
    return false;
  }

  Future<InternetAddress> _resolveHostname(
    http.Client client,
    String hostname,
  ) async {
    final uri = Uri.https('1.1.1.1', '/dns-query', {
      'name': hostname,
      'type': 'A',
    });
    final json = await _getJson(
      client,
      uri,
      headers: {'accept': 'application/dns-json'},
    );
    final answers = (json['Answer'] as List?) ?? const [];
    for (final value in answers) {
      if (value is! Map || value['type'] != 1) continue;
      final address = InternetAddress.tryParse(value['data']?.toString() ?? '');
      if (address?.type == InternetAddressType.IPv4) return address!;
    }
    throw const SocketException('secure DNS returned no IPv4 address');
  }

  Future<Map<String, dynamic>> _getJson(
    http.Client client,
    Uri uri, {
    Map<String, String> headers = const {},
  }) async {
    final request = http.Request('GET', uri)
      ..followRedirects = false
      ..headers.addAll(headers);
    final response = await client
        .send(request)
        .timeout(const Duration(seconds: 7));
    if (response.statusCode != 200) {
      await response.stream.listen((_) {}).cancel();
      throw const HttpException('online metadata request failed');
    }

    final bytes = BytesBuilder(copy: false);
    var length = 0;
    await for (final chunk in response.stream.timeout(
      const Duration(seconds: 7),
    )) {
      length += chunk.length;
      if (length > _maxJsonBytes) {
        throw const HttpException('online metadata response too large');
      }
      bytes.add(chunk);
    }
    return jsonDecode(utf8.decode(bytes.takeBytes())) as Map<String, dynamic>;
  }
}
