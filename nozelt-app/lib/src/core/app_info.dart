/// A single installed application, as reported by the Kotlin `getInstalledApps`
/// method channel. Icons are fetched lazily and separately (see
/// `getAppIcon`) so the list itself loads fast even with hundreds of apps.
class AppInfo {
  const AppInfo({
    required this.label,
    required this.packageName,
    required this.system,
  });

  final String label;
  final String packageName;

  /// True for system/preinstalled apps (FLAG_SYSTEM). The UI can visually
  /// distinguish or filter these.
  final bool system;

  factory AppInfo.fromMap(Map<dynamic, dynamic> map) => AppInfo(
    label: (map['label'] as String?) ?? (map['packageName'] as String),
    packageName: map['packageName'] as String,
    system: (map['system'] as bool?) ?? false,
  );
}
