import 'package:flutter_test/flutter_test.dart';
import 'package:nozelt/src/core/app_info.dart';
import 'package:nozelt/src/ui/split_tunnel_screen.dart';

void main() {
  const regularA = AppInfo(
    label: 'Alpha',
    packageName: 'app.alpha',
    system: false,
  );
  const regularB = AppInfo(
    label: 'Beta',
    packageName: 'app.beta',
    system: false,
  );
  const system = AppInfo(
    label: 'Android System',
    packageName: 'android.system',
    system: true,
  );

  test('selected applications are sorted before unselected applications', () {
    final result = filterAndSortSplitTunnelApps(
      apps: const [regularA, regularB, system],
      selected: const {'app.beta'},
      query: '',
      hideSystemApps: false,
    );

    expect(result.map((app) => app.packageName), [
      'app.beta',
      'app.alpha',
      'android.system',
    ]);
  });

  test('system filter retains selected system applications', () {
    final result = filterAndSortSplitTunnelApps(
      apps: const [regularA, regularB, system],
      selected: const {'android.system'},
      query: '',
      hideSystemApps: true,
    );

    expect(result.map((app) => app.packageName), [
      'android.system',
      'app.alpha',
      'app.beta',
    ]);
  });

  test('system filter removes unselected system applications', () {
    final result = filterAndSortSplitTunnelApps(
      apps: const [regularA, system],
      selected: const <String>{},
      query: '',
      hideSystemApps: true,
    );

    expect(result, [regularA]);
  });

  test('search is applied after system visibility and selected grouping', () {
    final result = filterAndSortSplitTunnelApps(
      apps: const [regularA, regularB, system],
      selected: const {'app.beta'},
      query: 'APP.',
      hideSystemApps: false,
    );

    expect(result.map((app) => app.packageName), ['app.beta', 'app.alpha']);
  });
}
