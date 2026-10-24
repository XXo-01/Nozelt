import 'dart:async';
import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nozelt/src/core/profile.dart';
import 'package:nozelt/src/core/proxy_node.dart';
import 'package:nozelt/src/core/split_tunnel_settings.dart';
import 'package:nozelt/src/core/tun_settings.dart';
import 'package:nozelt/src/data/runtime_rollback_journal.dart';
import 'package:nozelt/src/data/sensitive_settings_repository.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('dev.nozelt.nozelt/rollback-test');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  tearDown(() {
    messenger.setMockMethodCallHandler(channel, null);
  });

  SensitiveSettingsRepository repository({
    TunSettings tun = const TunSettings(),
    SplitTunnelSettings split = const SplitTunnelSettings(),
  }) => SensitiveSettingsRepository(
    initial: SensitiveSettingsSnapshot(tun: tun, split: split),
    writer: (_) async {},
  );

  test('preloaded empty journal avoids a duplicate bootstrap read', () async {
    final calls = <String>[];
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call.method);
      return null;
    });

    await restoreNativeRuntimeRollback(
      repository(),
      channel: channel,
      initialJournalWasRead: true,
    );

    expect(calls, isEmpty);
  });

  test('preloaded rollback is applied without reading it twice', () async {
    final calls = <String>[];
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call.method);
      expect(call.method, 'ackRuntimeRollback');
      return true;
    });
    final settings = repository(tun: const TunSettings(mtu: 1500));

    await restoreNativeRuntimeRollback(
      settings,
      channel: channel,
      initialJournal: <String, dynamic>{
        'id': 'preloaded',
        'kind': 'tun',
        'payload': const TunSettings(mtu: 9000).encode(),
        'rolledBack': true,
      },
      initialJournalWasRead: true,
    );

    expect(settings.tun.mtu, 9000);
    expect(calls, ['ackRuntimeRollback']);
  });

  test('native TUN rollback is restored before acknowledgement', () async {
    final settings = repository(
      tun: const TunSettings(mtu: 1500),
      split: const SplitTunnelSettings(
        mode: SplitMode.disallowed,
        apps: {'org.example.keep'},
      ),
    );
    final calls = <String>[];
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call.method);
      if (call.method == 'readRuntimeRollback') {
        return <String, Object>{
          'id': 'journal-1',
          'kind': 'tun',
          'payload': const TunSettings(mtu: 9000).encode(),
          'rolledBack': true,
        };
      }
      expect(call.arguments, {'id': 'journal-1'});
      return true;
    });

    await restoreNativeRuntimeRollback(settings, channel: channel);

    expect(settings.tun.mtu, 9000);
    expect(settings.split.mode, SplitMode.disallowed);
    expect(calls, ['readRuntimeRollback', 'ackRuntimeRollback']);
  });

  test('native per-app rollback preserves current TUN settings', () async {
    final settings = repository(tun: const TunSettings(mtu: 1500));
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'readRuntimeRollback') {
        return <String, Object>{
          'id': 'journal-2',
          'kind': 'split',
          'payload': const SplitTunnelSettings(
            mode: SplitMode.allowed,
            apps: {'org.example.vpn'},
          ).encode(),
          'rolledBack': true,
        };
      }
      return true;
    });

    await restoreNativeRuntimeRollback(settings, channel: channel);

    expect(settings.tun.mtu, 1500);
    expect(settings.split.mode, SplitMode.allowed);
    expect(settings.split.apps, {'org.example.vpn'});
  });

  test(
    'native profile rollback restores exact encrypted profile snapshot',
    () async {
      const previous = ProfilesState(
        activeId: 'old',
        profiles: [
          Profile(
            id: 'old',
            name: 'Old profile',
            type: ProfileType.manual,
            source: '',
            nodes: [
              ProxyNode(
                name: 'Old node',
                type: 'hysteria2',
                server: 'old.example',
                port: 443,
                raw: {
                  'name': 'Old node',
                  'type': 'hysteria2',
                  'server': 'old.example',
                  'port': 443,
                },
              ),
            ],
          ),
        ],
      );
      ProfilesState? restored;
      messenger.setMockMethodCallHandler(channel, (call) async {
        if (call.method == 'readRuntimeRollback') {
          return <String, Object>{
            'id': 'journal-3',
            'kind': 'profiles',
            'payload': jsonEncode(previous.toJson()),
            'rolledBack': true,
          };
        }
        return true;
      });

      await restoreNativeRuntimeRollback(
        repository(),
        channel: channel,
        profilesWriter: (value) async => restored = value,
      );

      expect(restored?.activeId, 'old');
      expect(restored?.active?.nodes.single.name, 'Old node');
    },
  );

  test('failed durable restore keeps native journal unacknowledged', () async {
    final calls = <String>[];
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call.method);
      return <String, Object>{
        'id': 'journal-4',
        'kind': 'profiles',
        'payload': jsonEncode(const ProfilesState().toJson()),
        'rolledBack': true,
      };
    });

    await expectLater(
      restoreNativeRuntimeRollback(
        repository(),
        channel: channel,
        profilesWriter: (_) => Future<void>.error(StateError('write failed')),
      ),
      throwsStateError,
    );

    expect(calls, ['readRuntimeRollback']);
  });

  test('bootstrap waits until a pending native decision is durable', () async {
    final calls = <String>[];
    var reads = 0;
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call.method);
      if (call.method == 'readRuntimeRollback') {
        reads += 1;
        return <String, Object>{
          'id': 'journal-5',
          'kind': 'tun',
          'payload': const TunSettings(mtu: 1400).encode(),
          'rolledBack': reads > 1,
        };
      }
      return true;
    });
    final settings = repository(tun: const TunSettings(mtu: 1500));

    await restoreNativeRuntimeRollback(
      settings,
      channel: channel,
      pendingTimeout: const Duration(milliseconds: 100),
      pendingPollInterval: Duration.zero,
    );

    expect(settings.tun.mtu, 1400);
    expect(calls, [
      'readRuntimeRollback',
      'readRuntimeRollback',
      'ackRuntimeRollback',
    ]);
  });

  test('pending native decision never exposes its rollback payload', () async {
    final calls = <String>[];
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call.method);
      return <String, Object>{
        'id': 'journal-6',
        'kind': 'tun',
        'payload': const TunSettings(mtu: 9000).encode(),
        'rolledBack': false,
      };
    });
    final settings = repository(tun: const TunSettings(mtu: 1500));

    await expectLater(
      restoreNativeRuntimeRollback(
        settings,
        channel: channel,
        pendingTimeout: Duration.zero,
        pendingPollInterval: Duration.zero,
      ),
      throwsA(isA<TimeoutException>()),
    );

    expect(settings.tun.mtu, 1500);
    expect(calls, ['readRuntimeRollback']);
  });
}
