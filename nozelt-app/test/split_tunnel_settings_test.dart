import 'package:flutter_test/flutter_test.dart';
import 'package:nozelt/src/core/split_tunnel_settings.dart';

void main() {
  test('interactive selection normalizes and validates package names', () {
    final settings = const SplitTunnelSettings()
        .toggleApp('  org.example.app  ', true)
        .toggleApp('bad\u0000package', true)
        .toggleApp('', true);

    expect(settings.apps, {'org.example.app'});
  });

  test('interactive selection cannot exceed the persisted app limit', () {
    final full = SplitTunnelSettings(
      apps: {
        for (var index = 0; index < maxSplitTunnelApps; index++)
          'org.example.app$index',
      },
    );

    expect(full.toggleApp('org.example.extra', true), same(full));
    expect(full.toggleApp('org.example.app0', true), isNot(same(full)));
    expect(
      full.toggleApp('org.example.app0', false).apps.length,
      maxSplitTunnelApps - 1,
    );
  });

  test('decoded selections discard malformed and excess packages', () {
    final decoded = SplitTunnelSettings.fromMap({
      'mode': 'allowed',
      'apps': [
        ' org.example.valid ',
        'bad\u007fpackage',
        for (var index = 0; index < maxSplitTunnelApps; index++)
          'org.example.app$index',
        'org.example.excess',
      ],
    });

    expect(decoded.mode, SplitMode.allowed);
    expect(decoded.apps.length, maxSplitTunnelApps);
    expect(decoded.apps, contains('org.example.valid'));
    expect(decoded.apps, isNot(contains('bad\u007fpackage')));
    expect(decoded.apps, isNot(contains('org.example.excess')));
  });
}
