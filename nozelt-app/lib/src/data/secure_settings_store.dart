import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../core/split_tunnel_settings.dart';
import '../core/tun_settings.dart';
import 'app_preferences.dart';
import 'sensitive_settings_repository.dart';

const _channel = MethodChannel('dev.nozelt.nozelt/engine');
const _secureStoreTimeout = Duration(seconds: 5);

/// Loads the encrypted Android settings before the first frame and migrates
/// the former plaintext SharedPreferences values exactly once.
Future<SensitiveSettingsRepository> loadSensitiveSettingsRepository(
  Future<SharedPreferences> preferencesFuture,
) async {
  if (defaultTargetPlatform != TargetPlatform.android) {
    return SensitiveSettingsRepository.legacy(await preferencesFuture);
  }

  final encodedFuture = _channel
      .invokeMethod<String>('readSecureSettings')
      .timeout(_secureStoreTimeout);

  Future<void> secureWrite(String encoded) async {
    try {
      final saved = await _channel
          .invokeMethod<bool>('writeSecureSettings', {'value': encoded})
          .timeout(_secureStoreTimeout);
      if (saved != true) throw const SensitiveSettingsStoreException();
    } catch (_) {
      // PlatformException/TimeoutException text can expose implementation
      // details. Controllers and UI receive one stable, localizable category.
      throw const SensitiveSettingsStoreException();
    }
  }

  try {
    final startupValues = await Future.wait<Object?>([
      preferencesFuture,
      encodedFuture,
    ]);
    final preferences = startupValues[0] as SharedPreferences;
    final encoded = startupValues[1] as String?;
    final initial = encoded == null
        ? SensitiveSettingsSnapshot.fromLegacy(preferences)
        : SensitiveSettingsSnapshot.decode(encoded);
    final repository = SensitiveSettingsRepository(
      initial: initial,
      writer: secureWrite,
    );
    if (encoded == null) await repository.persistCurrent();
    final legacyKeys = [
      legacyTunSettingsKey,
      legacySplitTunnelKey,
      legacyRoutingProfilesKey,
    ].where((key) => preferences.getString(key) != null);
    if (legacyKeys.isNotEmpty) {
      // One snapshot write is enough for the one-time migration. Normal
      // startups with no legacy keys perform no preferences write at all.
      await preferences.removeAll(legacyKeys);
    }
    return repository;
  } catch (_) {
    // On Android never downgrade sensitive data back to plaintext and never
    // overwrite a possibly valid encrypted snapshot with defaults after a
    // transient Keystore/read failure. The safe default view is deliberately
    // read-only for this process; a clean app restart can retry decryption.
    return SensitiveSettingsRepository(
      initial: const SensitiveSettingsSnapshot(
        tun: TunSettings(),
        split: SplitTunnelSettings(),
      ),
      writer: (_) =>
          Future<void>.error(const SensitiveSettingsStoreException()),
    );
  }
}
