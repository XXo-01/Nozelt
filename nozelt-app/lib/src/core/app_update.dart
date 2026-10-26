/// Pure parts of the GitHub Releases updater: versions, release metadata,
/// asset selection and SHA256SUMS parsing. No I/O, so it is unit-tested.
library;

const String updateRepository = 'XXo-01/Nozelt';
const String latestReleaseApi =
    'https://api.github.com/repos/$updateRepository/releases/latest';
const String releasesPage = 'https://github.com/$updateRepository/releases';

/// A semantic version `major.minor.patch[-pre][+build]`; build metadata is
/// ignored for ordering, as SemVer requires.
class AppVersion implements Comparable<AppVersion> {
  const AppVersion(this.major, this.minor, this.patch, [this.pre = const []]);

  final int major;
  final int minor;
  final int patch;
  final List<String> pre;

  static final _pattern = RegExp(
    r'^[vV]?(\d{1,6})\.(\d{1,6})(?:\.(\d{1,6}))?(?:-([0-9A-Za-z.-]+))?(?:\+[0-9A-Za-z.-]+)?$',
  );

  static AppVersion? tryParse(String? value) {
    final match = _pattern.firstMatch(value?.trim() ?? '');
    if (match == null) return null;
    return AppVersion(
      int.parse(match[1]!),
      int.parse(match[2]!),
      int.parse(match[3] ?? '0'),
      match[4]?.split('.') ?? const [],
    );
  }

  bool get isPrerelease => pre.isNotEmpty;

  @override
  int compareTo(AppVersion other) {
    for (final (a, b) in [
      (major, other.major),
      (minor, other.minor),
      (patch, other.patch),
    ]) {
      if (a != b) return a.compareTo(b);
    }
    // A release ranks above its pre-releases.
    if (pre.isEmpty || other.pre.isEmpty) {
      return pre.isEmpty == other.pre.isEmpty ? 0 : (pre.isEmpty ? 1 : -1);
    }
    for (var i = 0; i < pre.length && i < other.pre.length; i++) {
      final a = pre[i];
      final b = other.pre[i];
      final na = int.tryParse(a);
      final nb = int.tryParse(b);
      final result = na != null && nb != null
          ? na.compareTo(nb)
          : na != null
          ? -1
          : nb != null
          ? 1
          : a.compareTo(b);
      if (result != 0) return result;
    }
    return pre.length.compareTo(other.pre.length);
  }

  bool operator >(AppVersion other) => compareTo(other) > 0;

  @override
  bool operator ==(Object other) =>
      other is AppVersion && compareTo(other) == 0;

  @override
  int get hashCode => Object.hash(major, minor, patch, pre.join('.'));

  @override
  String toString() =>
      '$major.$minor.$patch${pre.isEmpty ? '' : '-${pre.join('.')}'}';
}

class ReleaseAsset {
  const ReleaseAsset({
    required this.name,
    required this.downloadUrl,
    this.size = 0,
  });

  final String name;
  final String downloadUrl;
  final int size;
}

class AppRelease {
  const AppRelease({
    required this.version,
    required this.tagName,
    required this.pageUrl,
    required this.assets,
  });

  final AppVersion version;
  final String tagName;
  final String pageUrl;
  final List<ReleaseAsset> assets;

  /// Reads one GitHub `releases/latest` object. Drafts, pre-releases,
  /// unparsable tags and non-HTTPS links are rejected.
  static AppRelease? fromGitHubJson(Object? json) {
    if (json is! Map) return null;
    if (json['draft'] == true || json['prerelease'] == true) return null;
    final tag = json['tag_name']?.toString() ?? '';
    final version = AppVersion.tryParse(tag);
    if (version == null || version.isPrerelease) return null;
    final page = _https(json['html_url']) ?? releasesPage;
    final assets = <ReleaseAsset>[
      for (final raw in (json['assets'] as List?) ?? const [])
        if (raw is Map)
          if (_https(raw['browser_download_url']) case final String url)
            ReleaseAsset(
              name: raw['name']?.toString() ?? '',
              downloadUrl: url,
              size: (raw['size'] as num?)?.toInt() ?? 0,
            ),
    ];
    return AppRelease(
      version: version,
      tagName: tag,
      pageUrl: page,
      assets: assets,
    );
  }

  static String? _https(Object? value) {
    final uri = Uri.tryParse(value?.toString() ?? '');
    return uri != null && uri.isScheme('https') && uri.host.isNotEmpty
        ? uri.toString()
        : null;
  }

  bool isNewerThan(String current) {
    final installed = AppVersion.tryParse(current);
    return installed == null || version > installed;
  }

  /// The checksum list published next to the builds.
  ReleaseAsset? get checksums {
    for (final asset in assets) {
      final name = asset.name.toLowerCase();
      if (name == 'sha256sums.txt' || name == 'sha256sums') return asset;
    }
    return null;
  }
}

/// What this copy of Nozelt updates from.
enum UpdateTarget {
  androidArm64('android-arm64-v8a.apk'),
  androidArmV7('android-armeabi-v7a.apk'),
  windowsInstaller('windows-x64-setup.exe'),
  windowsPortable('windows-x64-portable.zip');

  const UpdateTarget(this.suffix);

  /// Asset names are `Nozelt-<version>-<suffix>`.
  final String suffix;

  bool get isAndroid =>
      this == UpdateTarget.androidArm64 || this == UpdateTarget.androidArmV7;

  /// The first supported ABI the device prefers.
  static UpdateTarget? forAndroidAbis(Iterable<String> abis) {
    for (final abi in abis) {
      switch (abi.trim().toLowerCase()) {
        case 'arm64-v8a':
          return UpdateTarget.androidArm64;
        case 'armeabi-v7a':
          return UpdateTarget.androidArmV7;
      }
    }
    return null;
  }
}

/// Picks the build for [target]: the exact `Nozelt-<version>-<suffix>` name
/// first, then any Nozelt asset with that suffix.
ReleaseAsset? selectUpdateAsset(AppRelease release, UpdateTarget target) {
  final exact = 'nozelt-${release.version}-${target.suffix}';
  for (final asset in release.assets) {
    if (asset.name.toLowerCase() == exact) return asset;
  }
  for (final asset in release.assets) {
    final name = asset.name.toLowerCase();
    if (name.startsWith('nozelt-') && name.endsWith('-${target.suffix}')) {
      return asset;
    }
  }
  return null;
}

/// Parses `sha256sum` output: `<hex>  <name>` or `<hex> *<name>`.
Map<String, String> parseSha256Sums(String text) {
  final result = <String, String>{};
  final line = RegExp(r'^([0-9a-fA-F]{64})\s+\*?(.+?)\s*$');
  for (final raw in text.split(RegExp(r'\r?\n'))) {
    final match = line.firstMatch(raw.trim());
    if (match == null) continue;
    final name = match[2]!.split(RegExp(r'[\\/]')).last;
    result[name] = match[1]!.toLowerCase();
  }
  return result;
}
