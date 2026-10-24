import 'dart:convert';
import 'dart:io';

import 'routing_rule.dart';
import 'advanced_network_settings.dart';

/// Supported TUN network stacks, matching mihomo's `tun.stack` vocabulary
/// (lowercase). See nozelt-core for how each behaves.
enum TunStack {
  /// Userspace stack (gVisor). Most compatible; the safe default.
  gvisor,

  /// Kernel stack. Faster, but can be flaky on some Android builds.
  system,

  /// Hybrid: TCP via the kernel, UDP via gVisor.
  mixed;

  String get yamlValue => name; // 'gvisor' | 'system' | 'mixed'

  static TunStack fromName(String? v) => TunStack.values.firstWhere(
    (s) => s.name == v,
    orElse: () => TunStack.gvisor,
  );
}

/// Top-level mihomo routing mode exposed by the Routing tab.
enum RoutingMode {
  global,
  rule;

  static RoutingMode fromName(String? value) => RoutingMode.values.firstWhere(
    (mode) => mode.name == value,
    orElse: () => RoutingMode.rule,
  );
}

/// User-tunable TUN / DNS parameters. Persisted as JSON inside the Android
/// Keystore-backed sensitive-settings snapshot and fed to [ConfigBuilder] to
/// assemble mihomo JSON plus VpnService.Builder options. Immutable; edit via
/// [copyWith]. Non-Android targets retain the legacy private preference store.
class TunSettings {
  const TunSettings({
    this.stack = TunStack.gvisor,
    this.mtu = 9000,
    this.fakeIpRange = '198.18.0.0/15',
    this.nameservers = const [
      'https://1.1.1.1/dns-query',
      'https://8.8.8.8/dns-query',
    ],
    this.dnsHijack = true,
    this.autoRoute = false,
    this.autoDetectInterface = false,
    this.ipv6 = false,
    this.routingMode = RoutingMode.rule,
    this.allowLan = false,
    this.snifferEnabled = false,
    this.customRules = const [],
    this.geoUpdateIntervalHours = 24,
    this.dns = const AdvancedDnsSettings(),
    this.desktop = const DesktopTunSettings(),
  });

  /// TUN stack passed to mihomo.
  final TunStack stack;

  /// Link MTU. Must be within [mtuMin]..[mtuMax]; the same value is used for
  /// both `tun.mtu` and `VpnService.Builder.setMtu`.
  final int mtu;

  /// fake-ip CIDR handed to mihomo's DNS (`dns.fake-ip-range`).
  final String fakeIpRange;

  /// Upstream resolvers mihomo uses (`dns.nameserver`). Not the address
  /// advertised to Android — that is the in-tunnel hijack target.
  final List<String> nameservers;

  /// Whether mihomo hijacks all port-53 traffic entering the TUN
  /// (`tun.dns-hijack: [any:53]`). Required for fake-ip rule matching.
  final bool dnsHijack;

  /// Legacy persisted value for `tun.auto-route`. Nozelt forces this off in
  /// the generated Android config because VpnService owns routing.
  final bool autoRoute;

  /// Legacy persisted value for `tun.auto-detect-interface`. Nozelt forces
  /// this off on Android because sing-tun's netlink monitor is unavailable to
  /// sandboxed apps. Android's VpnService.protect() socket hook provides the
  /// anti-loop mechanism instead.
  final bool autoDetectInterface;

  /// Whether to add an IPv6 address/route to the TUN and enable DNS IPv6.
  final bool ipv6;

  final RoutingMode routingMode;

  /// Allows direct access to RFC1918, link-local, and IPv6 ULA networks in
  /// rule mode. Disabled by default to minimize local-network exposure.
  final bool allowLan;

  /// Inspects only destination metadata exposed by HTTP Host, TLS SNI, and
  /// QUIC Initial packets so domain rules can cover applications that bypass
  /// Android DNS. Explicit opt-in because it adds parsing work and changes
  /// pure-IP destinations into the detected hostname before proxy dialing.
  final bool snifferEnabled;

  /// Ordered user rules, evaluated before Nozelt's private-network defaults.
  final List<RoutingRule> customRules;

  /// Effective per-routing-profile geodata refresh interval. Zero disables
  /// periodic refresh while keeping already available geodata usable.
  final int geoUpdateIntervalHours;
  final AdvancedDnsSettings dns;
  final DesktopTunSettings desktop;

  static const int mtuMin = 1280;
  static const int mtuMax = 9000;
  static const int maxCustomRules = 4096;
  static const int maxNameservers = 8;
  static const int maxDnsEndpointCharacters = 2048;

  /// Returns a localization key for the first invalid setting, or null.
  /// Keeping user-facing text out of the model prevents English validation
  /// errors from leaking into the Russian UI.
  String? validationKey() {
    if (mtu < mtuMin || mtu > mtuMax) return 'invalidMtu';
    final fakeIpParts = fakeIpRange.trim().split('/');
    final fakeIpAddress = fakeIpParts.length == 2
        ? InternetAddress.tryParse(fakeIpParts.first)
        : null;
    final fakeIpPrefix = fakeIpParts.length == 2
        ? int.tryParse(fakeIpParts.last)
        : null;
    if (fakeIpAddress?.type != InternetAddressType.IPv4 ||
        fakeIpPrefix == null ||
        fakeIpPrefix < 0 ||
        fakeIpPrefix > 32) {
      return 'invalidFakeIp';
    }
    if (!_isSafeFakeIpNetwork(fakeIpAddress!, fakeIpPrefix)) {
      return 'invalidFakeIp';
    }
    if (nameservers.isEmpty) return 'dnsRequired';
    if (nameservers.length > maxNameservers) return 'invalidDns';
    for (final nameserver in nameservers) {
      final error = validateEncryptedResolver(nameserver);
      if (error != null) return error;
    }
    final advancedError = dns.validationKey() ?? desktop.validationKey();
    if (advancedError != null) return advancedError;
    if (customRules.length > maxCustomRules) return 'invalidRule';
    for (final rule in customRules) {
      if (rule.validate() != null) return 'invalidRule';
    }
    return null;
  }

  /// Low-level validation result retained for config tests and non-UI callers.
  String? validate() {
    return switch (validationKey()) {
      'invalidMtu' => 'MTU is outside the supported range.',
      'invalidFakeIp' =>
        'fake-ip range must be an aligned /15-/20 subnet of 198.18.0.0/15.',
      'dnsRequired' => 'At least one DNS nameserver is required.',
      'encryptedDnsOnly' => 'Only encrypted DNS is allowed.',
      'dnsIpLiteralOnly' => 'Encrypted DNS endpoints must use an IP address.',
      'invalidRule' => 'A routing rule is invalid.',
      null => null,
      final key => key,
    };
  }

  TunSettings copyWith({
    TunStack? stack,
    int? mtu,
    String? fakeIpRange,
    List<String>? nameservers,
    bool? dnsHijack,
    bool? autoRoute,
    bool? autoDetectInterface,
    bool? ipv6,
    RoutingMode? routingMode,
    bool? allowLan,
    bool? snifferEnabled,
    List<RoutingRule>? customRules,
    int? geoUpdateIntervalHours,
    AdvancedDnsSettings? dns,
    DesktopTunSettings? desktop,
  }) {
    return TunSettings(
      stack: stack ?? this.stack,
      mtu: mtu ?? this.mtu,
      fakeIpRange: fakeIpRange ?? this.fakeIpRange,
      nameservers: nameservers ?? this.nameservers,
      dnsHijack: dnsHijack ?? this.dnsHijack,
      autoRoute: autoRoute ?? this.autoRoute,
      autoDetectInterface: autoDetectInterface ?? this.autoDetectInterface,
      ipv6: ipv6 ?? this.ipv6,
      routingMode: routingMode ?? this.routingMode,
      allowLan: allowLan ?? this.allowLan,
      snifferEnabled: snifferEnabled ?? this.snifferEnabled,
      customRules: customRules ?? this.customRules,
      geoUpdateIntervalHours:
          geoUpdateIntervalHours ?? this.geoUpdateIntervalHours,
      dns: dns ?? this.dns,
      desktop: desktop ?? this.desktop,
    );
  }

  Map<String, dynamic> toMap() => {
    'stack': stack.name,
    'mtu': mtu,
    'fakeIpRange': fakeIpRange,
    'nameservers': nameservers,
    'dnsHijack': dnsHijack,
    'autoRoute': autoRoute,
    'autoDetectInterface': autoDetectInterface,
    'ipv6': ipv6,
    'routingMode': routingMode.name,
    'allowLan': allowLan,
    'snifferEnabled': snifferEnabled,
    'customRules': customRules.map((rule) => rule.toJson()).toList(),
    'geoUpdateIntervalHours': geoUpdateIntervalHours,
    'dns': dns.toMap(),
    'desktop': desktop.toMap(),
  };

  factory TunSettings.fromMap(Map<String, dynamic> map) => TunSettings(
    stack: TunStack.fromName(map['stack'] as String?),
    mtu: (map['mtu'] as num?)?.toInt() ?? 9000,
    fakeIpRange: map['fakeIpRange'] as String? ?? '198.18.0.0/15',
    nameservers: _migrateNameservers(
      (map['nameservers'] as List?)?.whereType<String>().toList(
        growable: false,
      ),
    ),
    // DNS interception is mandatory for fake-IP domain routing on Android.
    dnsHijack: true,
    // Migrate old installations away from Android-incompatible values.
    autoRoute: false,
    autoDetectInterface: false,
    ipv6: map['ipv6'] as bool? ?? false,
    routingMode: RoutingMode.fromName(map['routingMode'] as String?),
    allowLan: map['allowLan'] as bool? ?? false,
    snifferEnabled: map['snifferEnabled'] as bool? ?? false,
    customRules: ((map['customRules'] as List?) ?? const [])
        .whereType<Map>()
        .map((value) => RoutingRule.fromJson(value.cast<String, dynamic>()))
        .where((rule) => rule.id.isNotEmpty && rule.validate() == null)
        .take(maxCustomRules)
        .toList(growable: false),
    geoUpdateIntervalHours:
        (map['geoUpdateIntervalHours'] as num?)?.toInt() ?? 24,
    dns: AdvancedDnsSettings.fromMap(
      (map['dns'] as Map?)?.cast<String, dynamic>() ?? const {},
    ),
    desktop: DesktopTunSettings.fromMap(
      (map['desktop'] as Map?)?.cast<String, dynamic>() ?? const {},
    ),
  );

  static List<String> _migrateNameservers(List<String>? values) {
    final source = values ?? const <String>[];
    if (source.isEmpty) {
      return const ['https://1.1.1.1/dns-query', 'https://8.8.8.8/dns-query'];
    }
    return source
        .take(maxNameservers)
        .map((value) {
          return switch (value.trim()) {
            '1.1.1.1' => 'https://1.1.1.1/dns-query',
            '8.8.8.8' => 'https://8.8.8.8/dns-query',
            final other => other,
          };
        })
        .toList(growable: false);
  }

  static bool _isSafeFakeIpNetwork(InternetAddress address, int prefix) {
    // RFC 2544 reserves 198.18.0.0/15 for benchmarking; using a subnet of
    // that non-public block prevents synthetic answers from colliding with
    // real Internet/LAN routes. Keep at least 4096 addresses (/20) so normal
    // mobile browsing cannot churn the fake-IP pool continuously.
    if (prefix < 15 || prefix > 20) return false;
    var value = 0;
    for (final byte in address.rawAddress) {
      value = (value << 8) | byte;
    }
    final hostBits = 32 - prefix;
    final mask = (0xffffffff << hostBits) & 0xffffffff;
    final network = value & mask;
    final end = network | (0xffffffff ^ mask);
    return value == network && network >= 0xc6120000 && end <= 0xc613ffff;
  }

  String encode() => jsonEncode(toMap());

  factory TunSettings.decode(String json) =>
      TunSettings.fromMap(jsonDecode(json) as Map<String, dynamic>);
}
