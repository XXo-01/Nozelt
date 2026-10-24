// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'models.dart';

// **************************************************************************
// JsonSerializableGenerator
// **************************************************************************

Listeners _$ListenersFromJson(Map<String, dynamic> json) => Listeners(
  mixedPort: (json['mixedPort'] as num?)?.toInt() ?? 0,
  httpPort: (json['httpPort'] as num?)?.toInt() ?? 0,
  socksPort: (json['socksPort'] as num?)?.toInt() ?? 0,
  redirPort: (json['redirPort'] as num?)?.toInt() ?? 0,
  tproxyPort: (json['tproxyPort'] as num?)?.toInt() ?? 0,
);

Map<String, dynamic> _$ListenersToJson(Listeners instance) => <String, dynamic>{
  'mixedPort': instance.mixedPort,
  'httpPort': instance.httpPort,
  'socksPort': instance.socksPort,
  'redirPort': instance.redirPort,
  'tproxyPort': instance.tproxyPort,
};

TunStatus _$TunStatusFromJson(Map<String, dynamic> json) => TunStatus(
  enabled: json['enabled'] as bool? ?? false,
  stack: json['stack'] as String? ?? '',
  fd: (json['fd'] as num?)?.toInt() ?? 0,
);

Map<String, dynamic> _$TunStatusToJson(TunStatus instance) => <String, dynamic>{
  'enabled': instance.enabled,
  'stack': instance.stack,
  'fd': instance.fd,
};

Status _$StatusFromJson(Map<String, dynamic> json) => Status(
  running: json['running'] as bool,
  startedAtUnix: (json['startedAtUnix'] as num).toInt(),
  uptimeSeconds: (json['uptimeSeconds'] as num).toInt(),
  mihomoVersion: json['mihomoVersion'] as String,
  nozeltCoreVersion: json['nozeltCoreVersion'] as String,
  mode: json['mode'] as String? ?? '',
  listeners: json['listeners'] == null
      ? Listeners.none
      : Listeners.fromJson(json['listeners'] as Map<String, dynamic>),
  connectionsCount: (json['connectionsCount'] as num?)?.toInt() ?? 0,
  tun: json['tun'] == null
      ? TunStatus.down
      : TunStatus.fromJson(json['tun'] as Map<String, dynamic>),
  openFileDescriptors: (json['openFileDescriptors'] as num?)?.toInt() ?? -1,
  goRoutines: (json['goRoutines'] as num?)?.toInt() ?? 0,
  socketProtection: json['socketProtection'] as bool? ?? false,
  protectedSockets: (json['protectedSockets'] as num?)?.toInt() ?? 0,
  protectionFailures: (json['protectionFailures'] as num?)?.toInt() ?? 0,
  networkGuard: json['networkGuard'] as bool? ?? false,
  recovering: json['recovering'] as bool? ?? false,
);

Map<String, dynamic> _$StatusToJson(Status instance) => <String, dynamic>{
  'running': instance.running,
  'startedAtUnix': instance.startedAtUnix,
  'uptimeSeconds': instance.uptimeSeconds,
  'mihomoVersion': instance.mihomoVersion,
  'nozeltCoreVersion': instance.nozeltCoreVersion,
  'mode': instance.mode,
  'listeners': instance.listeners,
  'connectionsCount': instance.connectionsCount,
  'tun': instance.tun,
  'openFileDescriptors': instance.openFileDescriptors,
  'goRoutines': instance.goRoutines,
  'socketProtection': instance.socketProtection,
  'protectedSockets': instance.protectedSockets,
  'protectionFailures': instance.protectionFailures,
  'networkGuard': instance.networkGuard,
  'recovering': instance.recovering,
};

Traffic _$TrafficFromJson(Map<String, dynamic> json) => Traffic(
  uploadBytes: (json['uploadBytes'] as num).toInt(),
  downloadBytes: (json['downloadBytes'] as num).toInt(),
  uploadSpeedBps: (json['uploadSpeedBps'] as num).toInt(),
  downloadSpeedBps: (json['downloadSpeedBps'] as num).toInt(),
  activeConnections: (json['activeConnections'] as num).toInt(),
  synthetic: json['synthetic'] as bool? ?? false,
);

Map<String, dynamic> _$TrafficToJson(Traffic instance) => <String, dynamic>{
  'uploadBytes': instance.uploadBytes,
  'downloadBytes': instance.downloadBytes,
  'uploadSpeedBps': instance.uploadSpeedBps,
  'downloadSpeedBps': instance.downloadSpeedBps,
  'activeConnections': instance.activeConnections,
  'synthetic': instance.synthetic,
};

LogEntry _$LogEntryFromJson(Map<String, dynamic> json) => LogEntry(
  level: json['level'] as String,
  message: json['message'] as String,
  timestampMs: (json['timestampMs'] as num).toInt(),
);

Map<String, dynamic> _$LogEntryToJson(LogEntry instance) => <String, dynamic>{
  'level': instance.level,
  'message': instance.message,
  'timestampMs': instance.timestampMs,
};

EngineVersions _$EngineVersionsFromJson(Map<String, dynamic> json) =>
    EngineVersions(
      nozeltCore: json['nozeltCore'] as String,
      mihomo: json['mihomo'] as String,
      xray: json['xray'] as String,
      singBox: json['singBox'] as String,
    );

Map<String, dynamic> _$EngineVersionsToJson(EngineVersions instance) =>
    <String, dynamic>{
      'nozeltCore': instance.nozeltCore,
      'mihomo': instance.mihomo,
      'xray': instance.xray,
      'singBox': instance.singBox,
    };
