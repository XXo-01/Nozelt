import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nozelt/src/core/app_settings.dart';
import 'package:nozelt/src/data/app_preferences.dart';
import 'package:nozelt/src/state/app_settings_provider.dart';
import 'package:nozelt/src/state/settings_provider.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('dev.nozelt.nozelt/windows_shell');
  test('legacy settings keep startup opt-in', () {
    final legacy = AppSettings.decode('{"autoConnectEnabled":true}');
    expect(legacy.startWithWindows, false);
    expect(legacy.silentStart, false);
    final saved = AppSettings.decode(
      legacy.copyWith(startWithWindows: true, silentStart: true).encode(),
    );
    expect(saved.autoConnectEnabled, true);
    expect(saved.startWithWindows, true);
    expect(saved.silentStart, true);
  });

  test(
    'queued startup edits preserve both options and native failure preserves preferences',
    () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);
      SharedPreferences.setMockInitialValues({});
      final preferences = await SharedPreferences.getInstance();
      final container = ProviderContainer(
        overrides: [sharedPreferencesProvider.overrideWithValue(preferences)],
      );
      addTearDown(container.dispose);
      final calls = <Map<Object?, Object?>>[];
      var reject = false;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            calls.add(call.arguments as Map<Object?, Object?>);
            if (reject) throw PlatformException(code: 'startup_failed');
            return null;
          });
      addTearDown(
        () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, null),
      );
      final notifier = container.read(appSettingsProvider.notifier);
      await Future.wait([
        notifier.setStartWithWindows(true),
        notifier.setSilentStart(true),
      ]);
      expect(calls.last, {'enabled': true, 'silent': true});
      expect(container.read(appSettingsProvider).startWithWindows, true);
      expect(container.read(appSettingsProvider).silentStart, true);
      reject = true;
      await expectLater(
        notifier.setStartWithWindows(false),
        throwsA(isA<PlatformException>()),
      );
      expect(container.read(appSettingsProvider).startWithWindows, true);
      expect(
        AppSettings.decode(
          preferences.getString('app_settings_v1')!,
        ).silentStart,
        true,
      );
    },
  );
}
