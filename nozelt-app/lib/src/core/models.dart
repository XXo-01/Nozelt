import 'package:json_annotation/json_annotation.dart';

part 'models.g.dart';

/// Inbound ports actually open on the Go side after the engine starts.
/// A field with value `0` means that listener type is disabled in the
/// active config (or, before iteration 2, that the engine cannot report it).
@JsonSerializable()
class Listeners {
  const Listeners({
    this.mixedPort = 0,
    this.httpPort = 0,
    this.socksPort = 0,
    this.redirPort = 0,
    this.tproxyPort = 0,
  });

  final int mixedPort;
  final int httpPort;
  final int socksPort;
  final int redirPort;
  final int tproxyPort;

  factory Listeners.fromJson(Map<String, dynamic> json) =>
      _$ListenersFromJson(json);

  Map<String, dynamic> toJson() => _$ListenersToJson(this);

  static const Listeners none = Listeners();
}

/// TUN interface state reported by the Go engine (`core.TunStatus`). Added in
/// iteration 3. `enabled` is true only when mihomo's sing-tun listener is
/// actually up on the fd handed over by the VpnService.
@JsonSerializable()
class TunStatus {
  const TunStatus({this.enabled = false, this.stack = '', this.fd = 0});

  final bool enabled;

  /// `"gvisor" | "system" | "mixed" | ""` (lowercase; empty when down).
  final String stack;

  /// Android descriptor mihomo adopted, `0` when the TUN is not up.
  final int fd;

  factory TunStatus.fromJson(Map<String, dynamic> json) =>
      _$TunStatusFromJson(json);

  Map<String, dynamic> toJson() => _$TunStatusToJson(this);

  static const TunStatus down = TunStatus();
}

/// Mirrors the Go `core.Status` struct. The JSON arrives over MethodChannel
/// as a string; iteration 2 added `mode`, `listeners` and `connectionsCount`
/// with safe defaults so older `.aar` artifacts that don't emit those keys
/// still deserialise.
@JsonSerializable()
class Status {
  const Status({
    required this.running,
    required this.startedAtUnix,
    required this.uptimeSeconds,
    required this.mihomoVersion,
    required this.nozeltCoreVersion,
    this.mode = '',
    this.listeners = Listeners.none,
    this.connectionsCount = 0,
    this.tun = TunStatus.down,
    this.openFileDescriptors = -1,
    this.goRoutines = 0,
    this.socketProtection = false,
    this.protectedSockets = 0,
    this.protectionFailures = 0,
    this.networkGuard = false,
    this.recovering = false,
  });

  final bool running;
  final int startedAtUnix;
  final int uptimeSeconds;
  final String mihomoVersion;
  final String nozeltCoreVersion;

  /// `"rule" | "global" | "direct" | ""` — empty when the engine is not
  /// running or the Go side didn't report it.
  final String mode;

  /// Real inbound ports as reported by mihomo's `listener.GetPorts()`. All
  /// zero when the engine is not running.
  final Listeners listeners;

  /// Active tracked connections inside mihomo's statistic manager.
  final int connectionsCount;

  /// TUN interface state (iteration 3). Defaults to down for older `.aar`
  /// artifacts that don't emit the `tun` key.
  final TunStatus tun;

  /// Resource diagnostics used to detect regressions before Android's fd or
  /// memory limits take down both the VPN service and Flutter UI.
  final int openFileDescriptors;
  final int goRoutines;

  /// Whether mihomo's process-wide socket hook currently delegates every
  /// outbound transport socket to Android's VpnService.protect(fd).
  final bool socketProtection;

  /// Aggregate per-process counters. No destination, address, profile, or
  /// socket descriptor is retained, so diagnostics cannot expose secrets.
  final int protectedSockets;
  final int protectionFailures;
  final bool networkGuard;
  final bool recovering;

  factory Status.fromJson(Map<String, dynamic> json) => _$StatusFromJson(json);

  Map<String, dynamic> toJson() => _$StatusToJson(this);

  static const Status idle = Status(
    running: false,
    startedAtUnix: 0,
    uptimeSeconds: 0,
    mihomoVersion: '',
    nozeltCoreVersion: '',
  );
}

/// Common traffic frame. Mihomo fills it from its statistic manager; Android
/// fills native Xray/sing-box frames from UID network accounting.
@JsonSerializable()
class Traffic {
  const Traffic({
    required this.uploadBytes,
    required this.downloadBytes,
    required this.uploadSpeedBps,
    required this.downloadSpeedBps,
    required this.activeConnections,
    this.synthetic = false,
  });

  final int uploadBytes;
  final int downloadBytes;
  final int uploadSpeedBps;
  final int downloadSpeedBps;
  final int activeConnections;

  /// Legacy iteration-1 marker. After iteration 2 the Go side always sets
  /// this to `false` because the statistic manager is wired up. The flag is
  /// retained so old `.aar` artifacts that don't report it can be detected
  /// by absence (treated as `false`) and so a future fallback path can
  /// resurface it without ABI changes.
  final bool synthetic;

  factory Traffic.fromJson(Map<String, dynamic> json) =>
      _$TrafficFromJson(json);

  Map<String, dynamic> toJson() => _$TrafficToJson(this);

  static const Traffic zero = Traffic(
    uploadBytes: 0,
    downloadBytes: 0,
    uploadSpeedBps: 0,
    downloadSpeedBps: 0,
    activeConnections: 0,
  );
}

/// One log line emitted by the Go layer.
@JsonSerializable()
class LogEntry {
  const LogEntry({
    required this.level,
    required this.message,
    required this.timestampMs,
  });

  /// One of `debug | info | warning | error`.
  final String level;
  final String message;
  final int timestampMs;

  factory LogEntry.fromJson(Map<String, dynamic> json) =>
      _$LogEntryFromJson(json);

  Map<String, dynamic> toJson() => _$LogEntryToJson(this);
}

/// One live connection exposed by the desktop core. These snapshots are
/// intentionally volatile and are never persisted by the Flutter layer.
class DesktopConnection {
  const DesktopConnection({
    required this.id,
    required this.network,
    required this.inboundType,
    required this.source,
    required this.destination,
    required this.host,
    required this.process,
    required this.upload,
    required this.download,
    required this.startedAt,
    required this.chains,
    required this.rule,
    required this.rulePayload,
  });

  final String id;
  final String network;
  final String inboundType;
  final String source;
  final String destination;
  final String host;
  final String process;
  final int upload;
  final int download;
  final int startedAt;
  final List<String> chains;
  final String rule;
  final String rulePayload;

  factory DesktopConnection.fromJson(Map<String, dynamic> json) =>
      DesktopConnection(
        id: json['id']?.toString() ?? '',
        network: json['network']?.toString() ?? '',
        inboundType: json['inboundType']?.toString() ?? '',
        source: json['source']?.toString() ?? '',
        destination: json['destination']?.toString() ?? '',
        host: json['host']?.toString() ?? '',
        process: json['process']?.toString() ?? '',
        upload: (json['upload'] as num?)?.toInt() ?? 0,
        download: (json['download'] as num?)?.toInt() ?? 0,
        startedAt: (json['startedAt'] as num?)?.toInt() ?? 0,
        chains: ((json['chains'] as List?) ?? const [])
            .map((value) => value.toString())
            .toList(growable: false),
        rule: json['rule']?.toString() ?? '',
        rulePayload: json['rulePayload']?.toString() ?? '',
      );
}

/// Connection state surfaced to the UI. We don't reuse `Status.running`
/// directly because the UI needs intermediate states (connecting,
/// disconnecting, error) that are not visible from the Go side alone.
enum EngineConnectionState {
  disconnected,
  connecting,
  connected,
  disconnecting,
  error,
}

/// The composite UI-facing state held by the engine notifier.
class EngineState {
  const EngineState({
    this.connection = EngineConnectionState.disconnected,
    this.status = Status.idle,
    this.errorMessage,
  });

  final EngineConnectionState connection;
  final Status status;
  final String? errorMessage;

  EngineState copyWith({
    EngineConnectionState? connection,
    Status? status,
    String? errorMessage,
    bool clearError = false,
  }) {
    return EngineState(
      connection: connection ?? this.connection,
      status: status ?? this.status,
      errorMessage: clearError ? null : (errorMessage ?? this.errorMessage),
    );
  }
}

/// Versions reported by `Binding.getVersion()`. Matches the JSON shape
/// `{"nozeltCore":"...","mihomo":"...","xray":"...","singBox":"..."}`.
@JsonSerializable()
class EngineVersions {
  const EngineVersions({
    required this.nozeltCore,
    required this.mihomo,
    required this.xray,
    required this.singBox,
  });

  final String nozeltCore;
  final String mihomo;
  final String xray;
  final String singBox;

  factory EngineVersions.fromJson(Map<String, dynamic> json) =>
      _$EngineVersionsFromJson(json);

  Map<String, dynamic> toJson() => _$EngineVersionsToJson(this);
}
