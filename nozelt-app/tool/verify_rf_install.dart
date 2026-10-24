import 'dart:convert';
import 'dart:io';

import 'package:nozelt/src/core/profile.dart';
import 'package:nozelt/src/core/multi_core_config_builder.dart';
import 'package:nozelt/src/core/routing_profile.dart';
import 'package:nozelt/src/core/tun_settings.dart';
import 'package:nozelt/src/core/windows_native_bridge.dart';

dynamic canonical(dynamic value) {
  if (value is Map) {
    final keys = value.keys.cast<String>().toList()..sort();
    return {for (final key in keys) key: canonical(value[key])};
  }
  if (value is List) return value.map(canonical).toList();
  return value;
}

List<String> differentFields(dynamic a, dynamic b, [String path = '']) {
  if (a is Map && b is Map) {
    return {
      ...a.keys,
      ...b.keys,
    }.expand((key) => differentFields(a[key], b[key], '$path/$key')).toList();
  }
  if (a is List && b is List && a.length == b.length) {
    return [
      for (var i = 0; i < a.length; i++)
        ...differentFields(a[i], b[i], '$path/$i'),
    ];
  }
  return jsonEncode(canonical(a)) == jsonEncode(canonical(b)) ? [] : [path];
}

void main(List<String> args) {
  final bridge = WindowsNativeBridge.open();
  Map<String, dynamic> read(String directory, String name) =>
      (jsonDecode(
                bridge.unprotectData(
                  File('$directory/$name').readAsStringSync(),
                ),
              )
              as Map)
          .cast<String, dynamic>();
  final previous = read(args[0], 'profiles.dpapi');
  final current = read(args[1], 'profiles.dpapi');
  final oldProfiles = ProfilesState.fromJson(previous);
  final profiles = ProfilesState.fromJson(current);
  final oldNode = oldProfiles.active?.selectedNode;
  if (oldNode != null) {
    stdout.writeln(
      jsonEncode({
        'sameEndpointCandidates': profiles.active?.nodes
            .where(
              (n) =>
                  n.raw['server'] == oldNode.raw['server'] &&
                  n.raw['port'] == oldNode.raw['port'],
            )
            .map((n) => n.name)
            .toList(),
        'oldNameStillAvailable': profiles.active?.nodes.any(
          (n) => n.name == oldNode.name,
        ),
      }),
    );
  }
  stdout.writeln(
    jsonEncode({
      'selectedServerBefore': oldProfiles.active?.effectiveSelectedNodeName,
      'selectedServerNow': profiles.active?.effectiveSelectedNodeName,
      'subscriptionSourcePreserved':
          oldProfiles.active?.source == profiles.active?.source,
      'activeProfilePreserved': oldProfiles.activeId == profiles.activeId,
      'automaticSubscriptionRefreshOccurred':
          oldProfiles.active?.updatedAt != profiles.active?.updatedAt,
    }),
  );
  final profilesEqual =
      jsonEncode(canonical(oldProfiles.toJson())) ==
      jsonEncode(canonical(profiles.toJson()));
  Map<String, dynamic> persistentProfileSettings(Profile p) {
    final map = p.toJson();
    for (final key in [
      'nodes',
      'providerRouting',
      'updatedAt',
      'subscriptionMetadata',
      'selectedNodeName',
      'topologyRevision',
    ]) {
      map.remove(key);
    }
    return map;
  }

  final profileSettingsPreserved =
      oldProfiles.activeId == profiles.activeId &&
      oldProfiles.profiles.length == profiles.profiles.length &&
      jsonEncode(
            canonical(
              oldProfiles.profiles.map(persistentProfileSettings).toList(),
            ),
          ) ==
          jsonEncode(
            canonical(
              profiles.profiles.map(persistentProfileSettings).toList(),
            ),
          );
  final currentNode = profiles.active?.selectedNode;
  final selectedEndpointPreserved =
      oldNode != null &&
      currentNode != null &&
      oldNode.raw['server'] == currentNode.raw['server'] &&
      oldNode.raw['port'] == currentNode.raw['port'] &&
      oldNode.raw['type'] == currentNode.raw['type'];
  Map<String, dynamic> transportParameters(Map<String, dynamic> raw) {
    final map = Map<String, dynamic>.from(raw);
    map.remove('name');
    map.remove('nozelt-native-config');
    return map;
  }

  final selectedTransportPreserved =
      oldNode != null &&
      currentNode != null &&
      jsonEncode(canonical(transportParameters(oldNode.raw))) ==
          jsonEncode(canonical(transportParameters(currentNode.raw)));
  final before = read(args[0], 'preferences.dpapi');
  final after = read(args[1], 'preferences.dpapi');
  final changedSettings = before.keys
      .where(
        (key) =>
            !{'routing_profiles_v1', 'tun_settings_v1'}.contains(key) &&
            jsonEncode(canonical(before[key])) !=
                jsonEncode(canonical(after[key])),
      )
      .toList();
  final routing = RoutingProfilesState.decode(
    after['routing_profiles_v1'] as String,
  );
  final tun = TunSettings.decode(after['tun_settings_v1'] as String);
  final rendered = MultiCoreConfigBuilder.build(
    tun,
    profile: profiles.active!,
    desktopNativeTun: true,
  );
  final validation =
      jsonDecode(
            bridge.validateCoreConfig(rendered.core.wireName, rendered.content),
          )
          as Map;
  if (validation['ok'] != true) {
    throw StateError('Refreshed server configuration failed native validation');
  }
  if (!profileSettingsPreserved ||
      !selectedEndpointPreserved ||
      !selectedTransportPreserved ||
      changedSettings.isNotEmpty ||
      routing.activeId != 'rf-routing-2026-10-07' ||
      routing.profiles.length != 2) {
    stdout.writeln(
      jsonEncode({
        'profileSettingsPreserved': profileSettingsPreserved,
        'selectedEndpointPreserved': selectedEndpointPreserved,
        'selectedTransportPreserved': selectedTransportPreserved,
        'unrelatedSettingKeysChanged': changedSettings,
        'routingProfileCount': routing.profiles.length,
        'rfProfileActive': routing.activeId == 'rf-routing-2026-10-07',
      }),
    );
    throw StateError(
      'Preservation verification failed; no private values printed',
    );
  }
  stdout.writeln(
    jsonEncode({
      'cachedProfileContentUnchanged': profilesEqual,
      'profileSettingsPreserved': profileSettingsPreserved,
      'selectedEndpointPreserved': selectedEndpointPreserved,
      'selectedTransportPreserved': selectedTransportPreserved,
      'unrelatedSettingsPreserved': changedSettings.isEmpty,
      'routingProfileCount': routing.profiles.length,
      'rfProfileActive': routing.activeId == 'rf-routing-2026-10-07',
      'rfRuleCount': routing.active.rules.length,
      'refreshedServerConfigurationValid': true,
    }),
  );
}
