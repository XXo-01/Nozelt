import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:nozelt/src/core/config_builder.dart';
import 'package:nozelt/src/core/multi_core_config_builder.dart';
import 'package:nozelt/src/core/profile.dart';
import 'package:nozelt/src/core/proxy_node.dart';
import 'package:nozelt/src/core/tun_settings.dart';
import 'package:nozelt/src/core/vpn_core.dart';
import 'package:nozelt/src/state/nozelt_auto_provider.dart';

ProxyNode _node(String name) => ProxyNode.fromRaw({
  'name': name,
  'type': 'vless',
  'server': '$name.example',
  'port': 443,
  'uuid': '11111111-1111-4111-8111-111111111111',
  'tls': true,
});

Profile _profile({
  VpnCore core = VpnCore.mihomo,
  String? pick,
  bool selected = true,
}) => Profile(
  id: 'p',
  name: 'P',
  type: ProfileType.subscription,
  source: 'https://example.test/sub',
  nodes: [_node('a'), _node('b'), _node('c')],
  detectedCore: core,
  nozeltAuto: true,
  selectedNodeName: selected ? Profile.nozeltAutoId : 'b',
  autoPickName: pick,
);

void main() {
  test('the selected auto server connects through its pick', () {
    final profile = _profile(pick: 'c');
    expect(profile.autoSelected, isTrue);
    expect(profile.effectiveSelectedNodeName, 'c');
    expect(profile.selectedNode?.name, 'c');
    expect(_profile().effectiveSelectedNodeName, 'a');
    expect(_profile(selected: false).effectiveSelectedNodeName, 'b');
    expect(
      _profile().copyWith(nozeltAuto: false).effectiveSelectedNodeName,
      'a',
    );
  });

  test('auto selection and its pick survive persistence', () {
    final json =
        jsonDecode(jsonEncode(_profile(pick: 'b').toJson()))
            as Map<String, dynamic>;
    expect(json['selectedNodeName'], Profile.nozeltAutoId);
    expect(json['nodes'], hasLength(3));
    final restored = Profile.fromJson(json);
    expect(restored.autoSelected, isTrue);
    expect(restored.effectiveSelectedNodeName, 'b');
  });

  test('every core receives an ordinary server', () {
    for (final core in VpnCore.values) {
      final rendered = MultiCoreConfigBuilder.build(
        const TunSettings(),
        profile: _profile(core: core, pick: 'b'),
      );
      expect(rendered.content, contains('b.example'), reason: core.name);
    }
    final mihomo =
        jsonDecode(
              ConfigBuilder.buildConfig(
                const TunSettings(),
                nodes: _profile(pick: 'b').nodes,
                selectedNodeName: _profile(pick: 'b').effectiveSelectedNodeName,
              ),
            )
            as Map<String, dynamic>;
    final selector = (mihomo['proxy-groups'] as List).cast<Map>().last;
    expect((selector['proxies'] as List).first, 'b');
  });

  test('switches only when it is clearly worth it', () {
    final delays = {'a': 300, 'b': 120, 'c': 260};
    int? delay(String name) => delays[name];
    // Current server is unknown at first: take the fastest.
    expect(NozeltAutoServer.choose(_profile(), (_) => null), isNull);
    expect(NozeltAutoServer.choose(_profile(pick: 'a'), delay), 'b');
    // Already on the fastest server.
    expect(NozeltAutoServer.choose(_profile(pick: 'b'), delay), isNull);
    // A small gain is not worth a switch.
    delays['c'] = 140;
    expect(NozeltAutoServer.choose(_profile(pick: 'c'), delay), isNull);
    // An unreachable current server is always replaced.
    delays.remove('c');
    expect(NozeltAutoServer.choose(_profile(pick: 'c'), delay), 'b');
    // Native cores reconnect, so they need a larger gain.
    delays
      ..['a'] = 200
      ..['b'] = 140;
    expect(NozeltAutoServer.choose(_profile(pick: 'a'), delay), 'b');
    expect(
      NozeltAutoServer.choose(_profile(pick: 'a', core: VpnCore.xray), delay),
      isNull,
    );
  });
}
