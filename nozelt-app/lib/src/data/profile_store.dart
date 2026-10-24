import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:flutter/services.dart';

import '../core/profile.dart';
import '../core/windows_native_bridge.dart';
import 'windows_data_directory.dart';

/// Persists credential-bearing profiles. Android uses AES-256-GCM backed by a
/// non-exportable Android Keystore key. Other platforms keep the existing
/// atomic app-private file until their native secure store is implemented.
class ProfileStore {
  const ProfileStore();

  static const String _fileName = 'profiles.json';
  static const String _windowsFileName = 'profiles.dpapi';
  // Even medium subscriptions can take multiple 16 ms frames to parse on
  // lower-end phones. Move them off the UI isolate before they become visible.
  static const int _backgroundDecodeThreshold = 48 * 1024;
  static const Duration _secureStoreTimeout = Duration(seconds: 8);
  static const MethodChannel _channel = MethodChannel(
    'dev.nozelt.nozelt/engine',
  );

  Future<Directory> _dataDirectory() async {
    if (Platform.isWindows) return windowsDataDirectory();
    final separator = Platform.pathSeparator;
    final environment = Platform.environment;
    late final String base;
    if (Platform.isWindows) {
      base =
          environment['APPDATA'] ??
          environment['LOCALAPPDATA'] ??
          environment['USERPROFILE'] ??
          Directory.current.path;
    } else if (Platform.isMacOS) {
      base = <String>[
        environment['HOME'] ?? Directory.current.path,
        'Library',
        'Application Support',
      ].join(separator);
    } else {
      base =
          environment['XDG_DATA_HOME'] ??
          <String>[
            environment['HOME'] ?? Directory.current.path,
            '.local',
            'share',
          ].join(separator);
    }
    final directory = Directory(<String>[base, 'Nozelt'].join(separator));
    await directory.create(recursive: true);
    return directory;
  }

  Future<File> _legacyFile() async {
    final dir = await _dataDirectory();
    return File('${dir.path}${Platform.pathSeparator}$_fileName');
  }

  Future<File> _windowsFile() async {
    final dir = await _dataDirectory();
    return File('${dir.path}${Platform.pathSeparator}$_windowsFileName');
  }

  Future<ProfilesState> load() async {
    if (Platform.isAndroid) {
      try {
        final encryptedJson = await _channel
            .invokeMethod<String>('readSecureProfiles')
            .timeout(_secureStoreTimeout);
        if (encryptedJson != null && encryptedJson.trim().isNotEmpty) {
          return await _decode(encryptedJson);
        }

        // One-time migration stays on the native side so Windows builds do
        // not need path_provider and therefore require no plugin symlinks.
        final legacy = await _channel
            .invokeMethod<String>('readLegacyProfiles')
            .timeout(_secureStoreTimeout);
        if (legacy != null && legacy.trim().isNotEmpty) {
          final state = await _decode(legacy);
          await save(state);
          await _channel
              .invokeMethod<bool>('deleteLegacyProfiles')
              .timeout(_secureStoreTimeout);
          return state;
        }
        return const ProfilesState();
      } on PlatformException {
        // Do not fall back to plaintext when Keystore fails: that would turn a
        // transient security error into persistent credential exposure. Also
        // do not return an empty state: a later write could erase valid data.
        throw const ProfileStoreException(
          'Secure profile storage is temporarily unavailable.',
        );
      } catch (_) {
        throw const ProfileStoreException(
          'Encrypted profile data could not be read.',
        );
      }
    }

    if (Platform.isWindows) {
      try {
        final secure = await _windowsFile();
        if (await secure.exists()) {
          final encrypted = await secure.readAsString();
          if (encrypted.trim().isEmpty) return const ProfilesState();
          final plaintext = WindowsNativeBridge.open().unprotectData(encrypted);
          return await _decode(plaintext);
        }

        // One-time migration from the early Windows preview, which reused the
        // non-Android plaintext fallback. Delete it only after DPAPI succeeds.
        final legacy = await _legacyFile();
        if (await legacy.exists()) {
          final text = await legacy.readAsString();
          if (text.trim().isNotEmpty) {
            final state = await _decode(text);
            await save(state);
            await legacy.delete();
            return state;
          }
          await legacy.delete();
        }
        return const ProfilesState();
      } catch (_) {
        throw const ProfileStoreException(
          'Encrypted Windows profile data could not be read.',
        );
      }
    }

    final file = await _legacyFile();
    if (!await file.exists()) return const ProfilesState();
    final text = await file.readAsString();
    return text.trim().isEmpty ? const ProfilesState() : await _decode(text);
  }

  Future<void> save(ProfilesState state) async {
    // Encoding profiles duplicates every nested proxy map. Do that work away
    // from the UI isolate so a large subscription refresh cannot cause a
    // visible frame stall before the encrypted native write begins.
    final encoded = await Isolate.run(() => jsonEncode(state.toJson()));
    if (Platform.isAndroid) {
      final written = await _channel
          .invokeMethod<bool>('writeSecureProfiles', {'value': encoded})
          .timeout(_secureStoreTimeout);
      if (written != true) {
        throw const FileSystemException('Secure write failed');
      }
      return;
    }

    if (Platform.isWindows) {
      try {
        final encrypted = WindowsNativeBridge.open().protectData(encoded);
        final file = await _windowsFile();
        final tmp = File('${file.path}.tmp');
        await tmp.writeAsString(encrypted, flush: true);
        await tmp.rename(file.path);
        return;
      } catch (_) {
        throw const ProfileStoreException(
          'Encrypted Windows profile data could not be written.',
        );
      }
    }

    final file = await _legacyFile();
    final tmp = File('${file.path}.tmp');
    await tmp.writeAsString(encoded, flush: true);
    await tmp.rename(file.path);
  }

  Future<ProfilesState> _decode(String value) {
    if (value.length < _backgroundDecodeThreshold) {
      return Future.value(_decodeProfiles(value));
    }
    return Isolate.run(() => _decodeProfiles(value));
  }
}

ProfilesState _decodeProfiles(String value) =>
    ProfilesState.fromJson(jsonDecode(value) as Map<String, dynamic>);

class ProfileStoreException implements Exception {
  const ProfileStoreException(this.message);

  final String message;

  @override
  String toString() => message;
}
