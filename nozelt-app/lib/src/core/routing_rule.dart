import 'dart:io';

enum RoutingRuleType {
  geoIp,
  geoSite,
  domain,
  domainSuffix,
  domainKeyword,
  processName,
  ipCidr;

  static RoutingRuleType fromName(String? value) => values.firstWhere(
    (type) => type.name == value,
    orElse: () => RoutingRuleType.domainSuffix,
  );
}

enum RoutingRuleAction {
  proxy,
  direct,
  reject;

  static RoutingRuleAction fromName(String? value) => values.firstWhere(
    (action) => action.name == value,
    orElse: () => RoutingRuleAction.proxy,
  );
}

/// A user-owned routing rule. Values are validated before they are converted
/// into mihomo's comma-delimited rule syntax, preventing config injection via
/// pasted domains or CIDRs.
class RoutingRule {
  const RoutingRule({
    required this.id,
    required this.type,
    required this.value,
    required this.action,
    this.enabled = true,
  });

  final String id;
  final RoutingRuleType type;
  final String value;
  final RoutingRuleAction action;
  final bool enabled;

  String get normalizedValue => normalizeRuleValue(type, value);

  /// Turns what people usually paste into the form every core expects:
  /// a URL or `host:port` becomes its host, a trailing dot is dropped,
  /// Cyrillic and other international domains become punycode, and a single
  /// IP address becomes a one-address range.
  static String normalizeRuleValue(RoutingRuleType type, String raw) {
    var normalized = raw.trim().toLowerCase();
    switch (type) {
      case RoutingRuleType.domain:
      case RoutingRuleType.domainSuffix:
        normalized = _hostFromInput(normalized);
        if (type == RoutingRuleType.domainSuffix) {
          normalized = normalized.replaceFirst(RegExp(r'^\*?\.'), '');
        }
        normalized = _asciiDomain(normalized);
      case RoutingRuleType.ipCidr:
        if (!normalized.contains('/')) {
          final address = InternetAddress.tryParse(normalized);
          if (address != null) {
            final bits = address.type == InternetAddressType.IPv4 ? 32 : 128;
            normalized = '$normalized/$bits';
          }
        }
      case RoutingRuleType.geoIp:
      case RoutingRuleType.geoSite:
      case RoutingRuleType.domainKeyword:
      case RoutingRuleType.processName:
        break;
    }
    return normalized;
  }

  static String _hostFromInput(String input) {
    var host = input.replaceFirst(RegExp(r'^[a-z][a-z0-9+.-]*://'), '');
    host = host.replaceFirst(RegExp(r'^[^@/?#]*@'), '');
    final cut = host.indexOf(RegExp(r'[/?#]'));
    if (cut >= 0) host = host.substring(0, cut);
    final withPort = RegExp(r'^([^:\[\]]+):\d{1,5}$').firstMatch(host);
    if (withPort != null) host = withPort.group(1)!;
    while (host.length > 1 && host.endsWith('.')) {
      host = host.substring(0, host.length - 1);
    }
    return host;
  }

  static String _asciiDomain(String domain) {
    if (!domain.runes.any((rune) => rune >= 0x80)) return domain;
    return domain
        .split('.')
        .map(
          (label) => label.runes.any((rune) => rune >= 0x80)
              ? 'xn--${_punycode(label)}'
              : label,
        )
        .join('.');
  }

  /// RFC 3492 punycode for one domain label.
  static String _punycode(String label) {
    const base = 36, tMin = 1, tMax = 26;
    final input = label.runes.toList(growable: false);
    final output = StringBuffer();
    for (final rune in input) {
      if (rune < 0x80) output.writeCharCode(rune);
    }
    final basic = output.length;
    var handled = basic;
    if (basic > 0) output.write('-');
    var n = 0x80, delta = 0, bias = 72;
    int digit(int value) => value < 26 ? 0x61 + value : 0x16 + value;
    int adapt(int delta, int points, bool first) {
      delta = first ? delta ~/ 700 : delta ~/ 2;
      delta += delta ~/ points;
      var k = 0;
      while (delta > ((base - tMin) * tMax) ~/ 2) {
        delta ~/= base - tMin;
        k += base;
      }
      return k + ((base - tMin + 1) * delta) ~/ (delta + 38);
    }

    while (handled < input.length) {
      var m = 0x10FFFF;
      for (final rune in input) {
        if (rune >= n && rune < m) m = rune;
      }
      delta += (m - n) * (handled + 1);
      n = m;
      for (final rune in input) {
        if (rune < n) delta++;
        if (rune != n) continue;
        var q = delta;
        for (var k = base; ; k += base) {
          final t = k <= bias
              ? tMin
              : k >= bias + tMax
              ? tMax
              : k - bias;
          if (q < t) break;
          output.writeCharCode(digit(t + (q - t) % (base - t)));
          q = (q - t) ~/ (base - t);
        }
        output.writeCharCode(digit(q));
        bias = adapt(delta, handled + 1, handled == basic);
        delta = 0;
        handled++;
      }
      delta++;
      n++;
    }
    return output.toString();
  }

  String? validate() {
    final candidate = normalizedValue;
    if (candidate.isEmpty) return 'Rule value is empty.';
    if (candidate.contains(',') ||
        candidate.contains('\n') ||
        candidate.contains('\r') ||
        candidate.contains('\u0000')) {
      return 'Rule contains forbidden characters.';
    }

    switch (type) {
      case RoutingRuleType.geoIp:
      case RoutingRuleType.geoSite:
        if (candidate.length > 128 ||
            !RegExp(r'^[a-z0-9][a-z0-9._@!-]*$').hasMatch(candidate)) {
          return 'Enter a valid GeoIP/GeoSite tag.';
        }
      case RoutingRuleType.domain:
      case RoutingRuleType.domainSuffix:
        if (candidate.length > 253 ||
            !RegExp(
              r'^(?:[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\.)*'
              r'[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?$',
            ).hasMatch(candidate)) {
          return 'Enter a valid domain name.';
        }
      case RoutingRuleType.domainKeyword:
        if (candidate.length > 128) return 'Keyword is too long.';
      case RoutingRuleType.processName:
        if (candidate.length > 260 ||
            candidate.contains('/') ||
            candidate.contains(r'\')) {
          return 'Enter a valid process name.';
        }
      case RoutingRuleType.ipCidr:
        final slash = candidate.lastIndexOf('/');
        if (slash <= 0) return 'Enter an IP range in CIDR notation.';
        final address = InternetAddress.tryParse(candidate.substring(0, slash));
        final prefix = int.tryParse(candidate.substring(slash + 1));
        if (address == null || prefix == null) {
          return 'Enter a valid IP range.';
        }
        final maxPrefix = address.type == InternetAddressType.IPv4 ? 32 : 128;
        if (prefix < 0 || prefix > maxPrefix) return 'Invalid CIDR prefix.';
    }
    return null;
  }

  String toMihomoRule(String proxyGroup) {
    final error = validate();
    if (error != null) throw FormatException(error);
    final kind = switch (type) {
      RoutingRuleType.geoIp => 'GEOIP',
      RoutingRuleType.geoSite => 'GEOSITE',
      RoutingRuleType.domain => 'DOMAIN',
      RoutingRuleType.domainSuffix => 'DOMAIN-SUFFIX',
      RoutingRuleType.domainKeyword => 'DOMAIN-KEYWORD',
      RoutingRuleType.processName => 'PROCESS-NAME',
      RoutingRuleType.ipCidr =>
        normalizedValue.contains(':') ? 'IP-CIDR6' : 'IP-CIDR',
    };
    final target = switch (action) {
      RoutingRuleAction.proxy => proxyGroup,
      RoutingRuleAction.direct => 'DIRECT',
      RoutingRuleAction.reject => 'REJECT',
    };
    // No `no-resolve`: with fake-IP DNS an app connects by name, so an IP or
    // GeoIP rule must resolve that name (through the encrypted resolver) to
    // match at all. Xray and sing-box see the real address the same way.
    return '$kind,$normalizedValue,$target';
  }

  RoutingRule copyWith({
    RoutingRuleType? type,
    String? value,
    RoutingRuleAction? action,
    bool? enabled,
  }) => RoutingRule(
    id: id,
    type: type ?? this.type,
    value: value ?? this.value,
    action: action ?? this.action,
    enabled: enabled ?? this.enabled,
  );

  Map<String, dynamic> toJson() => {
    'id': id,
    'type': type.name,
    'value': normalizedValue,
    'action': action.name,
    'enabled': enabled,
  };

  factory RoutingRule.fromJson(Map<String, dynamic> json) => RoutingRule(
    id: json['id']?.toString() ?? '',
    type: RoutingRuleType.fromName(json['type'] as String?),
    value: json['value']?.toString() ?? '',
    action: RoutingRuleAction.fromName(json['action'] as String?),
    enabled: json['enabled'] as bool? ?? true,
  );
}
