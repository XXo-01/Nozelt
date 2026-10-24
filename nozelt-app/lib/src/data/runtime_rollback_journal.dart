import 'dart:async';
import 'dart:convert';
import 'dart:isolate';

import 'package:flutter/services.dart';

import '../core/profile.dart';
import '../core/routing_profile.dart';
import '../core/split_tunnel_settings.dart';
import '../core/tun_settings.dart';
import 'profile_store.dart';
import 'sensitive_settings_repository.dart';

const _engineChannel = MethodChannel('dev.nozelt.nozelt/engine');
const _journalTimeout = Duration(seconds: 8);
const _pendingJournalTimeout = Duration(seconds: 32);
const _pendingJournalPollInterval = Duration(milliseconds: 250);
const _maxJournalCharacters = 32 * 1024 * 1024;

typedef ProfilesRollbackWriter = Future<void> Function(ProfilesState value);

Future<Map<String, dynamic>?> readNativeRuntimeRollback({
  MethodChannel channel = _engineChannel,
}) => channel
    .invokeMapMethod<String, dynamic>('readRuntimeRollback')
    .timeout(_journalTimeout);

/// Applies one native-confirmed rollback before ProviderScope is created.
/// Acknowledgement is conditional on the journal id, so a stale bootstrap
/// callback cannot delete a newer replacement's recovery snapshot.
Future<void> restoreNativeRuntimeRollback(
  SensitiveSettingsRepository settings, {
  MethodChannel channel = _engineChannel,
  ProfilesRollbackWriter? profilesWriter,
  Duration pendingTimeout = _pendingJournalTimeout,
  Duration pendingPollInterval = _pendingJournalPollInterval,
  Map<String, dynamic>? initialJournal,
  bool initialJournalWasRead = false,
}) async {
  final pendingDeadline = DateTime.now().add(pendingTimeout);
  var raw = initialJournal;
  var useInitialJournal = initialJournalWasRead;
  while (true) {
    if (!useInitialJournal) {
      raw = await readNativeRuntimeRollback(channel: channel);
    }
    useInitialJournal = false;
    if (raw == null) return;

    final rolledBack = raw['rolledBack'];
    if (rolledBack is! bool) {
      throw const FormatException('Invalid native VPN rollback state.');
    }
    if (rolledBack) break;
    if (!DateTime.now().isBefore(pendingDeadline)) {
      throw TimeoutException(
        'Native VPN replacement did not reach a durable outcome.',
        pendingTimeout,
      );
    }
    final remaining = pendingDeadline.difference(DateTime.now());
    await Future<void>.delayed(
      remaining < pendingPollInterval ? remaining : pendingPollInterval,
    );
  }

  final id = raw['id'];
  final kind = raw['kind'];
  final payload = raw['payload'];
  if (id is! String ||
      id.isEmpty ||
      id.length > 128 ||
      kind is! String ||
      payload is! String ||
      payload.isEmpty ||
      payload.length > _maxJournalCharacters) {
    throw const FormatException('Invalid native VPN rollback journal.');
  }

  switch (kind) {
    case 'tun':
      final previous = TunSettings.decode(payload);
      if (previous.validationKey() != null) {
        throw const FormatException('Invalid rolled-back TUN settings.');
      }
      await settings.saveTun(previous);
    case 'split':
      await settings.saveSplit(SplitTunnelSettings.decode(payload));
    case 'profiles':
      final previous = await Isolate.run(
        () => ProfilesState.fromJson(
          (jsonDecode(payload) as Map).cast<String, dynamic>(),
        ),
      );
      await (profilesWriter ?? const ProfileStore().save)(previous);
    case 'routingProfiles':
      await settings.saveRoutingProfiles(RoutingProfilesState.decode(payload));
    default:
      throw const FormatException('Unsupported native VPN rollback kind.');
  }

  final acknowledged = await channel
      .invokeMethod<bool>('ackRuntimeRollback', {'id': id})
      .timeout(_journalTimeout);
  if (acknowledged != true) {
    throw StateError('Native VPN rollback acknowledgement was rejected.');
  }
}
