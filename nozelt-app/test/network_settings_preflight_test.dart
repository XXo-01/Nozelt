import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nozelt/src/core/advanced_network_settings.dart';
import 'package:nozelt/src/core/multi_core_config_builder.dart';
import 'package:nozelt/src/core/profile.dart';
import 'package:nozelt/src/core/proxy_node.dart';
import 'package:nozelt/src/core/tun_settings.dart';
import 'package:nozelt/src/core/vpn_core.dart';
import 'package:nozelt/src/data/app_preferences.dart';
import 'package:nozelt/src/data/profile_store.dart';
import 'package:nozelt/src/state/engine_provider.dart';
import 'package:nozelt/src/state/network_settings_controller.dart';
import 'package:nozelt/src/state/profiles_provider.dart';
import 'package:nozelt/src/state/settings_provider.dart';
import 'support/ui_audit_fixtures.dart';

class _Engine extends AuditEngine {
  bool reject = false;
  int checked = 0;
  @override
  Future<void> validateWindowsConfiguration(CoreRenderedConfig config) async {
    checked++;
    if (reject) throw StateError('synthetic native rejection');
  }
}

class _Store extends ProfileStore {
  @override
  Future<ProfilesState> load() async => ProfilesState(
    activeId: 'test',
    profiles: [
      Profile(
        id: 'test',
        name: 'test',
        type: ProfileType.manual,
        source: '',
        detectedCore: VpnCore.mihomo,
        nodes: [
          ProxyNode.fromRaw({
            'name': 'test',
            'type': 'vless',
            'server': 'vpn.example.test',
            'port': 443,
            'uuid': '11111111-1111-4111-8111-111111111111',
          }),
        ],
      ),
    ],
  );
  @override
  Future<void> save(ProfilesState state) async {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'native preflight rejection leaves preferences and live settings unchanged',
    () async {
      // The offline native preflight is a Windows step.
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      final engine = _Engine()..reject = true;
      final c = ProviderContainer(
        overrides: [
          sharedPreferencesProvider.overrideWithValue(prefs),
          nozeltEngineProvider.overrideWithValue(engine),
          engineStateProvider.overrideWith(() => AuditEngineState(false)),
          profileStoreProvider.overrideWithValue(_Store()),
        ],
      );
      addTearDown(c.dispose);
      await c.read(profilesProvider.future);
      final before = c.read(tunSettingsProvider).encode();
      await expectLater(
        c
            .read(networkSettingsControllerProvider)
            .setAdvancedDns(
              dns: const AdvancedDnsSettings(cacheAlgorithm: 'arc'),
              fakeIpRange: '198.18.0.0/15',
              nameservers: const ['https://9.9.9.9/dns-query'],
            ),
        throwsStateError,
      );
      expect(engine.checked, 1);
      expect(c.read(tunSettingsProvider).encode(), before);
      expect(prefs.getString('tun_settings_v1'), isNull);
      engine.reject = false;
      await c
          .read(networkSettingsControllerProvider)
          .setDesktopTun(
            desktop: const DesktopTunSettings(udpTimeout: 600),
            stack: TunStack.mixed,
            mtu: 1500,
            ipv6: true,
          );
      expect(engine.checked, 2);
      expect(c.read(tunSettingsProvider).desktop.udpTimeout, 600);
      expect(TunSettings.decode(prefs.getString('tun_settings_v1')!).mtu, 1500);
    },
  );
}
