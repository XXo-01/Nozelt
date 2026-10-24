import 'dart:convert';

enum AppThemePreference { dark, light, system }

enum TrayClickAction {
  openWindow('open_window'),
  toggleTun('toggle_tun');

  const TrayClickAction(this.wire);
  final String wire;

  static TrayClickAction parse(Object? value) => switch (value) {
    'toggle_tun' => TrayClickAction.toggleTun,
    _ => TrayClickAction.openWindow,
  };
}

class AppSettings {
  const AppSettings({
    this.languageCode = 'ru',
    this.pingIntervalSeconds = 60,
    this.onlineGeoIpEnabled = false,
    this.autoConnectEnabled = false,
    this.trayClickAction = TrayClickAction.openWindow,
    this.startWithWindows = false,
    this.silentStart = false,
    this.themeMode = AppThemePreference.dark,
  });

  final String languageCode;

  /// 0 remains supported for the desktop client. Android exposes intervals
  /// starting at 10 seconds and also accepts a custom value of at least 10.
  final int pingIntervalSeconds;

  /// Online GeoIP reveals proxy server IPs to a third party. It is therefore
  /// explicit opt-in and disabled in privacy-first defaults.
  final bool onlineGeoIpEnabled;

  /// Starts VPN when the Android app is opened while no session is running.
  final bool autoConnectEnabled;

  /// Action performed by a single click on the Windows notification icon.
  final TrayClickAction trayClickAction;
  final bool startWithWindows;
  final bool silentStart;
  final AppThemePreference themeMode;

  static const Set<int> supportedPingIntervals = {0, 10, 20, 30, 60, 300};
  static const Set<int> desktopPingIntervals = {0, 30, 60, 300, 900, 1800};

  static int normalizePingInterval(int value) {
    if (supportedPingIntervals.contains(value)) return value;
    return value >= 10 ? value : 60;
  }

  static int normalizeDesktopPingInterval(int value) {
    if (desktopPingIntervals.contains(value)) return value;
    return value <= 0 ? 0 : 60;
  }

  AppSettings copyWith({
    String? languageCode,
    int? pingIntervalSeconds,
    bool? onlineGeoIpEnabled,
    bool? autoConnectEnabled,
    TrayClickAction? trayClickAction,
    bool? startWithWindows,
    bool? silentStart,
    AppThemePreference? themeMode,
  }) => AppSettings(
    languageCode: languageCode ?? this.languageCode,
    pingIntervalSeconds: pingIntervalSeconds ?? this.pingIntervalSeconds,
    onlineGeoIpEnabled: onlineGeoIpEnabled ?? this.onlineGeoIpEnabled,
    autoConnectEnabled: autoConnectEnabled ?? this.autoConnectEnabled,
    trayClickAction: trayClickAction ?? this.trayClickAction,
    startWithWindows: startWithWindows ?? this.startWithWindows,
    silentStart: silentStart ?? this.silentStart,
    themeMode: themeMode ?? this.themeMode,
  );

  Map<String, dynamic> toMap() => {
    'languageCode': languageCode,
    'pingIntervalSeconds': pingIntervalSeconds,
    'onlineGeoIpEnabled': onlineGeoIpEnabled,
    'autoConnectEnabled': autoConnectEnabled,
    'trayClickAction': trayClickAction.wire,
    'startWithWindows': startWithWindows,
    'silentStart': silentStart,
    'themeMode': themeMode.name,
  };

  factory AppSettings.fromMap(Map<String, dynamic> map) => AppSettings(
    languageCode: map['languageCode'] == 'en' ? 'en' : 'ru',
    pingIntervalSeconds: normalizePingInterval(
      (map['pingIntervalSeconds'] as num?)?.toInt() ?? 60,
    ),
    onlineGeoIpEnabled: map['onlineGeoIpEnabled'] as bool? ?? false,
    autoConnectEnabled: map['autoConnectEnabled'] as bool? ?? false,
    trayClickAction: TrayClickAction.parse(map['trayClickAction']),
    startWithWindows: map['startWithWindows'] as bool? ?? false,
    silentStart: map['silentStart'] as bool? ?? false,
    themeMode: switch (map['themeMode']) {
      'light' => AppThemePreference.light,
      'system' => AppThemePreference.system,
      _ => AppThemePreference.dark,
    },
  );

  String encode() => jsonEncode(toMap());

  factory AppSettings.decode(String raw) =>
      AppSettings.fromMap(jsonDecode(raw) as Map<String, dynamic>);
}
