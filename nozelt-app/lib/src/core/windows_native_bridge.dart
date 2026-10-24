import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';

typedef _NoArgsNative = Pointer<Utf8> Function();
typedef _NoArgsDart = Pointer<Utf8> Function();
typedef _OneStringNative = Pointer<Utf8> Function(Pointer<Utf8>);
typedef _OneStringDart = Pointer<Utf8> Function(Pointer<Utf8>);
typedef _TwoStringsNative =
    Pointer<Utf8> Function(Pointer<Utf8>, Pointer<Utf8>);
typedef _TwoStringsDart = Pointer<Utf8> Function(Pointer<Utf8>, Pointer<Utf8>);
typedef _DelayNative =
    Pointer<Utf8> Function(
      Pointer<Utf8>,
      Pointer<Utf8>,
      Pointer<Utf8>,
      Int32,
      Int32,
    );
typedef _DelayDart =
    Pointer<Utf8> Function(
      Pointer<Utf8>,
      Pointer<Utf8>,
      Pointer<Utf8>,
      int,
      int,
    );
typedef _NativeDelayNative =
    Pointer<Utf8> Function(Pointer<Utf8>, Pointer<Utf8>, Int32);
typedef _NativeDelayDart =
    Pointer<Utf8> Function(Pointer<Utf8>, Pointer<Utf8>, int);
typedef _BeginDelayNative =
    Pointer<Utf8> Function(
      Pointer<Utf8>,
      Pointer<Utf8>,
      Pointer<Utf8>,
      Pointer<Utf8>,
      Pointer<Utf8>,
      Int32,
      Int32,
    );
typedef _BeginDelayDart =
    Pointer<Utf8> Function(
      Pointer<Utf8>,
      Pointer<Utf8>,
      Pointer<Utf8>,
      Pointer<Utf8>,
      Pointer<Utf8>,
      int,
      int,
    );
typedef _FreeNative = Void Function(Pointer<Void>);
typedef _FreeDart = void Function(Pointer<Void>);
typedef _VoidNative = Void Function();
typedef _VoidDart = void Function();
typedef _CloseConnectionNative = Int32 Function(Pointer<Utf8>);
typedef _CloseConnectionDart = int Function(Pointer<Utf8>);
typedef _IntNative = Int32 Function();
typedef _IntDart = int Function();

/// Thin dart:ffi wrapper around the portable Go C ABI. Every returned string
/// is owned by the DLL and released immediately after it is copied into Dart.
class WindowsNativeBridge {
  WindowsNativeBridge._(DynamicLibrary library)
    : _free = library.lookupFunction<_FreeNative, _FreeDart>('NozeltFree'),
      _start = library.lookupFunction<_OneStringNative, _OneStringDart>(
        'NozeltStart',
      ),
      _startCore = library.lookupFunction<_TwoStringsNative, _TwoStringsDart>(
        'NozeltStartCore',
      ),
      _validateCoreConfig = library
          .lookupFunction<_TwoStringsNative, _TwoStringsDart>(
            'NozeltValidateCoreConfig',
          ),
      _stop = library.lookupFunction<_NoArgsNative, _NoArgsDart>('NozeltStop'),
      _stopForRestart = library.lookupFunction<_NoArgsNative, _NoArgsDart>(
        'NozeltStopForRestart',
      ),
      _updateGeoData = library.lookupFunction<_NoArgsNative, _NoArgsDart>(
        'NozeltUpdateGeoData',
      ),
      _reload = library.lookupFunction<_OneStringNative, _OneStringDart>(
        'NozeltReload',
      ),
      _selectProxy = library.lookupFunction<_TwoStringsNative, _TwoStringsDart>(
        'NozeltSelectProxy',
      ),
      _getStatus = library.lookupFunction<_NoArgsNative, _NoArgsDart>(
        'NozeltGetStatus',
      ),
      _getTraffic = library.lookupFunction<_NoArgsNative, _NoArgsDart>(
        'NozeltGetTraffic',
      ),
      _getVersion = library.lookupFunction<_NoArgsNative, _NoArgsDart>(
        'NozeltGetVersion',
      ),
      _parseProxyLink = library
          .lookupFunction<_OneStringNative, _OneStringDart>(
            'NozeltParseProxyLink',
          ),
      _parseSubscription = library
          .lookupFunction<_OneStringNative, _OneStringDart>(
            'NozeltParseSubscription',
          ),
      _testProxyDelays = library.lookupFunction<_DelayNative, _DelayDart>(
        'NozeltTestProxyDelays',
      ),
      _testNativeProxyDelays = library
          .lookupFunction<_NativeDelayNative, _NativeDelayDart>(
            'NozeltTestNativeProxyDelays',
          ),
      _beginProxyDelays = library
          .lookupFunction<_BeginDelayNative, _BeginDelayDart>(
            'NozeltBeginProxyDelays',
          ),
      _pollProxyDelays = library
          .lookupFunction<_OneStringNative, _OneStringDart>(
            'NozeltPollProxyDelays',
          ),
      _cancelDelayTests = library.lookupFunction<_VoidNative, _VoidDart>(
        'NozeltCancelDelayTests',
      ),
      _getConnections = library.lookupFunction<_NoArgsNative, _NoArgsDart>(
        'NozeltGetConnections',
      ),
      _closeConnection = library
          .lookupFunction<_CloseConnectionNative, _CloseConnectionDart>(
            'NozeltCloseConnection',
          ),
      _closeAllConnections = library.lookupFunction<_IntNative, _IntDart>(
        'NozeltCloseAllConnections',
      ),
      _getLogs = library.lookupFunction<_NoArgsNative, _NoArgsDart>(
        'NozeltGetLogs',
      ),
      _clearLogs = library.lookupFunction<_VoidNative, _VoidDart>(
        'NozeltClearLogs',
      ),
      _protectData = library.lookupFunction<_OneStringNative, _OneStringDart>(
        'NozeltProtectData',
      ),
      _unprotectData = library.lookupFunction<_OneStringNative, _OneStringDart>(
        'NozeltUnprotectData',
      ),
      _pickConfigFile = library.lookupFunction<_NoArgsNative, _NoArgsDart>(
        'NozeltPickConfigFile',
      ),
      _getSubscriptionHwid = library.lookupFunction<_NoArgsNative, _NoArgsDart>(
        'NozeltGetSubscriptionHwid',
      );

  final _FreeDart _free;
  final _OneStringDart _start;
  final _TwoStringsDart _startCore;
  final _NoArgsDart _stop;
  final _NoArgsDart _stopForRestart;
  final _OneStringDart _reload;
  final _TwoStringsDart _selectProxy;
  final _NoArgsDart _getStatus;
  final _NoArgsDart _getTraffic;
  final _NoArgsDart _getVersion;
  final _OneStringDart _parseProxyLink;
  final _OneStringDart _parseSubscription;
  final _DelayDart _testProxyDelays;
  final _NativeDelayDart _testNativeProxyDelays;
  final _BeginDelayDart _beginProxyDelays;
  final _OneStringDart _pollProxyDelays;
  final _TwoStringsDart _validateCoreConfig;
  final _NoArgsDart _updateGeoData;
  final _VoidDart _cancelDelayTests;
  final _NoArgsDart _getConnections;
  final _CloseConnectionDart _closeConnection;
  final _IntDart _closeAllConnections;
  final _NoArgsDart _getLogs;
  final _VoidDart _clearLogs;
  final _OneStringDart _protectData;
  final _OneStringDart _unprotectData;
  final _NoArgsDart _pickConfigFile;
  final _NoArgsDart _getSubscriptionHwid;

  static WindowsNativeBridge open() {
    final executableDirectory = File(Platform.resolvedExecutable).parent.path;
    final candidates = <String>[
      '$executableDirectory${Platform.pathSeparator}nozelt_core.dll',
      '${Directory.current.path}${Platform.pathSeparator}nozelt_core.dll',
      '${Directory.current.path}${Platform.pathSeparator}..${Platform.pathSeparator}'
          'nozelt-core${Platform.pathSeparator}build${Platform.pathSeparator}'
          'windows${Platform.pathSeparator}nozelt_core.dll',
    ];
    for (final path in candidates) {
      if (File(path).existsSync()) {
        return WindowsNativeBridge._(DynamicLibrary.open(path));
      }
    }
    throw StateError('nozelt_core.dll is missing from the portable bundle.');
  }

  String start(String config) => _withString(config, _start);
  String startCore(String core, String config) =>
      _withTwoStrings(core, config, _startCore);
  String validateCoreConfig(String core, String config) =>
      _withTwoStrings(core, config, _validateCoreConfig);
  String stop() => _copyResult(_stop());
  String stopForRestart() => _copyResult(_stopForRestart());
  String updateGeoData() => _copyResult(_updateGeoData());
  String reload(String config) => _withString(config, _reload);
  String selectProxy(String group, String proxy) =>
      _withTwoStrings(group, proxy, _selectProxy);
  String getStatus() => _copyResult(_getStatus());
  String getTraffic() => _copyResult(_getTraffic());
  String getVersion() => _copyResult(_getVersion());
  String parseProxyLink(String value) => _withString(value, _parseProxyLink);
  String parseSubscription(String value) =>
      _withString(value, _parseSubscription);
  String getConnections() => _copyResult(_getConnections());
  String getLogs() => _copyResult(_getLogs());
  String protectData(String value) =>
      _secureDataResult(_withString(value, _protectData));
  String unprotectData(String value) =>
      _secureDataResult(_withString(value, _unprotectData));
  String pickConfigFile() => _secureDataResult(_copyResult(_pickConfigFile()));
  String getSubscriptionHwid() =>
      _secureDataResult(_copyResult(_getSubscriptionHwid()));

  String testProxyDelays({
    required String config,
    required String namesJson,
    required String testUrl,
    required int timeoutMs,
    required bool offline,
  }) {
    final configPointer = config.toNativeUtf8();
    final namesPointer = namesJson.toNativeUtf8();
    final urlPointer = testUrl.toNativeUtf8();
    try {
      return _copyResult(
        _testProxyDelays(
          configPointer,
          namesPointer,
          urlPointer,
          timeoutMs,
          offline ? 1 : 0,
        ),
      );
    } finally {
      calloc
        ..free(configPointer)
        ..free(namesPointer)
        ..free(urlPointer);
    }
  }

  String testNativeProxyDelays({
    required String core,
    required String targetsJson,
    required int timeoutMs,
  }) {
    final corePointer = core.toNativeUtf8();
    final targetsPointer = targetsJson.toNativeUtf8();
    try {
      return _copyResult(
        _testNativeProxyDelays(corePointer, targetsPointer, timeoutMs),
      );
    } finally {
      calloc
        ..free(corePointer)
        ..free(targetsPointer);
    }
  }

  String beginProxyDelays({
    required String core,
    required String config,
    required String namesJson,
    required String targetsJson,
    required String testUrl,
    required int timeoutMs,
    required bool offline,
  }) {
    final corePointer = core.toNativeUtf8();
    final configPointer = config.toNativeUtf8();
    final namesPointer = namesJson.toNativeUtf8();
    final targetsPointer = targetsJson.toNativeUtf8();
    final urlPointer = testUrl.toNativeUtf8();
    try {
      return _copyResult(
        _beginProxyDelays(
          corePointer,
          configPointer,
          namesPointer,
          targetsPointer,
          urlPointer,
          timeoutMs,
          offline ? 1 : 0,
        ),
      );
    } finally {
      calloc
        ..free(corePointer)
        ..free(configPointer)
        ..free(namesPointer)
        ..free(targetsPointer)
        ..free(urlPointer);
    }
  }

  String pollProxyDelays(String jobId) => _withString(jobId, _pollProxyDelays);

  void cancelDelayTests() => _cancelDelayTests();
  void clearLogs() => _clearLogs();
  int closeAllConnections() => _closeAllConnections();

  bool closeConnection(String id) {
    final pointer = id.toNativeUtf8();
    try {
      return _closeConnection(pointer) != 0;
    } finally {
      calloc.free(pointer);
    }
  }

  bool resultOK(String raw) {
    final value = jsonDecode(raw);
    return value is Map && value['ok'] == true;
  }

  String _secureDataResult(String raw) {
    final value = jsonDecode(raw);
    if (value is Map && value['ok'] == true && value['data'] is String) {
      return value['data'] as String;
    }
    throw StateError('Windows secure storage is unavailable.');
  }

  String _withString(String value, _OneStringDart function) {
    final pointer = value.toNativeUtf8();
    try {
      return _copyResult(function(pointer));
    } finally {
      calloc.free(pointer);
    }
  }

  String _withTwoStrings(
    String first,
    String second,
    _TwoStringsDart function,
  ) {
    final firstPointer = first.toNativeUtf8();
    final secondPointer = second.toNativeUtf8();
    try {
      return _copyResult(function(firstPointer, secondPointer));
    } finally {
      calloc
        ..free(firstPointer)
        ..free(secondPointer);
    }
  }

  String _copyResult(Pointer<Utf8> pointer) {
    if (pointer == nullptr) throw StateError('Native core returned null.');
    try {
      return pointer.toDartString();
    } finally {
      _free(pointer.cast<Void>());
    }
  }
}
