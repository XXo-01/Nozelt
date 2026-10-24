import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/routing_rule.dart';
import '../l10n/nozelt_l10n.dart';
import '../l10n/user_error.dart';
import '../state/routing_config_controller.dart';
import 'design_system/nozelt_controls.dart';
import 'widgets/nozelt_ui.dart';

class DomainRuleScreen extends ConsumerStatefulWidget {
  const DomainRuleScreen({super.key, this.rule});

  final RoutingRule? rule;

  @override
  ConsumerState<DomainRuleScreen> createState() => _DomainRuleScreenState();
}

class _DomainRuleScreenState extends ConsumerState<DomainRuleScreen> {
  late final TextEditingController _valueController;
  late RoutingRuleType _type;
  late RoutingRuleAction _action;
  late bool _enabled;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    final rule = widget.rule;
    _valueController = TextEditingController(text: rule?.value ?? '');
    _type = rule?.type ?? RoutingRuleType.domainSuffix;
    _action = rule?.action ?? RoutingRuleAction.proxy;
    _enabled = rule?.enabled ?? true;
  }

  @override
  void dispose() {
    _valueController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(context.tr('domainRule'))),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          NozeltDropdownField<RoutingRuleType>(
            value: _type,
            label: context.tr('matchType'),
            items: RoutingRuleType.values
                .where((type) => type != RoutingRuleType.processName)
                .map(
                  (type) => DropdownMenuItem(
                    value: type,
                    child: Text(_typeLabel(context, type)),
                  ),
                )
                .toList(growable: false),
            onChanged: (value) {
              if (value != null) setState(() => _type = value);
            },
          ),
          const SizedBox(height: 16),
          TextField(
            controller: _valueController,
            autofocus: widget.rule == null,
            autocorrect: false,
            enableSuggestions: false,
            keyboardType: TextInputType.url,
            decoration: InputDecoration(labelText: context.tr('ruleValue')),
          ),
          const SizedBox(height: 22),
          Text(
            context.tr('action'),
            style: Theme.of(context).textTheme.titleSmall,
          ),
          const SizedBox(height: 10),
          NozeltSegmentedControl<RoutingRuleAction>(
            segments: [
              ButtonSegment(
                value: RoutingRuleAction.proxy,
                icon: const Icon(Icons.verified_user_rounded, size: 18),
                label: Text(context.tr('throughProxy')),
              ),
              ButtonSegment(
                value: RoutingRuleAction.direct,
                icon: const Icon(Icons.arrow_forward_rounded),
                label: Text(context.tr('direct')),
              ),
              ButtonSegment(
                value: RoutingRuleAction.reject,
                icon: const Icon(Icons.block_rounded),
                label: Text(context.tr('block')),
              ),
            ],
            value: _action,
            onChanged: (value) => setState(() => _action = value),
          ),
          const SizedBox(height: 14),
          NozeltSwitchTile(
            contentPadding: EdgeInsets.zero,
            title: Text(context.tr('ruleEnabled')),
            value: _enabled,
            onChanged: (value) => setState(() => _enabled = value),
          ),
        ],
      ),
      bottomNavigationBar: NozeltPageSaveBar(saving: _saving, onPressed: _save),
    );
  }

  Future<void> _save() async {
    final rule = RoutingRule(
      id:
          widget.rule?.id ??
          'r_${DateTime.now().microsecondsSinceEpoch.toRadixString(36)}',
      type: _type,
      value: _valueController.text,
      action: _action,
      enabled: _enabled,
    );
    if (rule.validate() != null) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(context.tr('invalidRule'))));
      return;
    }
    setState(() => _saving = true);
    try {
      await ref.read(routingConfigControllerProvider).upsertRule(rule);
      if (mounted) Navigator.of(context).pop();
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(localizedUserError(context.l10n, error))),
        );
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  static String _typeLabel(BuildContext context, RoutingRuleType type) =>
      switch (type) {
        RoutingRuleType.geoIp => 'GeoIP',
        RoutingRuleType.geoSite => 'GeoSite',
        RoutingRuleType.domain => context.tr('exactDomain'),
        RoutingRuleType.domainSuffix => context.tr('domainSuffix'),
        RoutingRuleType.domainKeyword => context.tr('domainKeyword'),
        RoutingRuleType.processName => context.tr('processName'),
        RoutingRuleType.ipCidr => context.tr('ipCidr'),
      };
}
