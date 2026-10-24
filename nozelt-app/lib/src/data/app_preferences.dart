import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';

import '../core/windows_native_bridge.dart';
import 'windows_data_directory.dart';

/// Small Nozelt-owned preferences store. It avoids desktop Flutter plugins,
/// keeps the portable build self-contained, and DPAPI-protects the complete
/// Windows snapshot because legacy routing settings can be privacy-sensitive.
class SharedPreferences {
  SharedPreferences._(this._values, {this.file, this.android = false});

  static const _channel = MethodChannel('dev.nozelt.nozelt/engine');
  static Map<String, Object>? _mockValues;

  final Map<String, Object> _values;
  final File? file;
  final bool android;
  Future<void> _writeTail = Future<void>.value();

  static void setMockInitialValues(Map<String, Object> values) {
    _mockValues = Map<String, Object>.from(values);
  }

  static Future<SharedPreferences> getInstance() async {
    final mock = _mockValues;
    if (mock != null) return SharedPreferences._(Map.from(mock));

    if (Platform.isAndroid) {
      final value = await _channel.invokeMapMethod<String, dynamic>(
        'readAppPreferences',
      );
      return SharedPreferences._(
        (value ?? const <String, dynamic>{}).map(
          (key, item) => MapEntry(key, item as Object),
        ),
        android: true,
      );
    }

    final directory = await _dataDirectory();
    final protected = Platform.isWindows;
    final file = File(
      '${directory.path}${Platform.pathSeparator}'
      '${protected ? 'preferences.dpapi' : 'preferences.json'}',
    );
    if (!await file.exists()) {
      return SharedPreferences._(<String, Object>{}, file: file);
    }
    try {
      var encoded = await file.readAsString();
      if (protected && encoded.trim().isNotEmpty) {
        encoded = WindowsNativeBridge.open().unprotectData(encoded);
      }
      final decoded = jsonDecode(encoded);
      final values = decoded is Map
          ? decoded.map(
              (key, value) => MapEntry(key.toString(), value as Object),
            )
          : <String, Object>{};
      return SharedPreferences._(values, file: file);
    } catch (_) {
      throw const FileSystemException('Preferences could not be read.');
    }
  }

  String? getString(String key) => _values[key] as String?;

  Future<bool> setString(String key, String value) {
    _values[key] = value;
    return _persist();
  }

  Future<bool> remove(String key) {
    _values.remove(key);
    return _persist();
  }

  Future<bool> removeAll(Iterable<String> keys) {
    var changed = false;
    for (final key in keys) {
      changed = _values.remove(key) != null || changed;
    }
    return changed ? _persist() : Future<bool>.value(true);
  }

  Future<bool> _persist() {
    final snapshot = Map<String, Object>.from(_values);
    final operation = _writeTail.then((_) async {
      if (android) {
        final result = await _channel.invokeMethod<bool>(
          'writeAppPreferences',
          {'value': jsonEncode(snapshot)},
        );
        return result == true;
      }
      final target = file;
      if (target == null) {
        _mockValues = snapshot;
        return true;
      }
      var encoded = jsonEncode(snapshot);
      if (Platform.isWindows) {
        encoded = WindowsNativeBridge.open().protectData(encoded);
      }
      final temporary = File('${target.path}.tmp');
      await temporary.writeAsString(encoded, flush: true);
      await temporary.rename(target.path);
      return true;
    });
    _writeTail = operation.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    return operation;
  }

  static Future<Directory> _dataDirectory() async {
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
}
