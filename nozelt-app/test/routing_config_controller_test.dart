import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:nozelt/src/core/routing_rule.dart';
import 'package:nozelt/src/core/split_tunnel_settings.dart';
import 'package:nozelt/src/core/tun_settings.dart';
import 'package:nozelt/src/state/routing_config_controller.dart';
import 'package:nozelt/src/state/routing_profiles_provider.dart';
import 'package:nozelt/src/state/settings_provider.dart';
import 'package:nozelt/src/state/split_tunnel_provider.dart';
import 'package:nozelt/src/data/app_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'concurrent routing edits are serialized without losing fields',
    () async {
      SharedPreferences.setMockInitialValues({});
      final preferences = await SharedPreferences.getInstance();
      final container = ProviderContainer(
        overrides: [sharedPreferencesProvider.overrideWithValue(preferences)],
      );
      addTearDown(container.dispose);

      final controller = container.read(routingConfigControllerProvider);
      await Future.wait([
        controller.setMode(RoutingMode.global),
        controller.setAllowLan(true),
        controller.setSnifferEnabled(true),
      ]);

      final settings = container.read(tunSettingsProvider);
      expect(settings.routingMode, RoutingMode.global);
      expect(settings.allowLan, isTrue);
      expect(settings.snifferEnabled, isTrue);

      final persisted = preferences.getString('tun_settings_v1');
      expect(persisted, isNotNull);
      final restored = TunSettings.decode(persisted!);
      expect(restored.routingMode, RoutingMode.global);
      expect(restored.allowLan, isTrue);
      expect(restored.snifferEnabled, isTrue);
    },
  );

  test('rule priority can be moved and remains persisted', () async {
    SharedPreferences.setMockInitialValues({});
    final preferences = await SharedPreferences.getInstance();
    final container = ProviderContainer(
      overrides: [sharedPreferencesProvider.overrideWithValue(preferences)],
    );
    addTearDown(container.dispose);
    final controller = container.read(routingConfigControllerProvider);

    await controller.upsertRule(
      const RoutingRule(
        id: 'first',
        type: RoutingRuleType.domainSuffix,
        value: 'example.com',
        action: RoutingRuleAction.proxy,
      ),
    );
    await controller.upsertRule(
      const RoutingRule(
        id: 'second',
        type: RoutingRuleType.domainKeyword,
        value: 'telemetry',
        action: RoutingRuleAction.reject,
      ),
    );
    await controller.moveRule('second', -1);

    final settings = container.read(tunSettingsProvider);
    expect(settings.customRules.map((rule) => rule.id), ['second', 'first']);
    final restored = TunSettings.decode(
      preferences.getString('tun_settings_v1')!,
    );
    expect(restored.customRules.map((rule) => rule.id), ['second', 'first']);
  });

  test(
    'routing profiles retain independent split policies and rules',
    () async {
      SharedPreferences.setMockInitialValues({});
      final preferences = await SharedPreferences.getInstance();
      final container = ProviderContainer(
        overrides: [sharedPreferencesProvider.overrideWithValue(preferences)],
      );
      addTearDown(container.dispose);
      final controller = container.read(routingConfigControllerProvider);
      final originalId = container.read(routingProfilesProvider).activeId;

      final secondId = await controller.createProfile('Игры');
      await controller.activateProfile(secondId);
      await container
          .read(splitTunnelProvider.notifier)
          .setMode(SplitMode.allowed);
      await container
          .read(splitTunnelProvider.notifier)
          .toggleApp('org.example.game', true);
      await controller.upsertRule(
        const RoutingRule(
          id: 'games-direct',
          type: RoutingRuleType.geoIp,
          value: 'ru',
          action: RoutingRuleAction.direct,
        ),
      );

      await controller.activateProfile(originalId);
      expect(container.read(splitTunnelProvider).mode, SplitMode.off);
      expect(container.read(routingProfilesProvider).active.rules, isEmpty);

      await controller.activateProfile(secondId);
      final restored = container.read(routingProfilesProvider).active;
      expect(restored.name, 'Игры');
      expect(restored.split.mode, SplitMode.allowed);
      expect(restored.split.apps, {'org.example.game'});
      expect(restored.rules.single.type, RoutingRuleType.geoIp);
    },
  );
}
