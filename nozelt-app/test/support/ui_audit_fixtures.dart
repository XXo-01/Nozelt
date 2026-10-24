import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nozelt/src/core/models.dart';
import 'package:nozelt/src/core/nozelt_engine.dart';
import 'package:nozelt/src/core/profile.dart';
import 'package:nozelt/src/core/proxy_node.dart';
import 'package:nozelt/src/data/profile_store.dart';
import 'package:nozelt/src/state/engine_provider.dart';
import 'package:nozelt/src/state/node_health_provider.dart';

Future<void> loadAuditFonts() async {
  var sdk = File(Platform.resolvedExecutable).parent;
  while (!Directory(
    '${sdk.path}/bin/cache/artifacts/material_fonts',
  ).existsSync()) {
    if (sdk.parent.path == sdk.path) {
      throw StateError('Flutter fonts unavailable');
    }
    sdk = sdk.parent;
  }
  final fonts = '${sdk.path}/bin/cache/artifacts/material_fonts';
  for (final entry in {
    'Roboto': [
      '$fonts/roboto-regular.ttf',
      '$fonts/roboto-medium.ttf',
      '$fonts/roboto-bold.ttf',
    ],
    'Segoe UI': Platform.isWindows
        ? [
            'C:/Windows/Fonts/segoeui.ttf',
            'C:/Windows/Fonts/seguisb.ttf',
            'C:/Windows/Fonts/segoeuib.ttf',
          ]
        : [
            '$fonts/roboto-regular.ttf',
            '$fonts/roboto-medium.ttf',
            '$fonts/roboto-bold.ttf',
          ],
    'monospace': Platform.isWindows
        ? ['C:/Windows/Fonts/consola.ttf']
        : ['$fonts/roboto-regular.ttf'],
    'MaterialIcons': ['$fonts/materialicons-regular.otf'],
  }.entries) {
    final loader = FontLoader(entry.key);
    for (final path in entry.value) {
      loader.addFont(File(path).readAsBytes().then(ByteData.sublistView));
    }
    await loader.load();
  }
  await (FontLoader(
    'Runzoe',
  )..addFont(rootBundle.load('assets/fonts/Runzoe-Regular.otf'))).load();
}

Future<void> loadAuditImages(WidgetTester tester) async {
  final context = tester.element(find.byType(MaterialApp));
  await tester.runAsync(() async {
    for (final path in [
      'assets/branding/nozelt_desktop_logo.png',
      'assets/branding/nozelt_new_logo.png',
      'assets/branding/nozelt_new_master_logo.png',
      'assets/flags/FI.png',
      'assets/flags/SE.png',
      'assets/flags/DE.png',
    ]) {
      await precacheImage(AssetImage(path), context);
    }
  });
  await tester.pump();
}

ProfilesState auditProfiles() {
  final nodes = [
    for (final country in [
      ('🇸🇪 Швеция 3 | Ультра', 'se'),
      ('🇫🇮 Финляндия | Хельсинки', 'fi'),
      ('🇩🇪 Германия | Франкфурт', 'de'),
    ])
      ProxyNode.fromRaw({
        'name': country.$1,
        'type': 'vless',
        'server': '${country.$2}.example.test',
        'port': 443,
        'uuid': 'test-only',
      }),
  ];
  return ProfilesState(
    activeId: 'primary',
    profiles: [
      Profile(
        id: 'primary',
        name: 'Основная подписка',
        type: ProfileType.subscription,
        source: 'https://example.test/subscription',
        nodes: nodes,
        pinned: true,
        nozeltAuto: true,
        selectedNodeName: nodes.first.name,
        subscriptionMetadata: SubscriptionMetadata(
          uploadBytes: 1024 * 1024 * 1024,
          downloadBytes: 12 * 1024 * 1024 * 1024,
          totalBytes: 100 * 1024 * 1024 * 1024,
          expiresAt: DateTime(2027, 11, 1),
          description: 'Серверы для повседневного использования',
        ),
      ),
      Profile(
        id: 'backup',
        name: 'Резервный профиль',
        type: ProfileType.manual,
        source: '',
        nodes: [nodes.last],
      ),
    ],
  );
}

class AuditProfileStore extends ProfileStore {
  const AuditProfileStore();
  @override
  Future<ProfilesState> load() async => auditProfiles();
  @override
  Future<void> save(ProfilesState state) async {}
}

class AuditNodeHealth extends NodeHealthNotifier {
  @override
  NodeHealthState build() => NodeHealthState(
    delays: {
      for (final profile in auditProfiles().profiles)
        for (final node in profile.nodes)
          '${profile.id}\u0000${node.name}': NodeDelay(
            milliseconds: 25 + profile.nodes.indexOf(node) * 39,
            checkedAt: DateTime(2026, 10, 4),
          ),
    },
  );
}

class AuditEngineState extends EngineNotifier {
  AuditEngineState(this.connected);
  final bool connected;
  @override
  EngineState build() => connected
      ? const EngineState(
          connection: EngineConnectionState.connected,
          status: Status(
            running: true,
            startedAtUnix: 1791118800,
            uptimeSeconds: 154,
            mihomoVersion: '1.19.32',
            nozeltCoreVersion: '1.0.0',
            mode: 'rule',
            tun: TunStatus(enabled: true, stack: 'gvisor'),
            socketProtection: true,
            connectionsCount: 3,
          ),
        )
      : const EngineState();
}

class AuditEngine extends NozeltEngine {
  AuditEngine() : super(methodChannel: const MethodChannel('nozelt/ui-audit'));
  @override
  Future<bool> isVpnRequested() async => false;
  @override
  Future<bool> updateVpnNotification({
    required String flag,
    required String serverName,
    int? pingMs,
    bool updatePing = false,
    DateTime? pingMeasuredAt,
    Duration? pingMaxAge,
  }) async => true;
  @override
  Future<Status> getStatus() async => Status.idle;
  @override
  Future<EngineVersions> getVersion() async => const EngineVersions(
    nozeltCore: '1.0.0',
    mihomo: '1.19.32',
    xray: '26.9.30',
    singBox: '1.14.2',
  );
  @override
  Future<VpnPolicyState> getVpnPolicyState() async => const VpnPolicyState(
    alwaysOn: false,
    lockdown: false,
    lockdownKnown: false,
  );
  @override
  Future<List<DesktopConnection>> getConnections() async => [
    for (var i = 0; i < 4; i++)
      DesktopConnection(
        id: 'audit-$i',
        network: i == 3 ? 'udp' : 'tcp',
        inboundType: 'TUN',
        source: '192.0.2.10:45000',
        destination: '203.0.113.${i + 1}:443',
        host: [
          'store.steampowered.com',
          'cdn.example.test',
          'very-long-hostname-for-layout-checks.example.test',
          'resolver.example.test',
        ][i],
        process: i < 2 ? 'steam.exe' : 'chrome.exe',
        upload: 41000 * (i + 1),
        download: 5200000 * (i + 1),
        startedAt: 1791118800,
        chains: i == 3 ? ['DIRECT'] : ['PROXY', 'Швеция 3 | Ультра'],
        rule: i == 3 ? 'IPCIDR' : 'ProcessName',
        rulePayload: i == 3 ? '192.0.2.0/24' : 'steam.exe',
      ),
  ];
  @override
  Future<bool> closeConnection(String id) async => true;
  @override
  Future<int> closeAllConnections() async => 4;
  @override
  Future<bool> clearLogs() async => true;
  @override
  Stream<LogEntry> logsStream() => Stream.fromIterable([
    for (var i = 0; i < 18; i++)
      LogEntry(
        level: ['info', 'debug', 'warning', 'error'][i % 4],
        message: [
          '[TUN] Nozelt adapter ready; stack=gvisor',
          '[TCP] chrome.exe → example.test:443 matched ProcessName using PROXY',
          '[DNS] Resolver timeout, retrying with the next configured server',
          'Example diagnostic message with a long hostname and wrapping: very-long-hostname-for-layout-checks.example.test:443',
        ][i % 4],
        timestampMs: 1791118800000 + i * 1300,
      ),
  ]);
  @override
  Stream<Traffic> trafficStream() => Stream.value(
    const Traffic(
      uploadBytes: 43000000,
      downloadBytes: 765000000,
      uploadSpeedBps: 23000,
      downloadSpeedBps: 3200000,
      activeConnections: 4,
    ),
  );
}
