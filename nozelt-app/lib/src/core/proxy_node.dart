const int maxProxyNodes = 4096;

/// Carries local display/health metadata into a freshly downloaded node list
/// without making subscription refresh quadratic. Names are normalized and
/// unique at every import boundary, while server/port prevent an unrelated
/// replacement reusing a name from inheriting stale country or latency data.
List<ProxyNode> inheritProxyMetadata(
  List<ProxyNode> previous,
  List<ProxyNode> refreshed,
) {
  final previousByIdentity = <(String, String, int), ProxyNode>{
    for (final node in previous) (node.name, node.server, node.port): node,
  };
  return [
    for (final node in refreshed)
      if (previousByIdentity[(node.name, node.server, node.port)]
          case final old?)
        node.inheritMetadata(old)
      else
        node,
  ];
}

/// A single parsed proxy node. [raw] remains mihomo's source of truth; the
/// additional fields are Nozelt-only display/health metadata.
class ProxyNode {
  const ProxyNode({
    required this.name,
    required this.type,
    required this.server,
    required this.port,
    required this.raw,
    this.detectedCountryCode,
    this.countryCodeOverride,
    this.lastDelayMs,
    this.lastDelayAt,
  });

  final String name;
  final String type;
  final String server;
  final int port;
  final Map<String, dynamic> raw;
  final String? detectedCountryCode;
  final String? countryCodeOverride;
  final int? lastDelayMs;
  final DateTime? lastDelayAt;

  static const Set<String> _nonProxyOutboundTypes = {
    'direct',
    'reject',
    'reject-drop',
    'pass',
    'compatible',
    'dns',
    'selector',
    'url-test',
    'fallback',
    'load-balance',
    'relay',
  };
  static final RegExp _controlPattern = RegExp(r'[\u0000-\u001f\u007f]');

  bool get isAutomaticGroup => raw['nozelt-auto-members'] is List;

  String get displayType => isAutomaticGroup ? 'AUTO' : type.toUpperCase();

  List<Map<String, dynamic>> get automaticMembers {
    final members = raw['nozelt-auto-members'];
    if (members is! List) return const [];
    return members
        .whereType<Map>()
        .map((value) => value.cast<String, dynamic>())
        .toList(growable: false);
  }

  /// True only for a real remote outbound. Pseudo-outbounds such as DIRECT
  /// are valid in a desktop Clash config but are forbidden as selectable VPN
  /// nodes because their protected sockets would bypass Nozelt encryption.
  bool get isUsableOutbound {
    if (isAutomaticGroup) {
      final members = automaticMembers;
      return type.trim().toLowerCase() == 'url-test' &&
          members.length >= 2 &&
          members.length <= 64 &&
          members.every((member) => ProxyNode.fromRaw(member).isUsableOutbound);
    }
    final normalizedType = type.trim().toLowerCase();
    final normalizedServer = server.trim();
    final rawType = (raw['type'] ?? '').toString().trim().toLowerCase();
    final rawServer = (raw['server'] ?? '').toString().trim();
    final rawPort = int.tryParse((raw['port'] ?? '').toString());
    return normalizedType.isNotEmpty &&
        !_nonProxyOutboundTypes.contains(normalizedType) &&
        normalizedType == rawType &&
        normalizedType.length <= 64 &&
        !normalizedType.contains(_controlPattern) &&
        normalizedServer.isNotEmpty &&
        normalizedServer == rawServer &&
        normalizedServer.length <= 1024 &&
        !normalizedServer.contains(_controlPattern) &&
        port > 0 &&
        port <= 65535 &&
        rawPort == port;
  }

  _NameFlag get _nameFlag => _NameFlag.parse(name);

  /// Name shown in UI. A flag token is removed without touching mihomo's raw
  /// proxy name, which remains stable for selectors and subscription refresh.
  String get displayName => _nameFlag.cleanName;

  String? get embeddedCountryCode => _nameFlag.countryCode;

  /// Manual override wins, then a flag embedded in the subscription name,
  /// then GeoIP detection.
  String? get countryCode =>
      _normalizeCountryCode(countryCodeOverride) ??
      embeddedCountryCode ??
      _normalizeCountryCode(detectedCountryCode);

  String get flagEmoji => countryCodeToFlag(countryCode);

  factory ProxyNode.fromRaw(Map<String, dynamic> raw) {
    return ProxyNode(
      name: (raw['name'] ?? '').toString(),
      type: (raw['type'] ?? '').toString(),
      server: (raw['server'] ?? '').toString(),
      port: int.tryParse((raw['port'] ?? '').toString()) ?? 0,
      raw: raw,
    );
  }

  /// Returns a list whose mihomo-facing names are non-empty, unique, free of
  /// control characters, and distinct from built-in groups/targets. This is
  /// applied at every import boundary and again when old encrypted profiles
  /// are decoded, so a subscription cannot shadow `PROXY`/`DIRECT` or make
  /// mihomo reject the selector because of duplicate names.
  static List<ProxyNode> normalizeNames(Iterable<ProxyNode> source) {
    const maxNameRunes = 128;
    const reserved = {
      'PROXY',
      'DIRECT',
      'REJECT',
      'REJECT-DROP',
      'PASS',
      'COMPATIBLE',
      'GLOBAL',
    };
    final used = <String>{};
    final normalized = <ProxyNode>[];
    var index = 0;
    for (final node in source) {
      index++;
      var base = node.name
          .replaceAll(RegExp(r'[\u0000-\u001f\u007f]'), ' ')
          .replaceAll(RegExp(r'\s+'), ' ')
          .trim();
      if (base.isEmpty) base = 'Proxy $index';
      if (base.runes.length > maxNameRunes) {
        // Subscription-controlled names are rendered in several widgets and
        // copied into selector maps. Bound them before uniqueness suffixing so
        // a tiny proxy record cannot force megabyte-scale strings throughout
        // the encrypted profile and live config.
        base = String.fromCharCodes(
          base.runes.take(maxNameRunes - 8),
        ).trimRight();
      }
      if (reserved.contains(base.toUpperCase())) base = '$base (node)';

      var candidate = base;
      var suffix = 2;
      while (used.contains(candidate.toLowerCase()) ||
          reserved.contains(candidate.toUpperCase())) {
        candidate = '$base ($suffix)';
        suffix++;
      }
      used.add(candidate.toLowerCase());
      normalized.add(node._renamed(candidate));
    }
    return normalized;
  }

  ProxyNode _renamed(String nextName) {
    if (name == nextName && raw['name'] == nextName) return this;
    return ProxyNode(
      name: nextName,
      type: type,
      server: server,
      port: port,
      raw: {...raw, 'name': nextName},
      detectedCountryCode: detectedCountryCode,
      countryCodeOverride: countryCodeOverride,
      lastDelayMs: lastDelayMs,
      lastDelayAt: lastDelayAt,
    );
  }

  ProxyNode copyWith({
    String? detectedCountryCode,
    bool clearDetectedCountryCode = false,
    String? countryCodeOverride,
    bool clearCountryCodeOverride = false,
    int? lastDelayMs,
    bool clearLastDelay = false,
    DateTime? lastDelayAt,
  }) {
    return ProxyNode(
      name: name,
      type: type,
      server: server,
      port: port,
      raw: raw,
      detectedCountryCode: clearDetectedCountryCode
          ? null
          : (detectedCountryCode ?? this.detectedCountryCode),
      countryCodeOverride: clearCountryCodeOverride
          ? null
          : (countryCodeOverride ?? this.countryCodeOverride),
      lastDelayMs: clearLastDelay ? null : (lastDelayMs ?? this.lastDelayMs),
      lastDelayAt: lastDelayAt ?? this.lastDelayAt,
    );
  }

  /// Carries user/detected metadata across a refreshed subscription when the
  /// technical node identity still matches.
  ProxyNode inheritMetadata(ProxyNode previous) => ProxyNode(
    name: name,
    type: type,
    server: server,
    port: port,
    raw: raw,
    detectedCountryCode: previous.detectedCountryCode,
    countryCodeOverride: previous.countryCodeOverride,
    lastDelayMs: previous.lastDelayMs,
    lastDelayAt: previous.lastDelayAt,
  );

  Map<String, dynamic> toJson() => {
    'raw': raw,
    'detectedCountryCode': detectedCountryCode,
    'countryCodeOverride': countryCodeOverride,
    // Latency is volatile telemetry. Persisting it would rewrite and encrypt
    // the complete credential-bearing profile every 30/60 seconds merely to
    // save one number. It intentionally lives only in the current process.
  };

  factory ProxyNode.fromJson(Map<String, dynamic> json) {
    final parsed = ProxyNode.fromRaw(
      (json['raw'] as Map).cast<String, dynamic>(),
    );
    return parsed.copyWith(
      detectedCountryCode: json['detectedCountryCode'] as String?,
      countryCodeOverride: json['countryCodeOverride'] as String?,
      // Ignore legacy persisted latency so a new process never presents an
      // old network measurement as if it described the current route.
      clearLastDelay: true,
    );
  }

  static String countryCodeToFlag(String? rawCode) {
    final code = _normalizeCountryCode(rawCode);
    if (code == null) return '🌐';
    return String.fromCharCodes([
      0x1F1E6 + code.codeUnitAt(0) - 65,
      0x1F1E6 + code.codeUnitAt(1) - 65,
    ]);
  }

  static String? _normalizeCountryCode(String? code) {
    final normalized = code?.trim().toUpperCase();
    if (normalized == null ||
        normalized.length != 2 ||
        !RegExp(r'^[A-Z]{2}$').hasMatch(normalized)) {
      return null;
    }
    return normalized;
  }
}

class _NameFlag {
  const _NameFlag(this.cleanName, this.countryCode);

  final String cleanName;
  final String? countryCode;

  factory _NameFlag.parse(String name) {
    final runes = name.runes.toList(growable: false);
    String? code;
    final output = <int>[];
    var index = 0;
    while (index < runes.length) {
      final first = runes[index];
      final hasPair =
          index + 1 < runes.length &&
          _isRegional(first) &&
          _isRegional(runes[index + 1]);
      final startsToken = index == 0 || _isWhitespace(runes[index - 1]);
      if (hasPair && startsToken) {
        code ??= String.fromCharCodes([
          65 + first - 0x1F1E6,
          65 + runes[index + 1] - 0x1F1E6,
        ]);
        index += 2;
        continue;
      }
      output.add(first);
      index++;
    }
    final cleaned = String.fromCharCodes(
      output,
    ).replaceAll(RegExp(r'\s+'), ' ').trim();
    return _NameFlag(cleaned.isEmpty ? name : cleaned, code);
  }

  static bool _isRegional(int rune) => rune >= 0x1F1E6 && rune <= 0x1F1FF;
  static bool _isWhitespace(int rune) =>
      rune == 0x20 || rune == 0x09 || rune == 0x0A || rune == 0x0D;
}
