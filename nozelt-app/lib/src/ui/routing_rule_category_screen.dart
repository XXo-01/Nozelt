import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:nozelt/nozelt_design_system.dart';

import '../core/routing_rule.dart';
import '../l10n/nozelt_l10n.dart';
import '../l10n/user_error.dart';
import '../state/routing_config_controller.dart';
import '../state/routing_profiles_provider.dart';
import 'geo_tags_screen.dart';

class RoutingRuleCategoryScreen extends ConsumerStatefulWidget {
  const RoutingRuleCategoryScreen({
    required this.titleKey,
    required this.types,
    super.key,
  });

  final String titleKey;
  final Set<RoutingRuleType> types;

  @override
  ConsumerState<RoutingRuleCategoryScreen> createState() =>
      _RoutingRuleCategoryScreenState();
}

class _RoutingRuleCategoryScreenState
    extends ConsumerState<RoutingRuleCategoryScreen> {
  final Map<RoutingRuleAction, TextEditingController> _controllers = {};
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    final rules = ref.read(routingProfilesProvider).active.rules;
    for (final action in RoutingRuleAction.values) {
      final values = rules
          .where(
            (rule) => widget.types.contains(rule.type) && rule.action == action,
          )
          .map(_displayValue)
          .join('\n');
      _controllers[action] = TextEditingController(text: values);
    }
  }

  @override
  void dispose() {
    for (final controller in _controllers.values) {
      controller.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final isGeo = widget.types.contains(RoutingRuleType.geoIp);
    final desktop = defaultTargetPlatform == TargetPlatform.windows;
    final editors = [
      for (final action in const [
        RoutingRuleAction.proxy,
        RoutingRuleAction.direct,
        RoutingRuleAction.reject,
      ])
        _ActionEditor(
          action: action,
          controller: _controllers[action]!,
          processNames: widget.types.contains(RoutingRuleType.processName),
        ),
    ];
    return Scaffold(
      appBar: desktop
          ? NozeltDesktopAppBar(title: Text(context.tr(widget.titleKey)))
          : AppBar(
              title: FittedBox(
                fit: BoxFit.scaleDown,
                alignment: Alignment.centerLeft,
                child: Text(context.tr(widget.titleKey)),
              ),
            ),
      body: NozeltEditorBody(
        child: NozeltPageInsets(
          top: NozeltSpacing.sm,
          builder: (context, insets) => ListView(
            padding: desktop
                ? insets
                : const EdgeInsets.fromLTRB(20, 12, 20, 28),
            children: [
              if (desktop)
                LayoutBuilder(
                  builder: (context, constraints) {
                    // Proxy, direct and block side by side: they are edited
                    // together, so three columns read better than three rows.
                    if (constraints.maxWidth >= 480 &&
                        MediaQuery.textScalerOf(context).scale(14) <= 21) {
                      return Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          for (var i = 0; i < editors.length; i++) ...[
                            if (i > 0) const SizedBox(width: 14),
                            Expanded(child: editors[i]),
                          ],
                        ],
                      );
                    }
                    return Column(
                      children: [
                        for (final editor in editors) ...[
                          editor,
                          const SizedBox(height: 14),
                        ],
                      ],
                    );
                  },
                )
              else
                for (final editor in editors) ...[
                  editor,
                  const SizedBox(height: 14),
                ],
              if (isGeo) ...[
                Row(
                  children: [
                    Expanded(
                      child: OutlinedButton.icon(
                        onPressed: () => _openTags(GeoTagKind.geoIp),
                        icon: const Icon(Icons.public_rounded),
                        label: Text(context.tr('geoIpTags')),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: OutlinedButton.icon(
                        onPressed: () => _openTags(GeoTagKind.geoSite),
                        icon: const Icon(Icons.language_rounded),
                        label: Text(context.tr('geoSiteTags')),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 14),
              ],
            ],
          ),
        ),
      ),
      bottomNavigationBar: NozeltPageSaveBar(saving: _saving, onPressed: _save),
    );
  }

  String _displayValue(RoutingRule rule) => switch (rule.type) {
    RoutingRuleType.geoIp => 'geoip:${rule.normalizedValue}',
    RoutingRuleType.geoSite => 'geosite:${rule.normalizedValue}',
    _ => rule.normalizedValue,
  };

  List<(RoutingRuleType, String)> _parse(String text) {
    final lines = text
        .split(RegExp(r'\r?\n'))
        .map((value) => value.trim())
        .where((value) => value.isNotEmpty);
    final result = <(RoutingRuleType, String)>[];
    final isGeo = widget.types.contains(RoutingRuleType.geoIp);
    for (final line in lines) {
      RoutingRuleType type;
      String value;
      if (isGeo) {
        final separator = line.indexOf(':');
        if (separator <= 0) throw const FormatException('geo-prefix');
        final prefix = line.substring(0, separator).trim().toLowerCase();
        value = line.substring(separator + 1).trim();
        type = switch (prefix) {
          'geoip' => RoutingRuleType.geoIp,
          'geosite' => RoutingRuleType.geoSite,
          _ => throw const FormatException('geo-prefix'),
        };
      } else {
        type = widget.types.single;
        value = line;
      }
      final probe = RoutingRule(
        id: 'validation',
        type: type,
        value: value,
        action: RoutingRuleAction.proxy,
      );
      if (probe.validate() != null) throw const FormatException('rule');
      result.add((type, value));
    }
    return result;
  }

  Future<void> _save() async {
    setState(() => _saving = true);
    try {
      final values = <RoutingRuleAction, List<(RoutingRuleType, String)>>{
        for (final action in RoutingRuleAction.values)
          action: _parse(_controllers[action]!.text),
      };
      await ref
          .read(routingConfigControllerProvider)
          .replaceCategoryRules(widget.types, values);
      if (mounted) Navigator.of(context).pop();
    } catch (error) {
      if (!mounted) return;
      final text = error is FormatException
          ? context.tr('invalidRuleList')
          : localizedUserError(context.l10n, error);
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _openTags(GeoTagKind kind) async {
    final value = await Navigator.of(context).push<String>(
      MaterialPageRoute(builder: (_) => GeoTagsScreen(kind: kind)),
    );
    if (value == null || !mounted) return;
    final action = await showModalBottomSheet<RoutingRuleAction>(
      context: context,
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final entry in const [
              (RoutingRuleAction.proxy, 'throughProxy'),
              (RoutingRuleAction.direct, 'direct'),
              (RoutingRuleAction.reject, 'block'),
            ])
              ListTile(
                leading: _RoutingActionIcon(action: entry.$1),
                title: Text(context.tr(entry.$2)),
                onTap: () => Navigator.pop(sheetContext, entry.$1),
              ),
          ],
        ),
      ),
    );
    if (action == null || !mounted) return;
    final controller = _controllers[action]!;
    final prefix = controller.text.trim().isEmpty ? '' : '\n';
    controller.text = '${controller.text.trimRight()}$prefix$value';
  }
}

class _ActionEditor extends StatelessWidget {
  const _ActionEditor({
    required this.action,
    required this.controller,
    this.processNames = false,
  });

  final RoutingRuleAction action;
  final TextEditingController controller;
  final bool processNames;

  @override
  Widget build(BuildContext context) {
    final desktop = defaultTargetPlatform == TargetPlatform.windows;
    final key = switch (action) {
      RoutingRuleAction.proxy => 'throughProxy',
      RoutingRuleAction.direct => 'direct',
      RoutingRuleAction.reject => 'block',
    };
    return NozeltSurface(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              _RoutingActionIcon(action: action),
              const SizedBox(width: 10),
              Text(
                context.tr(key),
                style: Theme.of(context).textTheme.titleMedium,
              ),
            ],
          ),
          const SizedBox(height: 12),
          TextField(
            controller: controller,
            minLines: desktop ? 8 : 4,
            maxLines: desktop ? 16 : 10,
            autocorrect: false,
            enableSuggestions: false,
            decoration: InputDecoration(
              hintText: processNames ? 'steam.exe\nchrome.exe' : null,
            ),
          ),
        ],
      ),
    );
  }
}

class _RoutingActionIcon extends StatelessWidget {
  const _RoutingActionIcon({required this.action});

  final RoutingRuleAction action;

  @override
  Widget build(BuildContext context) => switch (action) {
    RoutingRuleAction.proxy => Icon(
      Icons.verified_user_rounded,
      size: 24,
      color: Theme.of(context).colorScheme.primary,
    ),
    RoutingRuleAction.direct => Icon(
      Icons.call_made_rounded,
      size: 24,
      color: context.nozelt.success,
    ),
    RoutingRuleAction.reject => Icon(
      Icons.block_rounded,
      size: 24,
      color: Theme.of(context).colorScheme.error,
    ),
  };
}
