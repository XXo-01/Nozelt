import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:nozelt/src/core/app_settings.dart';
import 'package:nozelt/src/core/split_tunnel_settings.dart';
import 'package:nozelt/src/core/tun_settings.dart';
import 'package:nozelt/src/data/sensitive_settings_repository.dart';
import 'package:nozelt/src/state/app_settings_provider.dart';
import 'package:nozelt/src/state/network_settings_controller.dart';
import 'package:nozelt/src/state/settings_provider.dart';
import 'package:nozelt/src/state/split_tunnel_provider.dart';
import 'package:nozelt/src/data/app_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('rapid TUN setting writes preserve the newest complete state', () async {
    SharedPreferences.setMockInitialValues({});
    final preferences = await SharedPreferences.getInstance();
    final container = ProviderContainer(
      overrides: [sharedPreferencesProvider.overrideWithValue(preferences)],
    );
    addTearDown(container.dispose);
    final notifier = container.read(tunSettingsProvider.notifier);

    final firstWrite = notifier.updatePersisted(
      container.read(tunSettingsProvider).copyWith(mtu: 1500),
    );
    final latest = container
        .read(tunSettingsProvider)
        .copyWith(ipv6: true, nameservers: ['https://9.9.9.9/dns-query']);
    await Future.wait([firstWrite, notifier.updatePersisted(latest)]);

    final restored = TunSettings.decode(
      preferences.getString('tun_settings_v1')!,
    );
    expect(restored.mtu, 1500);
    expect(restored.ipv6, isTrue);
    expect(restored.nameservers, ['https://9.9.9.9/dns-query']);
  });

  test('rapid split-tunnel edits persist their final union', () async {
    SharedPreferences.setMockInitialValues({});
    final preferences = await SharedPreferences.getInstance();
    final container = ProviderContainer(
      overrides: [sharedPreferencesProvider.overrideWithValue(preferences)],
    );
    addTearDown(container.dispose);
    final notifier = container.read(splitTunnelProvider.notifier);

    await Future.wait([
      notifier.setMode(SplitMode.allowed),
      notifier.toggleApp('org.example.one', true),
      notifier.toggleApp('org.example.two', true),
    ]);

    final restored = SplitTunnelSettings.decode(
      preferences.getString('split_tunnel_v1')!,
    );
    expect(restored.mode, SplitMode.allowed);
    expect(restored.apps, {'org.example.one', 'org.example.two'});
  });

  test('rapid app setting edits persist their final union', () async {
    SharedPreferences.setMockInitialValues({});
    final preferences = await SharedPreferences.getInstance();
    final container = ProviderContainer(
      overrides: [sharedPreferencesProvider.overrideWithValue(preferences)],
    );
    addTearDown(container.dispose);
    final notifier = container.read(appSettingsProvider.notifier);

    await Future.wait([
      notifier.setPingInterval(300),
      notifier.setOnlineGeoIp(true),
      notifier.setAutoConnect(true),
      notifier.setLanguage('en'),
    ]);

    final restored = AppSettings.decode(
      preferences.getString('app_settings_v1')!,
    );
    expect(restored.languageCode, 'en');
    expect(restored.pingIntervalSeconds, 300);
    expect(restored.onlineGeoIpEnabled, isTrue);
    expect(restored.autoConnectEnabled, isTrue);
  });

  test('custom ping intervals are accepted from ten seconds', () {
    final custom = AppSettings.fromMap({
      'languageCode': 'ru',
      'pingIntervalSeconds': 42,
      'onlineGeoIpEnabled': false,
      'autoConnectEnabled': true,
    });
    final tooShort = AppSettings.fromMap({
      'languageCode': 'ru',
      'pingIntervalSeconds': 9,
      'onlineGeoIpEnabled': false,
    });

    expect(custom.pingIntervalSeconds, 42);
    expect(custom.autoConnectEnabled, isTrue);
    expect(tooShort.pingIntervalSeconds, 60);
  });

  test('network setting transactions serialize complete values', () async {
    SharedPreferences.setMockInitialValues({});
    final preferences = await SharedPreferences.getInstance();
    final container = ProviderContainer(
      overrides: [sharedPreferencesProvider.overrideWithValue(preferences)],
    );
    addTearDown(container.dispose);
    final controller = container.read(networkSettingsControllerProvider);

    await Future.wait([
      controller.setMtu(1500),
      controller.setIpv6(true),
      controller.setDns(
        fakeIpRange: '198.18.0.0/15',
        nameservers: const ['https://1.1.1.1/dns-query'],
      ),
    ]);

    final restored = TunSettings.decode(
      preferences.getString('tun_settings_v1')!,
    );
    expect(restored.mtu, 1500);
    expect(restored.ipv6, isTrue);
    expect(restored.nameservers, ['https://1.1.1.1/dns-query']);
  });

  test('failed secure TUN write restores the in-memory setting', () async {
    SharedPreferences.setMockInitialValues({});
    final preferences = await SharedPreferences.getInstance();
    final repository = SensitiveSettingsRepository(
      initial: const SensitiveSettingsSnapshot(
        tun: TunSettings(),
        split: SplitTunnelSettings(),
      ),
      writer: (_) => Future<void>.error(StateError('secure store unavailable')),
    );
    final container = ProviderContainer(
      overrides: [
        sharedPreferencesProvider.overrideWithValue(preferences),
        sensitiveSettingsRepositoryProvider.overrideWithValue(repository),
      ],
    );
    addTearDown(container.dispose);

    await expectLater(
      container.read(networkSettingsControllerProvider).setMtu(1500),
      throwsA(isA<StateError>()),
    );
    expect(container.read(tunSettingsProvider).mtu, 9000);
    expect(repository.tun.mtu, 9000);
  });

  test('failed secure split write restores the picker policy', () async {
    SharedPreferences.setMockInitialValues({});
    final preferences = await SharedPreferences.getInstance();
    final repository = SensitiveSettingsRepository(
      initial: const SensitiveSettingsSnapshot(
        tun: TunSettings(),
        split: SplitTunnelSettings(),
      ),
      writer: (_) => Future<void>.error(StateError('secure store unavailable')),
    );
    final container = ProviderContainer(
      overrides: [
        sharedPreferencesProvider.overrideWithValue(preferences),
        sensitiveSettingsRepositoryProvider.overrideWithValue(repository),
      ],
    );
    addTearDown(container.dispose);

    await container
        .read(splitTunnelProvider.notifier)
        .setMode(SplitMode.disallowed);
    await Future<void>.delayed(Duration.zero);

    expect(container.read(splitTunnelProvider).mode, SplitMode.off);
    expect(repository.split.mode, SplitMode.off);
  });

  test('cross-provider sensitive settings share one atomic snapshot', () async {
    SharedPreferences.setMockInitialValues({});
    final preferences = await SharedPreferences.getInstance();
    final repository = SensitiveSettingsRepository.legacy(preferences);

    await Future.wait([
      repository.saveTun(
        const TunSettings().copyWith(
          mtu: 1500,
          nameservers: ['https://9.9.9.9/dns-query'],
        ),
      ),
      repository.saveSplit(
        const SplitTunnelSettings(
          mode: SplitMode.disallowed,
          apps: {'org.example.private'},
        ),
      ),
    ]);

    final snapshot = SensitiveSettingsSnapshot(
      tun: TunSettings.decode(preferences.getString(legacyTunSettingsKey)!),
      split: SplitTunnelSettings.decode(
        preferences.getString(legacySplitTunnelKey)!,
      ),
    );
    final roundTrip = SensitiveSettingsSnapshot.decode(snapshot.encode());
    expect(roundTrip.tun.mtu, 1500);
    expect(roundTrip.tun.nameservers, ['https://9.9.9.9/dns-query']);
    expect(roundTrip.split.mode, SplitMode.disallowed);
    expect(roundTrip.split.apps, {'org.example.private'});
  });

  test('failed TUN write cannot leak into a later split commit', () async {
    var calls = 0;
    SensitiveSettingsSnapshot? durable;
    final repository = SensitiveSettingsRepository(
      initial: const SensitiveSettingsSnapshot(
        tun: TunSettings(),
        split: SplitTunnelSettings(),
      ),
      writer: (encoded) async {
        calls++;
        if (calls == 1) throw StateError('first write failed');
        durable = SensitiveSettingsSnapshot.decode(encoded);
      },
    );

    final failedTun = repository.saveTun(
      const TunSettings().copyWith(mtu: 1500),
    );
    final savedSplit = repository.saveSplit(
      const SplitTunnelSettings(
        mode: SplitMode.disallowed,
        apps: {'org.example.private'},
      ),
    );

    await expectLater(failedTun, throwsA(isA<StateError>()));
    await savedSplit;
    expect(durable, isNotNull);
    expect(durable!.tun.mtu, 9000);
    expect(durable!.split.mode, SplitMode.disallowed);
    expect(repository.tun.mtu, 9000);
    expect(repository.split.mode, SplitMode.disallowed);
  });
}
