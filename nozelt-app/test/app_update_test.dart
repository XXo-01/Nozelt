import 'package:flutter_test/flutter_test.dart';
import 'package:nozelt/src/core/app_update.dart';

Map<String, dynamic> _release(String tag, {bool prerelease = false}) => {
  'tag_name': tag,
  'draft': false,
  'prerelease': prerelease,
  'html_url': 'https://github.com/XXo-01/Nozelt/releases/tag/$tag',
  'assets': [
    for (final suffix in [
      'android-arm64-v8a.apk',
      'android-armeabi-v7a.apk',
      'windows-x64-portable.zip',
      'windows-x64-setup.exe',
    ])
      {
        'name': 'Nozelt-${tag.substring(1)}-$suffix',
        'browser_download_url':
            'https://github.com/XXo-01/Nozelt/releases/download/$tag/Nozelt-${tag.substring(1)}-$suffix',
        'size': 100,
      },
    {
      'name': 'SHA256SUMS.txt',
      'browser_download_url':
          'https://github.com/XXo-01/Nozelt/releases/download/$tag/SHA256SUMS.txt',
      'size': 10,
    },
  ],
};

void main() {
  group('AppVersion', () {
    AppVersion v(String value) => AppVersion.tryParse(value)!;

    test('parses tags and app versions', () {
      expect(v('v1.1.0').toString(), '1.1.0');
      expect(v('1.0.0+37').toString(), '1.0.0');
      expect(v('2.3').toString(), '2.3.0');
      expect(v('1.2.0-beta.2').isPrerelease, isTrue);
      expect(AppVersion.tryParse('latest'), isNull);
      expect(AppVersion.tryParse(''), isNull);
    });

    test('orders by SemVer', () {
      expect(v('1.1.0') > v('1.0.0'), isTrue);
      expect(v('1.10.0') > v('1.9.9'), isTrue);
      expect(v('2.0.0') > v('1.99.99'), isTrue);
      expect(v('1.0.0') > v('1.0.0'), isFalse);
      expect(v('1.0.0+40') > v('1.0.0+37'), isFalse);
      expect(v('1.1.0') > v('1.1.0-rc.1'), isTrue);
      expect(v('1.1.0-rc.2') > v('1.1.0-rc.1'), isTrue);
      expect(v('1.1.0-rc.10') > v('1.1.0-rc.9'), isTrue);
      expect(v('1.1.0-beta') > v('1.1.0-alpha'), isTrue);
    });
  });

  group('AppRelease', () {
    test('reads a GitHub release and compares with the app', () {
      final release = AppRelease.fromGitHubJson(_release('v1.2.0'))!;
      expect(release.version.toString(), '1.2.0');
      expect(release.isNewerThan('1.1.0'), isTrue);
      expect(release.isNewerThan('1.2.0'), isFalse);
      expect(release.isNewerThan('1.3.0'), isFalse);
      expect(release.checksums?.name, 'SHA256SUMS.txt');
    });

    test('ignores drafts, pre-releases and bad tags', () {
      expect(
        AppRelease.fromGitHubJson(_release('v1.2.0', prerelease: true)),
        isNull,
      );
      expect(
        AppRelease.fromGitHubJson({..._release('v1.2.0'), 'draft': true}),
        isNull,
      );
      expect(AppRelease.fromGitHubJson(_release('v1.2.0-rc.1')), isNull);
      expect(
        AppRelease.fromGitHubJson({..._release('v1.2.0'), 'tag_name': 'next'}),
        isNull,
      );
      expect(AppRelease.fromGitHubJson('not json'), isNull);
    });

    test('drops non-HTTPS download links', () {
      final json = _release('v1.2.0');
      (json['assets'] as List).add({
        'name': 'evil.apk',
        'browser_download_url': 'http://example.com/evil.apk',
      });
      final release = AppRelease.fromGitHubJson(json)!;
      expect(release.assets.any((asset) => asset.name == 'evil.apk'), isFalse);
    });
  });

  group('asset selection', () {
    final release = AppRelease.fromGitHubJson(_release('v1.2.0'))!;

    test('picks the build for each target', () {
      expect(
        selectUpdateAsset(release, UpdateTarget.androidArm64)?.name,
        'Nozelt-1.2.0-android-arm64-v8a.apk',
      );
      expect(
        selectUpdateAsset(release, UpdateTarget.androidArmV7)?.name,
        'Nozelt-1.2.0-android-armeabi-v7a.apk',
      );
      expect(
        selectUpdateAsset(release, UpdateTarget.windowsInstaller)?.name,
        'Nozelt-1.2.0-windows-x64-setup.exe',
      );
      expect(
        selectUpdateAsset(release, UpdateTarget.windowsPortable)?.name,
        'Nozelt-1.2.0-windows-x64-portable.zip',
      );
    });

    test('accepts a differently versioned name with the same suffix', () {
      final odd = AppRelease(
        version: release.version,
        tagName: 'v1.2.0',
        pageUrl: release.pageUrl,
        assets: const [
          ReleaseAsset(
            name: 'Nozelt-1.2-android-arm64-v8a.apk',
            downloadUrl: 'https://example.com/a.apk',
          ),
        ],
      );
      expect(selectUpdateAsset(odd, UpdateTarget.androidArm64), isNotNull);
      expect(selectUpdateAsset(odd, UpdateTarget.windowsInstaller), isNull);
    });

    test('maps device ABIs to the APK', () {
      expect(
        UpdateTarget.forAndroidAbis(['arm64-v8a', 'armeabi-v7a', 'armeabi']),
        UpdateTarget.androidArm64,
      );
      expect(
        UpdateTarget.forAndroidAbis(['armeabi-v7a', 'armeabi']),
        UpdateTarget.androidArmV7,
      );
      expect(UpdateTarget.forAndroidAbis(['x86_64']), isNull);
    });
  });

  test('parses SHA256SUMS', () {
    final hash = 'A' * 64;
    final sums = parseSha256Sums(
      '$hash  Nozelt-1.2.0-android-arm64-v8a.apk\r\n'
      '${'b' * 64} *Nozelt-1.2.0-windows-x64-setup.exe\n'
      'garbage line\n',
    );
    expect(sums['Nozelt-1.2.0-android-arm64-v8a.apk'], 'a' * 64);
    expect(sums['Nozelt-1.2.0-windows-x64-setup.exe'], 'b' * 64);
    expect(sums, hasLength(2));
  });
}
