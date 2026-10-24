import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';

import '../core/routing_profile.dart';
import '../core/routing_rule.dart';
import '../core/runtime_rollback.dart';
import '../core/tun_settings.dart';
import 'engine_provider.dart';
import 'routing_profiles_provider.dart';
import 'settings_provider.dart';
import 'split_tunnel_provider.dart';

final routingConfigControllerProvider = Provider<RoutingConfigController>(
  RoutingConfigController.new,
);

/// Serializes routing-profile edits across encrypted storage, providers and
/// the live VPN generation. Failed native changes restore the entire previous
/// profile set instead of leaving a half-switched policy.
class RoutingConfigController {
  RoutingConfigController(this.ref);

  final Ref ref;
  static const _uuid = Uuid();
  Future<void> _tail = Future<void>.value();

  Future<void> setMode(RoutingMode mode) => _mutateProfiles<void>(
    (current) => current.replace(current.active.copyWith(routingMode: mode)),
    applyRuntime: true,
    restartVpn: true,
  );

  Future<void> setAllowLan(bool enabled) =>
      _mutateTun((current) => current.copyWith(allowLan: enabled));

  Future<void> setSnifferEnabled(bool enabled) =>
      _mutateTun((current) => current.copyWith(snifferEnabled: enabled));

  Future<void> upsertRule(RoutingRule rule, {bool atStart = false}) {
    if (rule.validate() != null) {
      return Future<void>.error(ArgumentError('invalid routing rule'));
    }
    return _mutateActive((current) {
      final index = current.rules.indexWhere((item) => item.id == rule.id);
      final rules = [...current.rules];
      if (index == -1) {
        atStart ? rules.insert(0, rule) : rules.add(rule);
      } else {
        rules[index] = rule;
      }
      return current.copyWith(rules: rules);
    });
  }

  Future<void> replaceRules(List<RoutingRule> rules) {
    if (rules.length > RoutingProfile.maxRules ||
        rules.any((rule) => rule.id.isEmpty || rule.validate() != null) ||
        rules.map((rule) => rule.id).toSet().length != rules.length) {
      return Future<void>.error(ArgumentError('invalid routing rules'));
    }
    return _mutateActive(
      (current) => current.copyWith(rules: List.unmodifiable(rules)),
    );
  }

  Future<void> replaceCategoryRules(
    Set<RoutingRuleType> types,
    Map<RoutingRuleAction, List<(RoutingRuleType, String)>> values,
  ) {
    final replacement = <RoutingRule>[];
    for (final action in RoutingRuleAction.values) {
      for (final entry in values[action] ?? const []) {
        final rule = RoutingRule(
          id: _uuid.v4(),
          type: entry.$1,
          value: entry.$2,
          action: action,
        );
        if (!types.contains(rule.type) || rule.validate() != null) {
          return Future<void>.error(ArgumentError('invalid routing rule'));
        }
        replacement.add(rule);
      }
    }
    return _mutateActive((current) {
      final retained = current.rules
          .where((rule) => !types.contains(rule.type))
          .toList(growable: true);
      retained.addAll(replacement);
      return current.copyWith(rules: retained);
    });
  }

  Future<void> deleteRule(String id) => _mutateActive(
    (current) => current.copyWith(
      rules: current.rules
          .where((rule) => rule.id != id)
          .toList(growable: false),
    ),
  );

  Future<void> setRuleEnabled(String id, bool enabled) => _mutateActive(
    (current) => current.copyWith(
      rules: current.rules
          .map((rule) => rule.id == id ? rule.copyWith(enabled: enabled) : rule)
          .toList(growable: false),
    ),
  );

  Future<void> moveRule(String id, int offset) => _mutateActive((current) {
    final rules = [...current.rules];
    final from = rules.indexWhere((rule) => rule.id == id);
    if (from == -1) return current;
    final to = (from + offset).clamp(0, rules.length - 1);
    if (from == to) return current;
    final rule = rules.removeAt(from);
    rules.insert(to, rule);
    return current.copyWith(rules: rules);
  });

  Future<String> createProfile(String name) {
    final id = _uuid.v4();
    return _mutateProfiles<String>(
      (current) => current.copyWith(
        profiles: [
          ...current.profiles,
          RoutingProfile(id: id, name: name.trim()),
        ],
      ),
      result: id,
    );
  }

  Future<String> importConfig(String raw) {
    final id = _uuid.v4();
    final profile = RoutingProfile.decodeConfig(raw, id: id);
    return _mutateProfiles<String>(
      (current) => current.copyWith(profiles: [...current.profiles, profile]),
      result: id,
    );
  }

  Future<String> importLink(String raw) {
    final id = _uuid.v4();
    final profile = RoutingProfile.decodeShareLink(raw, id: id);
    return _mutateProfiles<String>(
      (current) => current.copyWith(profiles: [...current.profiles, profile]),
      result: id,
    );
  }

  Future<void> replaceActiveFromConfig(String raw) => _mutateActive((current) {
    final imported = RoutingProfile.decodeConfig(raw, id: current.id);
    return imported;
  }, restartVpn: true);

  Future<void> renameProfile(String id, String name) => _mutateProfiles<void>(
    (current) => current.copyWith(
      profiles: [
        for (final profile in current.profiles)
          if (profile.id == id)
            profile.copyWith(name: name.trim())
          else
            profile,
      ],
    ),
  );

  Future<void> deleteProfile(String id) => _mutateProfiles<void>(
    (current) {
      if (current.profiles.length == 1) {
        throw StateError('At least one routing profile is required.');
      }
      final profiles = current.profiles
          .where((profile) => profile.id != id)
          .toList(growable: false);
      if (profiles.length == current.profiles.length) return current;
      return current.copyWith(
        profiles: profiles,
        activeId: current.activeId == id ? profiles.first.id : current.activeId,
      );
    },
    applyRuntime: true,
    restartVpn: true,
    loadSplit: true,
  );

  Future<void> activateProfile(String id) => _mutateProfiles<void>(
    (current) {
      if (!current.profiles.any((profile) => profile.id == id)) {
        throw StateError('Routing profile does not exist.');
      }
      return current.copyWith(activeId: id);
    },
    applyRuntime: true,
    restartVpn: true,
    loadSplit: true,
  );

  Future<void> updateProfileSettings(RoutingProfileSettings settings) {
    final error = settings.validate();
    if (error != null) return Future<void>.error(ArgumentError(error));
    return _mutateActive(
      (current) => current.copyWith(settings: settings),
      restartVpn: true,
    );
  }

  Future<void> markGeoDataUpdated() async {
    final updated = await ref.read(nozeltEngineProvider).updateGeoData();
    if (!updated) throw StateError('Could not update geodata.');
    await _mutateActive(
      (current) => current.copyWith(
        settings: current.settings.copyWith(
          lastGeoUpdateEpochSeconds:
              DateTime.now().toUtc().millisecondsSinceEpoch ~/ 1000,
        ),
      ),
      restartVpn: true,
    );
  }

  Future<void> _mutateActive(
    RoutingProfile Function(RoutingProfile current) transform, {
    bool restartVpn = false,
  }) => _mutateProfiles<void>(
    (current) => current.replace(transform(current.active)),
    applyRuntime: true,
    restartVpn: restartVpn,
  );

  Future<T> _mutateProfiles<T>(
    RoutingProfilesState Function(RoutingProfilesState current) transform, {
    T? result,
    bool applyRuntime = false,
    bool restartVpn = false,
    bool loadSplit = false,
  }) {
    final completer = Completer<T>();
    _tail = _tail.then((_) async {
      RoutingProfilesState? previous;
      var updated = false;
      try {
        if (!ref.mounted) throw StateError('Routing controller disposed.');
        final notifier = ref.read(routingProfilesProvider.notifier);
        final before = ref.read(routingProfilesProvider);
        previous = before;
        final next = transform(before);
        final validationKey = next.validate();
        if (validationKey != null) throw ArgumentError(validationKey);
        updated = true;
        await notifier.updatePersisted(next);
        if (!ref.mounted) throw StateError('Routing controller disposed.');
        if (loadSplit) {
          ref
              .read(splitTunnelProvider.notifier)
              .loadActiveProfile(next.active.split);
        }
        if (applyRuntime) {
          final engine = ref.read(engineStateProvider.notifier);
          final rollback = RuntimeRollbackSnapshot.routingProfiles(before);
          if (restartVpn) {
            await engine.restartWithCurrentConfiguration(rollback: rollback);
          } else {
            await engine.reloadRouting(
              ref.read(effectiveTunSettingsProvider),
              rollback: rollback,
            );
          }
        }
        completer.complete(result as T);
      } catch (error, stackTrace) {
        if (ref.mounted && updated && previous != null) {
          try {
            await ref
                .read(routingProfilesProvider.notifier)
                .updatePersisted(previous);
            if (loadSplit) {
              ref
                  .read(splitTunnelProvider.notifier)
                  .loadActiveProfile(previous.active.split);
            }
          } catch (_) {
            // Preserve the original persistence/native error.
          }
        }
        completer.completeError(error, stackTrace);
      }
    });
    return completer.future;
  }

  Future<void> _mutateTun(TunSettings Function(TunSettings current) transform) {
    final completer = Completer<void>();
    _tail = _tail.then((_) async {
      TunSettings? previous;
      var updated = false;
      try {
        if (!ref.mounted) throw StateError('Routing controller disposed.');
        final notifier = ref.read(tunSettingsProvider.notifier);
        final before = ref.read(tunSettingsProvider);
        previous = before;
        final next = transform(before);
        final validationKey = next.validationKey();
        if (validationKey != null) throw ArgumentError(validationKey);
        updated = true;
        await notifier.updatePersisted(next);
        await ref
            .read(engineStateProvider.notifier)
            .reloadRouting(
              ref.read(effectiveTunSettingsProvider),
              rollback: RuntimeRollbackSnapshot.tun(before),
            );
        completer.complete();
      } catch (error, stackTrace) {
        if (ref.mounted && updated && previous != null) {
          try {
            await ref
                .read(tunSettingsProvider.notifier)
                .updatePersisted(previous);
          } catch (_) {}
        }
        completer.completeError(error, stackTrace);
      }
    });
    return completer.future;
  }
}
