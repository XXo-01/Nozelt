import 'dart:convert';
import 'dart:io';

import 'routing_rule.dart';
import 'split_tunnel_settings.dart';
import 'tun_settings.dart';

const String defaultRoutingProfileId = 'default-routing-profile';
const String routingProfileLinkScheme = 'nozelt';
const String routingProfileLinkHost = 'routing-profile';
const int _routingProfileShareVersion = 2;
const int _maxCompressedShareBytes = 256 * 1024;
const int _maxExpandedShareBytes = 2 * 1024 * 1024;

/// Settings that affect only one routing profile.
class RoutingProfileSettings {
  const RoutingProfileSettings({
    this.geoUpdateIntervalHours = 24,
    this.lastGeoUpdateEpochSeconds,
    this.actionOrder = const [
      RoutingRuleAction.reject,
      RoutingRuleAction.proxy,
      RoutingRuleAction.direct,
    ],
  });

  /// 0 disables automatic GeoIP/GeoSite updates.
  final int geoUpdateIntervalHours;
  final int? lastGeoUpdateEpochSeconds;
  final List<RoutingRuleAction> actionOrder;

  static const int maxCustomGeoUpdateHours = 24 * 365;

  String? validate() {
    if (geoUpdateIntervalHours < 0 ||
        geoUpdateIntervalHours > maxCustomGeoUpdateHours) {
      return 'invalidGeoUpdateInterval';
    }
    if (actionOrder.length != RoutingRuleAction.values.length ||
        actionOrder.toSet().length != RoutingRuleAction.values.length) {
      return 'invalidRoutingOrder';
    }
    return null;
  }

  RoutingProfileSettings copyWith({
    int? geoUpdateIntervalHours,
    int? lastGeoUpdateEpochSeconds,
    bool clearLastGeoUpdate = false,
    List<RoutingRuleAction>? actionOrder,
  }) => RoutingProfileSettings(
    geoUpdateIntervalHours:
        geoUpdateIntervalHours ?? this.geoUpdateIntervalHours,
    lastGeoUpdateEpochSeconds: clearLastGeoUpdate
        ? null
        : lastGeoUpdateEpochSeconds ?? this.lastGeoUpdateEpochSeconds,
    actionOrder: List.unmodifiable(actionOrder ?? this.actionOrder),
  );

  Map<String, dynamic> toJson({bool includeRuntimeState = true}) => {
    'geoUpdateIntervalHours': geoUpdateIntervalHours,
    if (includeRuntimeState && lastGeoUpdateEpochSeconds != null)
      'lastGeoUpdateEpochSeconds': lastGeoUpdateEpochSeconds,
    'actionOrder': actionOrder.map((value) => value.name).toList(),
  };

  factory RoutingProfileSettings.fromJson(Map<String, dynamic> json) {
    final rawOrder = (json['actionOrder'] as List?)
        ?.whereType<String>()
        .map(RoutingRuleAction.fromName)
        .toList(growable: false);
    final order =
        rawOrder != null &&
            rawOrder.length == RoutingRuleAction.values.length &&
            rawOrder.toSet().length == RoutingRuleAction.values.length
        ? rawOrder
        : const [
            RoutingRuleAction.reject,
            RoutingRuleAction.proxy,
            RoutingRuleAction.direct,
          ];
    final interval = (json['geoUpdateIntervalHours'] as num?)?.toInt() ?? 24;
    return RoutingProfileSettings(
      geoUpdateIntervalHours:
          interval >= 0 && interval <= maxCustomGeoUpdateHours ? interval : 24,
      lastGeoUpdateEpochSeconds: (json['lastGeoUpdateEpochSeconds'] as num?)
          ?.toInt(),
      actionOrder: List.unmodifiable(order),
    );
  }
}

class RoutingProfile {
  const RoutingProfile({
    required this.id,
    required this.name,
    this.routingMode = RoutingMode.rule,
    this.split = const SplitTunnelSettings(),
    this.rules = const [],
    this.settings = const RoutingProfileSettings(),
  });

  final String id;
  final String name;
  final RoutingMode routingMode;
  final SplitTunnelSettings split;
  final List<RoutingRule> rules;
  final RoutingProfileSettings settings;

  static const int maxProfiles = 64;
  static const int maxNameCharacters = 80;
  static const int maxRules = 4096;

  String? validate() {
    final normalizedName = name.trim();
    if (id.isEmpty || id.length > 128) return 'invalidRoutingProfile';
    if (normalizedName.isEmpty || normalizedName.length > maxNameCharacters) {
      return 'invalidRoutingProfileName';
    }
    if (rules.length > maxRules ||
        rules.any((rule) => rule.id.isEmpty || rule.validate() != null) ||
        rules.map((rule) => rule.id).toSet().length != rules.length) {
      return 'invalidRule';
    }
    return settings.validate();
  }

  List<RoutingRule> get orderedRules {
    final enabled = rules.where((rule) => rule.enabled);
    return [
      for (final action in settings.actionOrder)
        ...enabled.where((rule) => rule.action == action),
    ];
  }

  RoutingProfile copyWith({
    String? name,
    RoutingMode? routingMode,
    SplitTunnelSettings? split,
    List<RoutingRule>? rules,
    RoutingProfileSettings? settings,
  }) => RoutingProfile(
    id: id,
    name: name ?? this.name,
    routingMode: routingMode ?? this.routingMode,
    split: split ?? this.split,
    rules: List.unmodifiable(rules ?? this.rules),
    settings: settings ?? this.settings,
  );

  Map<String, dynamic> toJson({
    bool includeId = true,
    bool includeRuntimeState = true,
  }) => {
    'schema': 'nozelt-routing-profile',
    'version': 1,
    if (includeId) 'id': id,
    'name': name.trim(),
    'routingMode': routingMode.name,
    'splitTunnel': split.toMap(),
    'settings': settings.toJson(includeRuntimeState: includeRuntimeState),
    'rules': rules.map((rule) => rule.toJson()).toList(growable: false),
  };

  factory RoutingProfile.fromJson(
    Map<String, dynamic> json, {
    String? importedId,
  }) {
    if (json['schema'] != null && json['schema'] != 'nozelt-routing-profile') {
      throw const FormatException('Unsupported routing profile schema.');
    }
    final profile = RoutingProfile(
      id: importedId ?? json['id']?.toString() ?? '',
      name: json['name']?.toString().trim() ?? '',
      routingMode: RoutingMode.fromName(json['routingMode'] as String?),
      split: json['splitTunnel'] is Map
          ? SplitTunnelSettings.fromMap(
              (json['splitTunnel'] as Map).cast<String, dynamic>(),
            )
          : const SplitTunnelSettings(),
      settings: json['settings'] is Map
          ? RoutingProfileSettings.fromJson(
              (json['settings'] as Map).cast<String, dynamic>(),
            )
          : const RoutingProfileSettings(),
      rules: ((json['rules'] as List?) ?? const [])
          .whereType<Map>()
          .map((value) => RoutingRule.fromJson(value.cast<String, dynamic>()))
          .toList(growable: false),
    );
    final error = profile.validate();
    if (error != null) throw FormatException(error);
    return profile;
  }

  String encodeConfig() => const JsonEncoder.withIndent(
    '  ',
  ).convert(toJson(includeId: false, includeRuntimeState: false));

  String encodeShareLink() {
    final compact = <Object?>[
      _routingProfileShareVersion,
      name.trim(),
      routingMode.index,
      split.mode.index,
      split.apps.toList(growable: false)..sort(),
      settings.geoUpdateIntervalHours,
      settings.actionOrder.map((value) => value.index).toList(growable: false),
      [
        for (final rule in rules)
          <Object?>[
            rule.type.index,
            rule.normalizedValue,
            rule.action.index,
            if (!rule.enabled) 0,
          ],
      ],
    ];
    final compressed = ZLibCodec(
      level: 9,
    ).encode(utf8.encode(jsonEncode(compact)));
    final payload = base64Url.encode(compressed).replaceAll('=', '');
    return Uri(
      scheme: routingProfileLinkScheme,
      host: routingProfileLinkHost,
      path: '/import/v2',
      queryParameters: {'data': payload},
    ).toString();
  }

  static RoutingProfile decodeConfig(String raw, {required String id}) {
    final decoded = jsonDecode(raw);
    if (decoded is! Map) {
      throw const FormatException('Routing profile must be a JSON object.');
    }
    return RoutingProfile.fromJson(
      decoded.cast<String, dynamic>(),
      importedId: id,
    );
  }

  static RoutingProfile decodeShareLink(String raw, {required String id}) {
    final uri = Uri.tryParse(raw.trim());
    if (uri == null ||
        uri.scheme != routingProfileLinkScheme ||
        uri.host != routingProfileLinkHost ||
        (uri.path != '/import' && uri.path != '/import/v2')) {
      throw const FormatException('Invalid Nozelt routing profile link.');
    }
    final data = uri.queryParameters['data'];
    if (data == null || data.isEmpty || data.length > 2 * 1024 * 1024) {
      throw const FormatException('Invalid routing profile link payload.');
    }
    final padded = data.padRight((data.length + 3) ~/ 4 * 4, '=');
    final decoded = base64Url.decode(padded);
    if (uri.path == '/import') {
      return decodeConfig(utf8.decode(decoded), id: id);
    }
    if (decoded.length > _maxCompressedShareBytes) {
      throw const FormatException('Routing profile link payload is too large.');
    }
    final output = _BoundedByteSink(_maxExpandedShareBytes);
    try {
      final decoder = ZLibCodec().decoder.startChunkedConversion(output);
      decoder.add(decoded);
      decoder.close();
    } on FormatException {
      rethrow;
    } catch (_) {
      throw const FormatException('Invalid compressed routing profile.');
    }
    return _decodeCompactShare(output.bytes, id: id);
  }

  static RoutingProfile _decodeCompactShare(
    List<int> bytes, {
    required String id,
  }) {
    final raw = jsonDecode(utf8.decode(bytes));
    if (raw is! List ||
        raw.length != 8 ||
        raw[0] != _routingProfileShareVersion ||
        raw[1] is! String ||
        raw[4] is! List ||
        raw[6] is! List ||
        raw[7] is! List) {
      throw const FormatException('Invalid compact routing profile.');
    }
    final apps = <String>{};
    for (final value in raw[4] as List) {
      if (value is! String ||
          !isValidSplitTunnelPackage(value) ||
          apps.length >= maxSplitTunnelApps) {
        throw const FormatException('Invalid split-tunnel application.');
      }
      apps.add(value);
    }
    final order = (raw[6] as List)
        .map(
          (value) =>
              _enumByIndex(RoutingRuleAction.values, value, 'routing action'),
        )
        .toList(growable: false);
    if (order.length != RoutingRuleAction.values.length ||
        order.toSet().length != RoutingRuleAction.values.length) {
      throw const FormatException('Invalid routing action order.');
    }
    final rawRules = raw[7] as List;
    if (rawRules.length > maxRules) {
      throw const FormatException('Too many routing rules.');
    }
    final rules = <RoutingRule>[];
    for (var index = 0; index < rawRules.length; index++) {
      final item = rawRules[index];
      if (item is! List ||
          (item.length != 3 && item.length != 4) ||
          item[1] is! String ||
          (item.length == 4 && item[3] != 0)) {
        throw const FormatException('Invalid compact routing rule.');
      }
      final rule = RoutingRule(
        id: 'shared-rule-$index',
        type: _enumByIndex(
          RoutingRuleType.values,
          item[0],
          'routing rule type',
        ),
        value: item[1] as String,
        action: _enumByIndex(
          RoutingRuleAction.values,
          item[2],
          'routing rule action',
        ),
        enabled: item.length == 3,
      );
      if (rule.validate() != null) {
        throw const FormatException('Invalid compact routing rule value.');
      }
      rules.add(rule);
    }
    final interval = raw[5];
    if (interval is! int ||
        interval < 0 ||
        interval > RoutingProfileSettings.maxCustomGeoUpdateHours) {
      throw const FormatException('Invalid geodata update interval.');
    }
    final profile = RoutingProfile(
      id: id,
      name: raw[1] as String,
      routingMode: _enumByIndex(RoutingMode.values, raw[2], 'routing mode'),
      split: SplitTunnelSettings(
        mode: _enumByIndex(SplitMode.values, raw[3], 'split-tunnel mode'),
        apps: Set.unmodifiable(apps),
      ),
      rules: List.unmodifiable(rules),
      settings: RoutingProfileSettings(
        geoUpdateIntervalHours: interval,
        actionOrder: List.unmodifiable(order),
      ),
    );
    final error = profile.validate();
    if (error != null) throw FormatException(error);
    return profile;
  }
}

T _enumByIndex<T>(List<T> values, Object? raw, String field) {
  if (raw is! int || raw < 0 || raw >= values.length) {
    throw FormatException('Invalid $field.');
  }
  return values[raw];
}

class _BoundedByteSink implements Sink<List<int>> {
  _BoundedByteSink(this.limit);

  final int limit;
  final List<int> _bytes = <int>[];
  bool _closed = false;

  List<int> get bytes => List.unmodifiable(_bytes);

  @override
  void add(List<int> data) {
    if (_closed) throw StateError('The decompression sink is closed.');
    if (_bytes.length + data.length > limit) {
      throw const FormatException('Expanded routing profile is too large.');
    }
    _bytes.addAll(data);
  }

  @override
  void close() => _closed = true;
}

class RoutingProfilesState {
  const RoutingProfilesState({required this.profiles, required this.activeId});

  final List<RoutingProfile> profiles;
  final String activeId;

  RoutingProfile get active => profiles.firstWhere(
    (profile) => profile.id == activeId,
    orElse: () => profiles.first,
  );

  String? validate() {
    if (profiles.isEmpty || profiles.length > RoutingProfile.maxProfiles) {
      return 'invalidRoutingProfile';
    }
    if (profiles.map((profile) => profile.id).toSet().length !=
            profiles.length ||
        !profiles.any((profile) => profile.id == activeId)) {
      return 'invalidRoutingProfile';
    }
    for (final profile in profiles) {
      final error = profile.validate();
      if (error != null) return error;
    }
    return null;
  }

  RoutingProfilesState copyWith({
    List<RoutingProfile>? profiles,
    String? activeId,
  }) => RoutingProfilesState(
    profiles: List.unmodifiable(profiles ?? this.profiles),
    activeId: activeId ?? this.activeId,
  );

  RoutingProfilesState replace(RoutingProfile profile) => copyWith(
    profiles: [
      for (final value in profiles)
        if (value.id == profile.id) profile else value,
    ],
  );

  Map<String, dynamic> toJson() => {
    'version': 1,
    'activeId': activeId,
    'profiles': profiles.map((profile) => profile.toJson()).toList(),
  };

  factory RoutingProfilesState.fromJson(Map<String, dynamic> json) {
    final profiles = ((json['profiles'] as List?) ?? const [])
        .whereType<Map>()
        .map((value) => RoutingProfile.fromJson(value.cast<String, dynamic>()))
        .take(RoutingProfile.maxProfiles)
        .toList(growable: false);
    final state = RoutingProfilesState(
      profiles: List.unmodifiable(profiles),
      activeId: json['activeId']?.toString() ?? '',
    );
    final error = state.validate();
    if (error != null) throw FormatException(error);
    return state;
  }

  String encode() => jsonEncode(toJson());

  factory RoutingProfilesState.decode(String raw) =>
      RoutingProfilesState.fromJson(
        (jsonDecode(raw) as Map).cast<String, dynamic>(),
      );

  factory RoutingProfilesState.fromLegacy(
    TunSettings tun,
    SplitTunnelSettings split,
  ) => RoutingProfilesState(
    activeId: defaultRoutingProfileId,
    profiles: [
      RoutingProfile(
        id: defaultRoutingProfileId,
        name: 'Основной',
        routingMode: tun.routingMode,
        split: split,
        rules: List.unmodifiable(tun.customRules),
      ),
    ],
  );
}
