import 'dart:async';
import 'package:alchemist/alchemist.dart';
import 'package:flutter_test/flutter_test.dart';
import '../support/ui_audit_fixtures.dart';

Future<void> testExecutable(FutureOr<void> Function() testMain) async {
  TestWidgetsFlutterBinding.ensureInitialized();
  await loadAuditFonts();
  await AlchemistConfig.runWithConfig(
    config: AlchemistConfig(
      // Readable snapshots are specific to Windows/Segoe UI. CI snapshots use
      // Alchemist's obscured text. Keep exact comparison; no pixel tolerance.
      platformGoldensConfig: PlatformGoldensConfig(
        platforms: {HostPlatform.windows},
        renderShadows: false,
        filePathResolver: (name, environment) =>
            'goldens/$environment/$name.png',
      ),
      ciGoldensConfig: CiGoldensConfig(
        filePathResolver: (name, environment) => 'goldens/ci/$name.png',
      ),
    ),
    run: testMain,
  );
}
