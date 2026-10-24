import 'package:nozelt/nozelt_design_system.dart';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';

import '../../core/routing_rule.dart';
import '../../l10n/nozelt_l10n.dart';
import '../../l10n/user_error.dart';
import '../../state/routing_config_controller.dart';
import '../../state/settings_provider.dart';

class DesktopRoutingTab extends ConsumerStatefulWidget {
  const DesktopRoutingTab({super.key});

  @override
  ConsumerState<DesktopRoutingTab> createState() => _DesktopRoutingTabState();
}

class _DesktopRoutingTabState extends ConsumerState<DesktopRoutingTab> {
  static const _uuid = Uuid();

  final _valueController = TextEditingController();
  final _jsonController = TextEditingController();
  final _jsonFocus = FocusNode();
  RoutingRuleType _type = RoutingRuleType.domain;
  RoutingRuleAction _action = RoutingRuleAction.proxy;
  String? _editingId;
  bool _advanced = false;

  @override
  void initState() {
    super.initState();
    _jsonController.text = _encodeRules(
      ref.read(tunSettingsProvider).customRules,
    );
  }

  @override
  void dispose() {
    _valueController.dispose();
    _jsonController.dispose();
    _jsonFocus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final settings = ref.watch(tunSettingsProvider);
    ref.listen(tunSettingsProvider, (previous, next) {
      if (_advanced && !_jsonFocus.hasFocus) {
        _jsonController.text = _encodeRules(next.customRules);
      }
    });

    return Padding(
      padding: NozeltLayout.desktopPagePadding,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          NozeltPageHeader(
            title: context.tr('routingTab'),
            subtitle: context.tr('routingSubtitle'),
            trailing: FilledButton.tonalIcon(
              onPressed: () {
                setState(() {
                  _advanced = !_advanced;
                  if (_advanced) {
                    _jsonController.text = _encodeRules(settings.customRules);
                  }
                });
              },
              icon: Icon(
                _advanced
                    ? Icons.view_quilt_rounded
                    : Icons.data_object_rounded,
              ),
              label: Text(
                context.tr(_advanced ? 'visualEditor' : 'advancedEditor'),
              ),
            ),
          ),
          const SizedBox(height: 20),
          Expanded(
            child: _advanced
                ? _JsonEditor(
                    controller: _jsonController,
                    focusNode: _jsonFocus,
                    onApply: _applyJson,
                  )
                : _VisualEditor(
                    type: _type,
                    action: _action,
                    valueController: _valueController,
                    editing: _editingId != null,
                    rules: settings.customRules,
                    onTypeChanged: (value) => setState(() => _type = value),
                    onActionChanged: (value) => setState(() => _action = value),
                    onAddFirst: () => _saveVisual(atStart: true),
                    onAddLast: () => _saveVisual(atStart: false),
                    onEdit: _edit,
                    onCancelEdit: _resetEditor,
                  ),
          ),
          if (!_advanced) ...[
            const SizedBox(height: 12),
            _RoutingOptions(
              allowLan: settings.allowLan,
              snifferEnabled: settings.snifferEnabled,
              onAllowLan: (value) => _run(
                () => ref
                    .read(routingConfigControllerProvider)
                    .setAllowLan(value),
              ),
              onSniffer: (value) => _run(
                () => ref
                    .read(routingConfigControllerProvider)
                    .setSnifferEnabled(value),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Future<void> _saveVisual({required bool atStart}) async {
    final rule = RoutingRule(
      id: _editingId ?? _uuid.v4(),
      type: _type,
      value: _valueController.text,
      action: _action,
    );
    if (rule.validate() != null) {
      _showError(context.tr('invalidRule'));
      return;
    }
    await _run(
      () => ref
          .read(routingConfigControllerProvider)
          .upsertRule(rule, atStart: atStart),
      onSuccess: _resetEditor,
    );
  }

  void _edit(RoutingRule rule) {
    setState(() {
      _editingId = rule.id;
      _type = rule.type;
      _action = rule.action;
      _valueController.text = rule.value;
    });
  }

  void _resetEditor() {
    setState(() {
      _editingId = null;
      _type = RoutingRuleType.domain;
      _action = RoutingRuleAction.proxy;
      _valueController.clear();
    });
  }

  Future<void> _applyJson() async {
    try {
      final decoded = jsonDecode(_jsonController.text);
      final rawRules = switch (decoded) {
        List<dynamic> value => value,
        Map<String, dynamic> value when value['rules'] is List =>
          value['rules'] as List<dynamic>,
        _ => throw const FormatException('rules must be an array'),
      };
      final rules = rawRules.indexed
          .map((entry) {
            final map = (entry.$2 as Map).cast<String, dynamic>();
            final rule = RoutingRule.fromJson({
              ...map,
              'id': map['id']?.toString().trim().isNotEmpty == true
                  ? map['id']
                  : _uuid.v4(),
            });
            if (rule.validate() != null) {
              throw FormatException('invalid rule at ${entry.$1}');
            }
            return rule;
          })
          .toList(growable: false);
      await ref.read(routingConfigControllerProvider).replaceRules(rules);
      if (mounted) _jsonController.text = _encodeRules(rules);
    } catch (_) {
      if (mounted) _showError(context.tr('invalidJson'));
    }
  }

  Future<void> _run(
    Future<void> Function() operation, {
    VoidCallback? onSuccess,
  }) async {
    try {
      await operation();
      if (mounted) onSuccess?.call();
    } catch (error) {
      if (mounted) _showError(localizedUserError(context.l10n, error));
    }
  }

  void _showError(String message) {
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }

  static String _encodeRules(List<RoutingRule> rules) {
    final value = {
      'rules': rules
          .map(
            (rule) => {
              'id': rule.id,
              'type': rule.type.name,
              'value': rule.value,
              'action': rule.action.name,
              'enabled': rule.enabled,
            },
          )
          .toList(growable: false),
    };
    return const JsonEncoder.withIndent('  ').convert(value);
  }
}

class _VisualEditor extends StatelessWidget {
  const _VisualEditor({
    required this.type,
    required this.action,
    required this.valueController,
    required this.editing,
    required this.rules,
    required this.onTypeChanged,
    required this.onActionChanged,
    required this.onAddFirst,
    required this.onAddLast,
    required this.onEdit,
    required this.onCancelEdit,
  });

  final RoutingRuleType type;
  final RoutingRuleAction action;
  final TextEditingController valueController;
  final bool editing;
  final List<RoutingRule> rules;
  final ValueChanged<RoutingRuleType> onTypeChanged;
  final ValueChanged<RoutingRuleAction> onActionChanged;
  final VoidCallback onAddFirst;
  final VoidCallback onAddLast;
  final ValueChanged<RoutingRule> onEdit;
  final VoidCallback onCancelEdit;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final leftWidth = constraints.maxWidth < 680
            ? constraints.maxWidth.clamp(250.0, 280.0)
            : constraints.maxWidth.clamp(300.0, 390.0);
        return Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              width: leftWidth,
              child: NozeltSurface(
                child: SingleChildScrollView(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        context.tr('addRule'),
                        style: Theme.of(context).textTheme.titleLarge,
                      ),
                      const SizedBox(height: 18),
                      _Label(context.tr('ruleType')),
                      const SizedBox(height: 7),
                      NozeltDropdownField<RoutingRuleType>(
                        value: type,
                        items: RoutingRuleType.values
                            .map(
                              (value) => DropdownMenuItem(
                                value: value,
                                child: Text(_typeLabel(context, value)),
                              ),
                            )
                            .toList(),
                        onChanged: (value) {
                          if (value != null) onTypeChanged(value);
                        },
                      ),
                      const SizedBox(height: 15),
                      _Label(context.tr('ruleContent')),
                      const SizedBox(height: 7),
                      TextField(
                        controller: valueController,
                        decoration: InputDecoration(hintText: _hint(type)),
                        onSubmitted: (_) => onAddLast(),
                      ),
                      const SizedBox(height: 15),
                      _Label(context.tr('proxyPolicy')),
                      const SizedBox(height: 7),
                      NozeltDropdownField<RoutingRuleAction>(
                        value: action,
                        items: RoutingRuleAction.values
                            .map(
                              (value) => DropdownMenuItem(
                                value: value,
                                child: Text(_actionLabel(context, value)),
                              ),
                            )
                            .toList(),
                        onChanged: (value) {
                          if (value != null) onActionChanged(value);
                        },
                      ),
                      const SizedBox(height: 18),
                      SizedBox(
                        width: double.infinity,
                        child: FilledButton.icon(
                          onPressed: onAddFirst,
                          icon: const Icon(Icons.vertical_align_top_rounded),
                          label: Text(
                            editing
                                ? context.tr('save')
                                : context.tr('addRuleFirst'),
                          ),
                        ),
                      ),
                      const SizedBox(height: 8),
                      SizedBox(
                        width: double.infinity,
                        child: OutlinedButton.icon(
                          onPressed: onAddLast,
                          icon: const Icon(Icons.vertical_align_bottom_rounded),
                          label: Text(
                            editing
                                ? context.tr('save')
                                : context.tr('addRuleLast'),
                          ),
                        ),
                      ),
                      if (editing) ...[
                        const SizedBox(height: 8),
                        SizedBox(
                          width: double.infinity,
                          child: TextButton(
                            onPressed: onCancelEdit,
                            child: Text(context.tr('cancel')),
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: rules.isEmpty
                  ? NozeltSurface(
                      child: Center(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(
                              Icons.rule_folder_outlined,
                              size: 42,
                              color: Theme.of(
                                context,
                              ).colorScheme.onSurfaceVariant,
                            ),
                            const SizedBox(height: 10),
                            Text(
                              context.tr('noRules'),
                              style: Theme.of(context).textTheme.titleMedium,
                            ),
                            const SizedBox(height: 5),
                            Text(
                              context.tr('rulesHint'),
                              textAlign: TextAlign.center,
                              style: TextStyle(
                                color: Theme.of(
                                  context,
                                ).colorScheme.onSurfaceVariant,
                              ),
                            ),
                          ],
                        ),
                      ),
                    )
                  : ListView.separated(
                      itemCount: rules.length,
                      separatorBuilder: (_, _) => const SizedBox(height: 8),
                      itemBuilder: (context, index) => _RuleCard(
                        rule: rules[index],
                        index: index,
                        onEdit: () => onEdit(rules[index]),
                      ),
                    ),
            ),
          ],
        );
      },
    );
  }
}

class _RuleCard extends ConsumerWidget {
  const _RuleCard({
    required this.rule,
    required this.index,
    required this.onEdit,
  });

  final RoutingRule rule;
  final int index;
  final VoidCallback onEdit;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final color = switch (rule.action) {
      RoutingRuleAction.proxy => Theme.of(context).colorScheme.primary,
      RoutingRuleAction.direct => context.nozelt.success,
      RoutingRuleAction.reject => Theme.of(context).colorScheme.error,
    };
    return Material(
      color: color.withValues(alpha: rule.enabled ? 0.12 : 0.04),
      borderRadius: BorderRadius.circular(17),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onEdit,
        borderRadius: BorderRadius.circular(17),
        child: Container(
          padding: const EdgeInsets.fromLTRB(15, 12, 8, 12),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(17),
            border: Border.all(color: color.withValues(alpha: 0.35)),
          ),
          child: Row(
            children: [
              Text(
                '${index + 1}',
                style: TextStyle(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(width: 13),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      rule.value,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontWeight: FontWeight.w700,
                        color: rule.enabled
                            ? Theme.of(context).colorScheme.onSurface
                            : Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                    ),
                    const SizedBox(height: 5),
                    Wrap(
                      spacing: 8,
                      children: [
                        _Tag(
                          _typeLabel(context, rule.type),
                          Theme.of(context).colorScheme.primary,
                        ),
                        _Tag(_actionLabel(context, rule.action), color),
                      ],
                    ),
                  ],
                ),
              ),
              Switch(
                value: rule.enabled,
                onChanged: (value) => ref
                    .read(routingConfigControllerProvider)
                    .setRuleEnabled(rule.id, value),
              ),
              NozeltPopupMenuButton<String>(
                onSelected: (value) {
                  final controller = ref.read(routingConfigControllerProvider);
                  switch (value) {
                    case 'up':
                      controller.moveRule(rule.id, -1);
                    case 'down':
                      controller.moveRule(rule.id, 1);
                    case 'delete':
                      controller.deleteRule(rule.id);
                  }
                },
                itemBuilder: (context) => [
                  PopupMenuItem(value: 'up', child: Text(context.tr('moveUp'))),
                  PopupMenuItem(
                    value: 'down',
                    child: Text(context.tr('moveDown')),
                  ),
                  PopupMenuItem(
                    value: 'delete',
                    child: Text(context.tr('delete')),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _RoutingOptions extends StatelessWidget {
  const _RoutingOptions({
    required this.allowLan,
    required this.snifferEnabled,
    required this.onAllowLan,
    required this.onSniffer,
  });

  final bool allowLan;
  final bool snifferEnabled;
  final ValueChanged<bool> onAllowLan;
  final ValueChanged<bool> onSniffer;

  @override
  Widget build(BuildContext context) {
    return NozeltSurface(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final allowLanTile = SwitchListTile(
            dense: true,
            secondary: Icon(
              Icons.lan_outlined,
              color: Theme.of(context).colorScheme.primary,
            ),
            title: Text(context.tr('allowLan')),
            value: allowLan,
            onChanged: onAllowLan,
          );
          final snifferTile = SwitchListTile(
            dense: true,
            secondary: Icon(
              Icons.manage_search_rounded,
              color: Theme.of(context).colorScheme.primary,
            ),
            title: Text(context.tr('domainSniffer')),
            value: snifferEnabled,
            onChanged: onSniffer,
          );
          if (constraints.maxWidth < 620) {
            return Column(
              children: [allowLanTile, const Divider(height: 1), snifferTile],
            );
          }
          return Row(
            children: [
              Expanded(child: allowLanTile),
              const SizedBox(height: 44, child: VerticalDivider()),
              Expanded(child: snifferTile),
            ],
          );
        },
      ),
    );
  }
}

class _JsonEditor extends StatelessWidget {
  const _JsonEditor({
    required this.controller,
    required this.focusNode,
    required this.onApply,
  });

  final TextEditingController controller;
  final FocusNode focusNode;
  final VoidCallback onApply;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          context.tr('jsonRulesHint'),
          style: TextStyle(
            color: Theme.of(context).colorScheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: 10),
        Expanded(
          child: TextField(
            controller: controller,
            focusNode: focusNode,
            expands: true,
            maxLines: null,
            minLines: null,
            textAlignVertical: TextAlignVertical.top,
            style: const TextStyle(
              fontFamily: 'monospace',
              fontSize: 13.5,
              height: 1.45,
            ),
            decoration: InputDecoration(
              hintText: '{\n  "rules": []\n}',
              contentPadding: const EdgeInsets.all(18),
              fillColor: Theme.of(context).colorScheme.surfaceContainerLow,
              labelText: context.tr('jsonRules'),
              alignLabelWithHint: true,
            ),
          ),
        ),
        const SizedBox(height: 12),
        Align(
          alignment: Alignment.centerRight,
          child: FilledButton.icon(
            onPressed: onApply,
            icon: const Icon(Icons.check_rounded),
            label: Text(context.tr('apply')),
          ),
        ),
      ],
    );
  }
}

class _Label extends StatelessWidget {
  const _Label(this.value);

  final String value;

  @override
  Widget build(BuildContext context) => Text(
    value,
    style: TextStyle(
      color: Theme.of(context).colorScheme.onSurfaceVariant,
      fontSize: 12,
      fontWeight: FontWeight.w600,
    ),
  );
}

class _Tag extends StatelessWidget {
  const _Tag(this.value, this.color);

  final String value;
  final Color color;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
    decoration: BoxDecoration(
      color: color.withValues(alpha: 0.1),
      borderRadius: BorderRadius.circular(7),
      border: Border.all(color: color.withValues(alpha: 0.35)),
    ),
    child: Text(
      value,
      style: TextStyle(
        color: color,
        fontSize: 10.5,
        fontWeight: FontWeight.w700,
      ),
    ),
  );
}

String _typeLabel(BuildContext context, RoutingRuleType type) => switch (type) {
  RoutingRuleType.geoIp => 'GeoIP',
  RoutingRuleType.geoSite => 'GeoSite',
  RoutingRuleType.domain => context.tr('exactDomain'),
  RoutingRuleType.domainSuffix => context.tr('domainSuffix'),
  RoutingRuleType.domainKeyword => context.tr('domainKeyword'),
  RoutingRuleType.processName => context.tr('processName'),
  RoutingRuleType.ipCidr => context.tr('ipCidr'),
};

String _actionLabel(BuildContext context, RoutingRuleAction action) =>
    switch (action) {
      RoutingRuleAction.proxy => context.tr('throughProxy'),
      RoutingRuleAction.direct => context.tr('direct'),
      RoutingRuleAction.reject => context.tr('block'),
    };

String _hint(RoutingRuleType type) => switch (type) {
  RoutingRuleType.geoIp => 'ru',
  RoutingRuleType.geoSite => 'category-ads-all',
  RoutingRuleType.domain => 'api.example.com',
  RoutingRuleType.domainSuffix => 'example.com',
  RoutingRuleType.domainKeyword => 'telemetry',
  RoutingRuleType.processName => 'example.exe',
  RoutingRuleType.ipCidr => '203.0.113.0/24',
};
