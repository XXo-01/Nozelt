import 'dart:convert';
import 'dart:io';

import 'package:nozelt/src/core/app_settings.dart';
import 'package:nozelt/src/core/config_builder.dart';
import 'package:nozelt/src/core/multi_core_config_builder.dart';
import 'package:nozelt/src/core/profile.dart';
import 'package:nozelt/src/core/proxy_node.dart';
import 'package:nozelt/src/core/routing_profile.dart';
import 'package:nozelt/src/core/routing_rule.dart';
import 'package:nozelt/src/core/split_tunnel_settings.dart';
import 'package:nozelt/src/core/tun_settings.dart';
import 'package:nozelt/src/core/windows_native_bridge.dart';

// Offline, same-user DPAPI configuration. Never starts/stops a core or TUN.
// Default is a dry run. Writes only after native validation and a backup.
void main(List<String> args) {
  if (args.length < 3) {
    throw ArgumentError(
      'portable-data, source text, export directory [--apply]',
    );
  }
  final directory = Directory(args[0]);
  final exportDirectory = Directory(args[2])..createSync(recursive: true);
  final bridge = WindowsNativeBridge.open();
  final preferencesFile = File('${directory.path}/preferences.dpapi');
  final protectedBefore = preferencesFile.readAsStringSync();
  final preferences = (jsonDecode(bridge.unprotectData(protectedBefore)) as Map)
      .cast<String, dynamic>();
  final profilesFile = File('${directory.path}/profiles.dpapi');
  final protectedProfiles = profilesFile.readAsStringSync();
  final profiles = ProfilesState.fromJson(
    (jsonDecode(bridge.unprotectData(protectedProfiles)) as Map)
        .cast<String, dynamic>(),
  );
  final tun = preferences['tun_settings_v1'] is String
      ? TunSettings.decode(preferences['tun_settings_v1'] as String)
      : const TunSettings();
  final split = preferences['split_tunnel_v1'] is String
      ? SplitTunnelSettings.decode(preferences['split_tunnel_v1'] as String)
      : const SplitTunnelSettings();
  final oldRouting = preferences['routing_profiles_v1'] is String
      ? RoutingProfilesState.decode(
          preferences['routing_profiles_v1'] as String,
        )
      : RoutingProfilesState.fromLegacy(tun, split);
  final rules = <RoutingRule>[];
  final unsupported = <String>[];
  final seen = <String>{};
  var redundant = 0;
  for (final line in File(args[1]).readAsLinesSync()) {
    final text = line.trim();
    if (!text.startsWith('- ')) continue;
    final fields = text.substring(2).split(',');
    if (fields.length < 3) throw const FormatException('Invalid routing entry');
    final kind = fields[0];
    if (kind == 'PROCESS-PATH-REGEX') {
      unsupported.add(fields[1]);
      continue;
    }
    final type = switch (kind) {
      'PROCESS-NAME' => RoutingRuleType.processName,
      'DOMAIN' => RoutingRuleType.domain,
      'DOMAIN-SUFFIX' => RoutingRuleType.domainSuffix,
      'IP-CIDR' || 'IP-CIDR6' => RoutingRuleType.ipCidr,
      'GEOSITE' => RoutingRuleType.geoSite,
      'GEOIP' => RoutingRuleType.geoIp,
      _ => throw FormatException('Unsupported rule kind: $kind'),
    };
    final action = switch (fields[2]) {
      'DIRECT' => RoutingRuleAction.direct,
      'REJECT' => RoutingRuleAction.reject,
      _ => RoutingRuleAction.proxy,
    };
    var value = fields[1].toLowerCase();
    var effectiveType = type;
    if (action == RoutingRuleAction.proxy && type == RoutingRuleType.domain) {
      effectiveType = RoutingRuleType.domainSuffix;
    }
    if (!seen.add('${effectiveType.name}|$value|${action.name}')) {
      redundant++;
      continue;
    }
    rules.add(
      RoutingRule(
        id: 'rf-rule-${rules.length}',
        type: effectiveType,
        value: value,
        action: action,
      ),
    );
  }
  // Remove only same-action explicit suffixes covered by another explicit suffix.
  final redundantIds = <String>{};
  for (final rule in rules.where(
    (r) => r.type == RoutingRuleType.domainSuffix,
  )) {
    if (rules.any(
      (other) =>
          other.id != rule.id &&
          other.type == RoutingRuleType.domainSuffix &&
          other.action == rule.action &&
          rule.value.endsWith('.${other.value}'),
    )) {
      redundantIds.add(rule.id);
    }
  }
  redundant += redundantIds.length;
  rules.removeWhere((rule) => redundantIds.contains(rule.id));
  // A narrow explicit exception for the installed Minecraft launcher; retain
  // the source's existing Java/game process decisions rather than widening them.
  rules.add(
    RoutingRule(
      id: 'rf-prism-launcher',
      type: RoutingRuleType.processName,
      value: 'prismlauncher.exe',
      action: RoutingRuleAction.direct,
    ),
  );
  const id = 'rf-routing-2026-10-07';
  final profile = RoutingProfile(
    id: id,
    name: 'РФ — напрямую / остальное через VPN',
    rules: rules,
    split: oldRouting.active.split,
    settings: RoutingProfileSettings(
      lastGeoUpdateEpochSeconds: DateTime.now().millisecondsSinceEpoch ~/ 1000,
    ),
  );
  final error = profile.validate();
  if (error != null) throw FormatException(error);
  final nextRouting = oldRouting.copyWith(
    profiles: [...oldRouting.profiles.where((p) => p.id != id), profile],
    activeId: id,
  );
  if (nextRouting.validate() != null) {
    throw const FormatException('Invalid routing state');
  }
  final effective = tun.copyWith(
    routingMode: RoutingMode.rule,
    customRules: profile.orderedRules,
    geoUpdateIntervalHours: profile.settings.geoUpdateIntervalHours,
  );
  // Always validate RF Geo/process/domain/IP rules in the common frontend,
  // even if an old selected transport profile needs separate correction.
  final frontend = ConfigBuilder.buildConfig(
    effective,
    nodes: [
      ProxyNode.fromRaw({
        'name': 'RF validation',
        'type': 'socks5',
        'server': '127.0.0.1',
        'port': 1,
        'udp': true,
      }),
    ],
    desktopNativeTun: true,
  );
  final checked =
      jsonDecode(bridge.validateCoreConfig('mihomo', frontend)) as Map;
  if (checked['ok'] != true) {
    throw const FormatException(
      'RF native routing validation failed; no preferences written',
    );
  }
  String selectedValidation = 'no selected server';
  if (profiles.active != null) {
    try {
      final rendered = MultiCoreConfigBuilder.build(
        effective,
        profile: profiles.active!,
        desktopNativeTun: true,
      );
      final result =
          jsonDecode(
                bridge.validateCoreConfig(
                  rendered.core.wireName,
                  rendered.content,
                ),
              )
              as Map;
      selectedValidation = result['ok'] == true
          ? 'valid'
          : 'native validation rejected';
    } catch (_) {
      selectedValidation = 'old transport profile requires review';
    }
  }
  File(
    '${exportDirectory.path}/rf-routing.json',
  ).writeAsStringSync(profile.encodeConfig(), flush: true);
  File(
    '${exportDirectory.path}/rf-routing-link.txt',
  ).writeAsStringSync(profile.encodeShareLink(), flush: true);
  File('${exportDirectory.path}/rf-rules.yaml').writeAsStringSync(
    'rules:\n${profile.orderedRules.map((r) => '  - ${r.toMihomoRule('PROXY')}').join('\n')}\n  - MATCH,PROXY\n',
    flush: true,
  );
  final appSettings = preferences['app_settings_v1'] is String
      ? AppSettings.decode(preferences['app_settings_v1'] as String)
      : const AppSettings();
  if (args.contains('--apply')) {
    final backup = File('${exportDirectory.path}/preferences-before-rf.dpapi');
    if (backup.existsSync()) {
      throw StateError('Backup already exists; refusing to overwrite');
    }
    backup.writeAsStringSync(protectedBefore, flush: true);
    final nextPreferences = Map<String, dynamic>.from(preferences);
    final rawTun = preferences['tun_settings_v1'] is String
        ? (jsonDecode(preferences['tun_settings_v1'] as String) as Map)
              .cast<String, dynamic>()
        : tun.toMap();
    nextPreferences['routing_profiles_v1'] = nextRouting.encode();
    nextPreferences['tun_settings_v1'] = jsonEncode({
      ...rawTun,
      'routingMode': 'rule',
      'customRules': profile.orderedRules.map((r) => r.toJson()).toList(),
      'geoUpdateIntervalHours': profile.settings.geoUpdateIntervalHours,
    });
    if (profilesFile.readAsStringSync() != protectedProfiles ||
        preferencesFile.readAsStringSync() != protectedBefore) {
      throw StateError('Data changed during preparation');
    }
    final encoded = jsonEncode(nextPreferences);
    final encrypted = bridge.protectData(encoded);
    if (bridge.unprotectData(encrypted) != encoded) {
      throw StateError('DPAPI round trip failed');
    }
    File(
      '${preferencesFile.path}.rf-new',
    ).writeAsStringSync(encrypted, flush: true);
    File('${preferencesFile.path}.rf-new').renameSync(preferencesFile.path);
    final committed =
        (jsonDecode(bridge.unprotectData(preferencesFile.readAsStringSync()))
                as Map)
            .cast<String, dynamic>();
    if (committed['routing_profiles_v1'] != nextRouting.encode()) {
      throw StateError('Routing readback failed');
    }
    for (final key in preferences.keys.where(
      (key) => !{'tun_settings_v1', 'routing_profiles_v1'}.contains(key),
    )) {
      if (jsonEncode(committed[key]) != jsonEncode(preferences[key])) {
        throw StateError('Unrelated preference changed');
      }
    }
    if (profilesFile.readAsStringSync() != protectedProfiles) {
      throw StateError('VPN profiles changed');
    }
  }
  stdout.writeln(
    jsonEncode({
      'applied': args.contains('--apply'),
      'ruleCount': rules.length,
      'redundantRemoved': redundant,
      'unsupportedPathRules': unsupported.length,
      'routingProfilesBefore': oldRouting.profiles.length,
      'routingProfilesAfter': nextRouting.profiles.length,
      'vpnProfilesPreserved': profiles.profiles.length,
      'selectedTransportValidation': selectedValidation,
      'autoConnectEnabled': appSettings.autoConnectEnabled,
      'core': profiles.active?.effectiveCore.wireName,
    }),
  );
}
