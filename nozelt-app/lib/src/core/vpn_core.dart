enum VpnCore {
  mihomo,
  xray,
  singBox;

  String get wireName => switch (this) {
    VpnCore.mihomo => 'mihomo',
    VpnCore.xray => 'xray',
    VpnCore.singBox => 'sing_box',
  };

  String get displayName => switch (this) {
    VpnCore.mihomo => 'Mihomo',
    VpnCore.xray => 'Xray',
    VpnCore.singBox => 'sing-box',
  };

  static VpnCore fromWireName(Object? value) => values.firstWhere(
    (core) => core.wireName == value,
    orElse: () => VpnCore.mihomo,
  );
}

enum ProfileCoreMode {
  automatic,
  manual;

  static ProfileCoreMode fromName(Object? value) => values.firstWhere(
    (mode) => mode.name == value,
    orElse: () => ProfileCoreMode.automatic,
  );
}

VpnCore detectProfileCore(Iterable<Map<String, dynamic>> nodes) {
  var sawSingBox = false;
  for (final node in nodes) {
    final nativeCore = node['nozelt-native-core']?.toString();
    if (nativeCore == VpnCore.xray.wireName) return VpnCore.xray;
    if (nativeCore == VpnCore.singBox.wireName) sawSingBox = true;
  }
  return sawSingBox ? VpnCore.singBox : VpnCore.mihomo;
}
