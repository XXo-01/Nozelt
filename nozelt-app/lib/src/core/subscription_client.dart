import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import 'profile.dart';
import 'vpn_core.dart';

class SubscriptionDocument {
  const SubscriptionDocument({
    required this.content,
    this.metadata = const SubscriptionMetadata(),
  });

  final String content;
  final SubscriptionMetadata metadata;
}

/// Downloads subscription URLs. The URL is a credential and is never logged
/// or included in user-facing exception messages.
class SubscriptionClient {
  const SubscriptionClient({
    this.timeout = const Duration(seconds: 30),
    this.maxResponseBytes = 16 * 1024 * 1024,
    http.Client? client,
    Future<String?> Function()? hwidLoader,
  }) : _client = client,
       _hwidLoader = hwidLoader;

  final Duration timeout;
  final int maxResponseBytes;
  final http.Client? _client;
  final Future<String?> Function()? _hwidLoader;

  static const String defaultUserAgent = 'clash-meta';
  static const String xrayUserAgent = 'Happ/3.26.3/';
  static const String singBoxUserAgent =
      'SFA/1.14.1 (11401; sing-box 1.14.1; language ru_RU)';
  static const int _maxRedirects = 5;
  static const int _maxUrlCharacters = 8192;
  static const int _maxUserAgentCharacters = 256;

  static String userAgentForCore(VpnCore core) => switch (core) {
    VpnCore.mihomo => defaultUserAgent,
    VpnCore.xray => xrayUserAgent,
    VpnCore.singBox => singBoxUserAgent,
  };

  Future<String> download(String url, {String? userAgent}) async =>
      (await downloadDocument(url, userAgent: userAgent)).content;

  Future<SubscriptionDocument> downloadDocument(
    String url, {
    String? userAgent,
  }) async {
    if (url.length > _maxUrlCharacters) {
      throw const SubscriptionException(
        'Invalid subscription URL.',
        l10nKey: 'subscriptionInvalidUrl',
      );
    }
    final Uri uri;
    try {
      uri = Uri.parse(url);
    } catch (_) {
      throw const SubscriptionException(
        'Invalid subscription URL.',
        l10nKey: 'subscriptionInvalidUrl',
      );
    }
    if (!uri.hasScheme || !uri.isScheme('https')) {
      throw const SubscriptionException(
        'Subscription URL must use HTTPS.',
        l10nKey: 'subscriptionHttpsRequired',
      );
    }
    if (uri.host.isEmpty) {
      throw const SubscriptionException(
        'Invalid subscription URL.',
        l10nKey: 'subscriptionInvalidUrl',
      );
    }
    final effectiveUserAgent = userAgent ?? defaultUserAgent;
    if (effectiveUserAgent.length > _maxUserAgentCharacters ||
        effectiveUserAgent.codeUnits.any(
          (value) => value < 0x20 || value == 0x7f,
        )) {
      throw const SubscriptionException(
        'Invalid subscription user agent.',
        l10nKey: 'subscriptionInvalidUserAgent',
      );
    }

    final hwid = await _loadHwid();
    final client = _client ?? http.Client();
    final ownsClient = _client == null;
    try {
      var current = uri;
      for (var redirects = 0; redirects <= _maxRedirects; redirects++) {
        final request = http.Request('GET', current)
          ..followRedirects = false
          ..headers['User-Agent'] = effectiveUserAgent;
        if (hwid != null) request.headers['x-hwid'] = hwid;
        final response = await client.send(request).timeout(timeout);

        if (_isRedirect(response.statusCode)) {
          final location = response.headers['location'];
          await response.stream.listen((_) {}).cancel();
          if (location == null || redirects == _maxRedirects) {
            throw const SubscriptionException(
              'Subscription redirect was invalid or excessive.',
              l10nKey: 'subscriptionRedirectInvalid',
            );
          }
          final next = current.resolve(location);
          if (!next.isScheme('https')) {
            throw const SubscriptionException(
              'Subscription redirect refused an insecure destination.',
              l10nKey: 'subscriptionRedirectInsecure',
            );
          }
          if (next.host.isEmpty || next.toString().length > _maxUrlCharacters) {
            throw const SubscriptionException(
              'Subscription redirect was invalid or excessive.',
              l10nKey: 'subscriptionRedirectInvalid',
            );
          }
          current = next;
          continue;
        }

        if (response.statusCode < 200 || response.statusCode >= 300) {
          await response.stream.listen((_) {}).cancel();
          throw SubscriptionException(
            'Server returned HTTP ${response.statusCode}.',
            l10nKey: 'subscriptionHttpError',
            statusCode: response.statusCode,
          );
        }
        final declaredLength = int.tryParse(
          response.headers['content-length'] ?? '',
        );
        if (declaredLength != null && declaredLength > maxResponseBytes) {
          await response.stream.listen((_) {}).cancel();
          throw const SubscriptionException(
            'Subscription response exceeded the safe size limit.',
            l10nKey: 'subscriptionTooLarge',
          );
        }
        final body = await _readLimited(response).timeout(timeout);
        if (body.trim().isEmpty) {
          throw const SubscriptionException(
            'Subscription response was empty.',
            l10nKey: 'subscriptionEmpty',
          );
        }
        return SubscriptionDocument(
          content: body,
          // Providers commonly expose Happ/Clash metadata either as response
          // headers or as leading "#key: value" lines. Header values win,
          // while body metadata fills fields omitted by the server.
          metadata: _metadataFromBody(
            body,
          ).merge(_metadataFromHeaders(response.headers)),
        );
      }
      throw const SubscriptionException(
        'Subscription redirect limit exceeded.',
        l10nKey: 'subscriptionRedirectInvalid',
      );
    } on SubscriptionException {
      rethrow;
    } catch (_) {
      // Client exceptions frequently embed the complete URI and secret token.
      throw const SubscriptionException(
        'Download failed. Check the network and TLS certificate.',
        l10nKey: 'subscriptionDownloadFailed',
      );
    } finally {
      if (ownsClient) client.close();
    }
  }

  Future<String> _readLimited(http.StreamedResponse response) async {
    final bytes = BytesBuilder(copy: false);
    var length = 0;
    await for (final chunk in response.stream) {
      length += chunk.length;
      if (length > maxResponseBytes) {
        throw const SubscriptionException(
          'Subscription response exceeded the safe size limit.',
          l10nKey: 'subscriptionTooLarge',
        );
      }
      bytes.add(chunk);
    }
    return utf8.decode(bytes.takeBytes(), allowMalformed: true);
  }

  Future<String?> _loadHwid() async {
    final loader = _hwidLoader;
    if (loader == null) return null;
    try {
      final value = (await loader())?.trim();
      if (value == null ||
          value.isEmpty ||
          value.length > 36 ||
          !RegExp(r'^[A-Za-z0-9._:-]+$').hasMatch(value)) {
        return null;
      }
      return value;
    } catch (_) {
      // Device identity is a compatibility hint. A transient platform
      // failure must not prevent subscriptions that do not require HWID.
      return null;
    }
  }

  static bool _isRedirect(int statusCode) =>
      statusCode == 301 ||
      statusCode == 302 ||
      statusCode == 303 ||
      statusCode == 307 ||
      statusCode == 308;

  static SubscriptionMetadata _metadataFromHeaders(
    Map<String, String> headers,
  ) => _metadataFromMap(headers);

  static SubscriptionMetadata _metadataFromBody(String body) {
    final values = <String, String>{};
    for (final rawLine in const LineSplitter().convert(body).take(32)) {
      var line = rawLine.trimLeft();
      if (!line.startsWith('#')) continue;
      line = line.substring(1).trimLeft();
      final separator = line.indexOf(':');
      if (separator <= 0) continue;
      final key = line.substring(0, separator).trim().toLowerCase();
      if (!_bodyMetadataKeys.contains(key)) continue;
      final value = line.substring(separator + 1).trim();
      if (value.isNotEmpty) values[key] = value;
    }
    return _metadataFromMap(values);
  }

  static const _bodyMetadataKeys = <String>{
    'profile-title',
    'profile-description',
    'subscription-description',
    'announce',
    'subscription-userinfo',
    'profile-web-page-url',
    'support-url',
  };

  static SubscriptionMetadata _metadataFromMap(Map<String, String> values) {
    final usage = <String, int>{};
    for (final part in (values['subscription-userinfo'] ?? '').split(';')) {
      final separator = part.indexOf('=');
      if (separator <= 0) continue;
      final key = part.substring(0, separator).trim().toLowerCase();
      final value = int.tryParse(part.substring(separator + 1).trim());
      if (value != null && value >= 0) usage[key] = value;
    }

    final title = _decodeMetadataText(values['profile-title'], 96);
    final description = _decodeMetadataText(
      values['profile-description'] ??
          values['subscription-description'] ??
          values['announce'],
      maxSubscriptionDescriptionRunes,
    );
    final webPage = _safeHttpsUrl(
      values['support-url'] ??
          values['profile-web-page-url'] ??
          _telegramUrlFromText(description),
    );
    final expires = usage['expire'];
    final total = usage['total'];
    DateTime? expiresAt;
    if (expires != null && expires > 0) {
      try {
        expiresAt = DateTime.fromMillisecondsSinceEpoch(
          expires * 1000,
          isUtc: true,
        ).toLocal();
      } catch (_) {
        expiresAt = null;
      }
    }

    return SubscriptionMetadata(
      title: title,
      uploadBytes: usage['upload'],
      downloadBytes: usage['download'],
      totalBytes: total != null && total > 0 ? total : null,
      expiresAt: expiresAt,
      description: description,
      webPageUrl: webPage,
    );
  }

  static String? _decodeMetadataText(String? value, int maxRunes) {
    var text = value?.trim() ?? '';
    if (text.isEmpty) return null;
    if (text.toLowerCase().startsWith('base64:')) {
      try {
        text = utf8.decode(base64.decode(text.substring(7).trim()));
      } catch (_) {
        return null;
      }
    } else if (text.contains('%')) {
      try {
        text = Uri.decodeComponent(text);
      } catch (_) {
        // Keep the original header when it merely contains a literal percent.
      }
    }
    text = text
        .replaceAll('\r\n', '\n')
        .replaceAll('\r', '\n')
        .replaceAll(
          RegExp(r'[\u0000-\u0008\u000b\u000c\u000e-\u001f\u007f]'),
          ' ',
        );
    text = text
        .split('\n')
        .map((line) => line.replaceAll(RegExp(r'[ \t]+'), ' ').trim())
        .join('\n')
        .replaceAll(RegExp(r'\n{3,}'), '\n\n')
        .trim();
    if (text.isEmpty) return null;
    return String.fromCharCodes(text.runes.take(maxRunes));
  }

  static String? _safeHttpsUrl(String? value) {
    final text = value?.trim();
    if (text == null || text.isEmpty || text.length > _maxUrlCharacters) {
      return null;
    }
    final uri = Uri.tryParse(text);
    return uri != null && uri.isScheme('https') && uri.host.isNotEmpty
        ? uri.toString()
        : null;
  }

  static String? _telegramUrlFromText(String? value) {
    if (value == null) return null;
    return RegExp(
      r'https://(?:t\.me|telegram\.me)/[^\s<>()]+',
      caseSensitive: false,
    ).firstMatch(value)?.group(0);
  }
}

class SubscriptionException implements Exception {
  const SubscriptionException(
    this.message, {
    this.l10nKey = 'subscriptionDownloadFailed',
    this.statusCode,
  });
  final String message;
  final String l10nKey;
  final int? statusCode;

  @override
  String toString() => message;
}
