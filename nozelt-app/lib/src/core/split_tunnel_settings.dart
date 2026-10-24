import 'dart:convert';

const int maxSplitTunnelApps = 4096;
final RegExp _invalidPackageCharacter = RegExp(r'[\u0000-\u001f\u007f]');

bool isValidSplitTunnelPackage(String value) =>
    value.isNotEmpty &&
    value.length <= 255 &&
    !_invalidPackageCharacter.hasMatch(value);

/// Split-tunneling mode. Maps to the `splitMode` string the Kotlin
/// VpnService reads (see NozeltVpnService.applySplitTunneling).
///
/// Nozelt's UI process remains inside the tunnel. Only mihomo's transport
/// sockets bypass it through VpnService.protect(fd), which avoids granting all
/// same-UID application traffic a clear-network exception.
enum SplitMode {
  /// Every app is tunneled.
  off,

  /// Only the selected apps are tunneled.
  allowed,

  /// Every app is tunneled except the selected ones.
  disallowed;

  String get wire => name; // 'off' | 'allowed' | 'disallowed'

  static SplitMode fromName(String? v) => SplitMode.values.firstWhere(
    (m) => m.name == v,
    orElse: () => SplitMode.off,
  );
}

/// Persisted split-tunneling selection. Immutable; edit via [copyWith].
class SplitTunnelSettings {
  const SplitTunnelSettings({
    this.mode = SplitMode.off,
    this.apps = const <String>{},
  });

  final SplitMode mode;

  /// Package names the [mode] applies to. Ignored when [mode] is
  /// [SplitMode.off].
  final Set<String> apps;

  SplitTunnelSettings copyWith({SplitMode? mode, Set<String>? apps}) =>
      SplitTunnelSettings(mode: mode ?? this.mode, apps: apps ?? this.apps);

  SplitTunnelSettings toggleApp(String pkg, bool selected) {
    final normalized = pkg.trim();
    if (!isValidSplitTunnelPackage(normalized)) return this;
    final next = Set<String>.of(apps);
    if (selected) {
      if (next.length >= maxSplitTunnelApps && !next.contains(normalized)) {
        return this;
      }
      next.add(normalized);
    } else {
      next.remove(normalized);
    }
    return copyWith(apps: next);
  }

  Map<String, dynamic> toMap() => {
    'mode': mode.name,
    'apps': apps.toList(growable: false)..sort(),
  };

  factory SplitTunnelSettings.fromMap(Map<String, dynamic> map) =>
      SplitTunnelSettings(
        mode: SplitMode.fromName(map['mode'] as String?),
        apps: ((map['apps'] as List?) ?? const <dynamic>[])
            .whereType<String>()
            .map((value) => value.trim())
            .where(isValidSplitTunnelPackage)
            .take(maxSplitTunnelApps)
            .toSet(),
      );

  String encode() => jsonEncode(toMap());

  factory SplitTunnelSettings.decode(String json) =>
      SplitTunnelSettings.fromMap(jsonDecode(json) as Map<String, dynamic>);

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is SplitTunnelSettings &&
          mode == other.mode &&
          apps.length == other.apps.length &&
          apps.containsAll(other.apps);

  @override
  int get hashCode {
    final orderedApps = apps.toList(growable: false)..sort();
    return Object.hash(mode, Object.hashAll(orderedApps));
  }
}
