import 'dart:convert';
import 'dart:io';

import 'package:nozelt/src/core/multi_core_config_builder.dart';
import 'package:nozelt/src/core/profile.dart';
import 'package:nozelt/src/core/tun_settings.dart';
import 'package:nozelt/src/core/vpn_core.dart';
import 'package:nozelt/src/core/windows_native_bridge.dart';

// Read-only profile preparation for the opt-in Go transport diagnostic.
// The temporary artifact is DPAPI encrypted and contains no plaintext secrets.
void main(List<String> args) {
  if (args.length != 2) {
    throw ArgumentError(
      'Expected portable-data directory and encrypted output.',
    );
  }
  final bridge = WindowsNativeBridge.open();
  final directory = Directory(args[0]);
  final profiles = ProfilesState.fromJson(
    (jsonDecode(
              bridge.unprotectData(
                File('${directory.path}/profiles.dpapi').readAsStringSync(),
              ),
            )
            as Map)
        .cast<String, dynamic>(),
  );
  final profile = profiles.active;
  if (profile == null || profile.effectiveCore == VpnCore.mihomo) {
    throw StateError('Selected profile must use a native transport core.');
  }
  final preferences =
      jsonDecode(
            bridge.unprotectData(
              File('${directory.path}/preferences.dpapi').readAsStringSync(),
            ),
          )
          as Map;
  final settings = preferences['tun_settings_v1'] is String
      ? TunSettings.decode(preferences['tun_settings_v1'] as String)
      : const TunSettings();
  final rendered = MultiCoreConfigBuilder.build(
    settings,
    profile: profile,
    desktopNativeTun: true,
  );
  File(args[1]).writeAsStringSync(
    bridge.protectData(
      jsonEncode({
        'core': rendered.core.wireName,
        'config': jsonDecode(rendered.content),
      }),
    ),
    flush: true,
  );
  stdout.writeln('Encrypted ${rendered.core.displayName} diagnostic prepared.');
}
