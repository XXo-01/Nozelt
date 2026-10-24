import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/advanced_network_settings.dart';
import '../core/tun_settings.dart';
import '../core/nozelt_engine.dart';
import '../l10n/nozelt_l10n.dart';
import '../l10n/user_error.dart';
import '../state/network_settings_controller.dart';
import '../state/settings_provider.dart';
import 'design_system/nozelt_tokens.dart';
import 'design_system/nozelt_controls.dart';
import 'widgets/nozelt_ui.dart';

/// Staged category edits: nothing touches the running core until Save, which
/// uses the existing serialized protected replacement/rollback transaction.
class NetworkSettingsScreen extends ConsumerStatefulWidget {
  const NetworkSettingsScreen({required this.dns, super.key});
  final bool dns;

  @override
  ConsumerState<NetworkSettingsScreen> createState() =>
      _NetworkSettingsScreenState();
}

class _NetworkSettingsScreenState extends ConsumerState<NetworkSettingsScreen> {
  final _fields = <String, TextEditingController>{};
  late Map<String, dynamic> _values;
  late TunStack _stack;
  bool _ipv6 = false, _saving = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load(ref.read(tunSettingsProvider));
  }

  void _load(TunSettings s) {
    _values = widget.dns ? s.dns.toMap() : s.desktop.toMap();
    _stack = s.stack;
    _ipv6 = s.ipv6;
    final values = <String, Object>{
      ..._values,
      'fakeIpRange': s.fakeIpRange,
      'nameservers': s.nameservers,
      'mtu': s.mtu,
    };
    for (final entry in values.entries) {
      if (entry.value is bool) continue;
      final text = switch (entry.value) {
        final Map map =>
          map.entries
              .map((e) => '${e.key} = ${(e.value as List).join(', ')}')
              .join('\n'),
        final List list => list.join('\n'),
        final value => value.toString(),
      };
      (_fields[entry.key] ??= TextEditingController()).text = text;
    }
    _error = null;
  }

  @override
  void dispose() {
    for (final controller in _fields.values) {
      controller.dispose();
    }
    super.dispose();
  }

  bool get _windows => Theme.of(context).platform == TargetPlatform.windows;

  List<String> _lines(String key) => _fields[key]!.text
      .split('\n')
      .map((s) => s.trim())
      .where((s) => s.isNotEmpty)
      .toList();

  Map<String, List<String>> _policies(String key) {
    final result = <String, List<String>>{};
    for (final line in _lines(key)) {
      final equals = line.indexOf('=');
      if (equals <= 0) throw const FormatException();
      final pattern = line.substring(0, equals).trim();
      if (result.containsKey(pattern)) throw const FormatException();
      final entries = line
          .substring(equals + 1)
          .split(',')
          .map((v) => v.trim())
          .toList();
      if (entries.any((s) => s.isEmpty)) throw const FormatException();
      result[pattern] = entries;
    }
    return result;
  }

  Future<void> _save() async {
    if (_saving) return;
    final current = ref.read(tunSettingsProvider);
    late TunSettings next;
    try {
      final map = Map<String, dynamic>.from(_values);
      if (widget.dns) {
        for (final key in [
          'filters',
          'bootstrap',
          'directResolvers',
          'fallback',
          'fallbackCidrs',
          'fallbackDomains',
        ]) {
          map[key] = _lines(key);
        }
        for (final key in ['policy', 'proxyPolicy', 'hosts']) {
          map[key] = _policies(key);
        }
        for (final key in ['fakeIpTtl', 'cacheSize', 'ipv6Timeout']) {
          map[key] = int.parse(_fields[key]!.text.trim());
        }
        map['fakeIpv6Range'] = _fields['fakeIpv6Range']!.text.trim();
        map['fallbackCountry'] = _fields['fallbackCountry']!.text
            .trim()
            .toUpperCase();
        next = current.copyWith(
          dns: AdvancedDnsSettings.fromMap(map),
          fakeIpRange: _fields['fakeIpRange']!.text.trim(),
          nameservers: _lines('nameservers'),
        );
      } else {
        for (final key in ['udpTimeout', 'icmpTimeout']) {
          map[key] = int.parse(_fields[key]!.text.trim());
        }
        map['loopbackAddresses'] = _lines('loopbackAddresses');
        map['ipv6Address'] = _fields['ipv6Address']!.text.trim();
        next = current.copyWith(
          desktop: DesktopTunSettings.fromMap(map),
          stack: _stack,
          mtu: int.parse(_fields['mtu']!.text.trim()),
          ipv6: _ipv6,
        );
      }
      final validation = next.validationKey();
      if (validation != null) {
        setState(() => _error = context.tr(validation));
        return;
      }
    } on FormatException {
      setState(
        () => _error = context.tr(
          widget.dns ? 'invalidAdvancedDns' : 'invalidAdvancedTun',
        ),
      );
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      final controller = ref.read(networkSettingsControllerProvider);
      if (widget.dns) {
        await controller.setAdvancedDns(
          dns: next.dns,
          fakeIpRange: next.fakeIpRange,
          nameservers: next.nameservers,
        );
      } else {
        await controller.setDesktopTun(
          desktop: next.desktop,
          stack: next.stack,
          mtu: next.mtu,
          ipv6: next.ipv6,
        );
      }
      if (mounted) Navigator.pop(context);
    } catch (error) {
      if (mounted) {
        setState(
          () => _error =
              error is NozeltEngineException && error.code == 'parse_failed'
              ? context.tr('networkNativeRejected')
              : localizedUserError(context.l10n, error),
        );
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Widget _field(
    String key,
    String label, {
    String? hint,
    int lines = 1,
    String? help,
  }) => NozeltSettingsField(
    label: context.tr(label),
    help: help == null ? null : context.tr(help),
    controlMaxWidth:
        {
          'mtu',
          'cacheSize',
          'fakeIpTtl',
          'ipv6Timeout',
          'udpTimeout',
          'icmpTimeout',
          'fallbackCountry',
        }.contains(key)
        ? 180
        : double.infinity,
    child: NozeltTextField(
      key: ValueKey('network-$key'),
      controller: _fields[key],
      enabled: !_saving,
      minLines: lines,
      maxLines: lines == 1 ? 1 : 6,
      autocorrect: false,
      enableSuggestions: false,
      keyboardType:
          {
            'mtu',
            'cacheSize',
            'fakeIpTtl',
            'ipv6Timeout',
            'udpTimeout',
            'icmpTimeout',
          }.contains(key)
          ? TextInputType.number
          : null,
      hintText: hint,
    ),
  );

  Widget _choice(String key, String label, List<(String, String)> choices) =>
      NozeltSettingsField(
        label: context.tr(label),
        controlMaxWidth: 360,
        child: NozeltDropdownField<String>(
          key: ValueKey('$key-${_values[key]}'),
          value: _values[key] as String,
          items: [
            for (final choice in choices)
              DropdownMenuItem(
                value: choice.$1,
                child: Text(context.tr(choice.$2)),
              ),
          ],
          onChanged: _saving ? null : (v) => setState(() => _values[key] = v!),
        ),
      );

  Widget _toggle(String key, String label, {String? help}) {
    final control = NozeltSwitchTile(
      contentPadding: EdgeInsets.zero,
      title: Text(
        context.tr(label),
        style: Theme.of(context).textTheme.bodyMedium,
      ),
      value: _values[key] as bool,
      onChanged: _saving ? null : (v) => setState(() => _values[key] = v),
    );
    return help == null
        ? control
        : Tooltip(message: context.tr(help), child: control);
  }

  Widget _group(String label, List<Widget> children) => Padding(
    padding: const EdgeInsets.only(bottom: NozeltSpacing.xxl),
    child: NozeltSettingsGroup(
      title: context.tr(label),
      icon: switch (label) {
        'dnsUpstream' || 'dnsFallbackTab' => Icons.dns_outlined,
        'dnsResponses' => Icons.swap_vert_rounded,
        'dnsPool' => Icons.hub_outlined,
        'dnsExceptions' || 'dnsFallbackConditions' => Icons.filter_alt_outlined,
        'dnsPolicyTab' => Icons.alt_route_rounded,
        'dnsHosts' => Icons.list_alt_rounded,
        'tunInterfaceTab' => Icons.tune_rounded,
        'tunLoopback' => Icons.lan_outlined,
        'tunTrafficTab' || 'tunIcmp' => Icons.swap_horiz_rounded,
        'tunProtectionTab' => Icons.verified_user_outlined,
        _ => null,
      },
      children: children,
    ),
  );

  Widget _extra(String title, List<Widget> children, {bool expanded = false}) {
    final tile = _extraTile(title, children, expanded);
    if (Theme.of(context).platform != TargetPlatform.windows) return tile;
    // The row sits flush with the group's padding, where any hover fill would
    // be a hard-edged rectangle. On Windows the chevron alone signals it.
    return Theme(
      data: Theme.of(context).copyWith(
        hoverColor: Colors.transparent,
        highlightColor: Colors.transparent,
        splashFactory: NoSplash.splashFactory,
      ),
      child: tile,
    );
  }

  Widget _extraTile(String title, List<Widget> children, bool expanded) =>
      ExpansionTile(
        key: PageStorageKey('network-extra-$title'),
        initiallyExpanded: expanded,
        maintainState: true,
        tilePadding: EdgeInsets.zero,
        childrenPadding: const EdgeInsets.only(top: NozeltSpacing.md),
        shape: const Border(),
        collapsedShape: const Border(),
        title: Text(
          context.tr(title),
          style: Theme.of(context).textTheme.bodyMedium,
        ),
        children: [
          for (var index = 0; index < children.length; index++) ...[
            if (index > 0) const SizedBox(height: NozeltSpacing.md),
            children[index],
          ],
        ],
      );

  Widget _page(String key, List<Widget> children) => NozeltPageInsets(
    top: NozeltSpacing.xl,
    bottom: NozeltSpacing.xxl,
    builder: (context, insets) => ListView(
      key: PageStorageKey('network-page-$key'),
      padding: Theme.of(context).platform == TargetPlatform.windows
          ? insets
          : const EdgeInsets.fromLTRB(24, 20, 24, 24),
      children: children,
    ),
  );

  List<Widget> _dnsPages() => [
    _page('dns-main', [
      _group('dnsUpstream', [
        _field(
          'nameservers',
          'dnsMainResolvers',
          lines: 2,
          hint: 'https://1.1.1.1/dns-query',
        ),
        _extra(
          'dnsExtraResolvers',
          [
            _field(
              'bootstrap',
              'dnsBootstrap',
              lines: 2,
              help: 'dnsInherit',
              hint: 'https://9.9.9.9/dns-query',
            ),
            _field(
              'directResolvers',
              'dnsDirect',
              lines: 2,
              help: 'dnsDirectPrivate',
            ),
          ],
          expanded:
              _lines('bootstrap').isNotEmpty ||
              _lines('directResolvers').isNotEmpty,
        ),
      ]),
      _group('dnsResponses', [
        _toggle('ipv6', 'dnsIpv6', help: 'dnsIpv6Hint'),
        if (_values['ipv6'] == true)
          _field('ipv6Timeout', 'dnsIpv6Timeout', help: 'dnsIpv6TimeoutHint'),
        _toggle('preferH3', 'dnsPreferH3'),
        _extra('dnsCache', [
          _choice('cacheAlgorithm', 'dnsCacheAlgorithm', [
            ('lru', 'LRU'),
            ('arc', 'ARC'),
          ]),
          _field('cacheSize', 'dnsCacheSize', help: 'dnsCacheLimits'),
        ]),
      ]),
    ]),
    _page('dns-fake', [
      _group('dnsPool', [
        _choice('mode', 'dnsMode', [
          ('fake-ip', 'Fake-IP'),
          ('redir-host', 'Redir-Host'),
        ]),
        _field('fakeIpRange', 'fakeIpRange', help: 'dnsFakeRangeHint'),
        _field('fakeIpv6Range', 'dnsFakeIpv6Range'),
        _field('fakeIpTtl', 'dnsFakeTtl', help: 'dnsTtlLimits'),
      ]),
      _group('dnsExceptions', [
        _choice('filterMode', 'dnsFilterMode', [
          ('blacklist', 'dnsBlacklist'),
          ('whitelist', 'dnsWhitelist'),
          ('rule', 'dnsRuleFilter'),
        ]),
        _field(
          'filters',
          'dnsFilters',
          lines: 4,
          help: _values['filterMode'] == 'rule'
              ? 'dnsRuleFilterHint'
              : 'dnsFilterHint',
        ),
        if (_windows)
          _toggle('storeFakeIp', 'dnsStoreFakeIp', help: 'dnsStoreFakeIpHint'),
      ]),
    ]),
    _page('dns-policy', [
      _group('dnsPolicyTab', [
        _field(
          'policy',
          'dnsPolicy',
          lines: 3,
          help: 'dnsPolicyHint',
          hint: '+.example.com = https://1.1.1.1/dns-query',
        ),
        _field(
          'proxyPolicy',
          'dnsProxyPolicy',
          lines: 2,
          help: 'dnsPolicyHint',
        ),
        _toggle('directFollowPolicy', 'dnsDirectFollow'),
      ]),
      _group('dnsHosts', [
        _toggle('useHosts', 'dnsUseHosts'),
        if (_windows) _toggle('useSystemHosts', 'dnsUseSystemHosts'),
        _field(
          'hosts',
          'dnsHostEntries',
          lines: 3,
          help: 'dnsHostsHint',
          hint: 'nas.lan = 192.168.1.10',
        ),
      ]),
    ]),
    _page('dns-fallback', [
      _group('dnsFallbackTab', [
        _field(
          'fallback',
          'dnsFallbackServers',
          lines: 3,
          help: 'dnsFallbackHint',
        ),
        _toggle('fallbackLazy', 'dnsFallbackLazy'),
      ]),
      _group('dnsFallbackConditions', [
        _toggle('fallbackGeoIp', 'dnsFallbackGeoIp'),
        _field('fallbackCountry', 'dnsFallbackCountry', hint: 'RU'),
        _field('fallbackCidrs', 'dnsFallbackCidrs', lines: 3),
        _field('fallbackDomains', 'dnsFallbackDomains', lines: 3),
      ]),
    ]),
  ];

  List<Widget> _tunPages() => [
    _page('tun-main', [
      _group('tunInterfaceTab', [
        NozeltSettingsField(
          label: context.tr('networkStack'),
          controlMaxWidth: 360,
          child: NozeltDropdownField<String>(
            key: ValueKey('tun-stack-${_values['stackOverride']}-$_stack'),
            value: _values['stackOverride'] == 'mips' ? 'mips' : _stack.name,
            items: [
              for (final v in [
                'gvisor',
                'system',
                'mixed',
                if (_windows) 'mips',
              ])
                DropdownMenuItem(
                  value: v,
                  child: Text(
                    {
                      'gvisor': 'gVisor',
                      'system': 'System',
                      'mixed': 'Mixed',
                      'mips': 'MIPS',
                    }[v]!,
                  ),
                ),
            ],
            onChanged: _saving
                ? null
                : (v) => setState(() {
                    _values['stackOverride'] = v == 'mips' ? 'mips' : '';
                    if (v != 'mips') _stack = TunStack.fromName(v);
                  }),
          ),
        ),
        _field('mtu', 'MTU', help: 'tunMtuLimits'),
        NozeltSwitchTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('IPv6'),
          value: _ipv6,
          onChanged: _saving ? null : (v) => setState(() => _ipv6 = v),
        ),
        // Android's VpnService owns the tunnel's own addresses.
        if (_ipv6 && _windows) _field('ipv6Address', 'tunIpv6Address'),
        if (_values['stackOverride'] == 'mips')
          _choice('congestionController', 'tunCongestion', [
            ('cubic', 'CUBIC'),
            ('reno', 'Reno'),
            ('bbr', 'BBR'),
            ('bbr3', 'BBR3'),
          ]),
      ]),
      if (_windows)
        _group('tunLoopback', [
          _field(
            'loopbackAddresses',
            'tunLoopbackAddresses',
            lines: 2,
            help: 'tunLoopbackHint',
          ),
        ]),
    ]),
    _page('tun-traffic', [
      _group('tunTrafficTab', [
        _field('udpTimeout', 'tunUdpTimeout', help: 'tunUdpLimits'),
      ]),
      // Android always answers ping inside the tunnel (no ICMP leak).
      if (_windows)
        _group('tunIcmp', [
          _toggle('disableIcmpForwardingV2', 'tunDisableIcmp'),
          _field('icmpTimeout', 'tunIcmpTimeout', help: 'tunIcmpLimits'),
        ]),
    ]),
    if (_windows)
      _page('tun-protection', [
        _group('tunProtectionTab', [
          for (final key in [
            'tunAutoRoute',
            'tunAutoInterface',
            'tunStrictRoute',
            'tunDnsHijack',
            'tunKillSwitch',
            'tunDevice',
          ])
            ListTile(
              contentPadding: EdgeInsets.zero,
              title: Text(context.tr(key)),
              trailing: key == 'tunDevice'
                  ? const Text('Nozelt')
                  : Icon(Icons.check_rounded, color: context.nozelt.success),
            ),
        ]),
        Text(
          context.tr('tunProtectionHint'),
          style: Theme.of(context).textTheme.bodyMedium?.copyWith(
            color: Theme.of(context).colorScheme.onSurfaceVariant,
          ),
        ),
      ]),
  ];

  @override
  Widget build(BuildContext context) {
    final titles = widget.dns
        ? ['dnsGeneralTab', 'Fake-IP', 'dnsPolicyTab', 'dnsFallbackTab']
        : [
            'tunInterfaceTab',
            'tunTrafficTab',
            // Routing and leak protection belong to Android itself.
            if (_windows) 'tunProtectionTab',
          ];
    final defaults = TextButton(
      onPressed: _saving
          ? null
          : () => setState(() => _load(const TunSettings())),
      child: Text(context.tr('networkDefaults')),
    );
    final desktop = Theme.of(context).platform == TargetPlatform.windows;
    // On Windows the tab labels start at the content column edge.
    final tabs = TabBar(
      isScrollable: true,
      padding: desktop
          ? EdgeInsets.zero
          : const EdgeInsets.symmetric(horizontal: NozeltSpacing.sm),
      labelPadding: desktop
          ? const EdgeInsets.symmetric(horizontal: NozeltSpacing.lg)
          : null,
      tabAlignment: TabAlignment.start,
      tabs: [
        for (final title in titles) Tab(height: 40, text: context.tr(title)),
      ],
    );
    return PopScope(
      canPop: !_saving,
      child: DefaultTabController(
        length: titles.length,
        child: Scaffold(
          appBar: desktop
              ? NozeltDesktopAppBar(
                  title: Text(
                    context.tr(widget.dns ? 'dnsSettings' : 'tunSettings'),
                  ),
                  actions: [defaults],
                  bottom: tabs,
                )
              : AppBar(
                  title: Text(
                    context.tr(widget.dns ? 'dnsSettings' : 'tunSettings'),
                  ),
                  actions: [defaults],
                  bottom: tabs,
                ),
          body: NozeltEditorBody(
            child: Column(
              children: [
                if (_error != null)
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(16),
                    color: Theme.of(context).colorScheme.surface,
                    child: Text(
                      _error!,
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.error,
                      ),
                    ),
                  ),
                Expanded(
                  child: TabBarView(
                    children: widget.dns ? _dnsPages() : _tunPages(),
                  ),
                ),
              ],
            ),
          ),
          bottomNavigationBar: NozeltPageSaveBar(
            onPressed: _save,
            saving: _saving,
            onCancel: () => Navigator.pop(context),
          ),
        ),
      ),
    );
  }
}
