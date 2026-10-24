import 'package:nozelt/nozelt_design_system.dart';
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/routing_profile.dart';
import '../core/routing_rule.dart';
import '../l10n/nozelt_l10n.dart';
import '../l10n/user_error.dart';
import '../state/routing_config_controller.dart';
import '../state/routing_profiles_provider.dart';

class RoutingProfileSettingsScreen extends ConsumerStatefulWidget {
  const RoutingProfileSettingsScreen({super.key});

  @override
  ConsumerState<RoutingProfileSettingsScreen> createState() =>
      _RoutingProfileSettingsScreenState();
}

class _RoutingProfileSettingsScreenState
    extends ConsumerState<RoutingProfileSettingsScreen> {
  bool _updating = false;

  @override
  Widget build(BuildContext context) {
    final profile = ref.watch(routingProfilesProvider).active;
    final settings = profile.settings;
    return Scaffold(
      appBar: defaultTargetPlatform == TargetPlatform.windows
          ? NozeltDesktopAppBar(title: Text(context.tr('routingSettings')))
          : AppBar(
              title: FittedBox(
                fit: BoxFit.scaleDown,
                child: Text(context.tr('routingSettings')),
              ),
            ),
      body: NozeltEditorBody(
        child: NozeltPageInsets(
          top: NozeltSpacing.sm,
          builder: (context, insets) => ListView(
            padding: defaultTargetPlatform == TargetPlatform.windows
                ? insets
                : const EdgeInsets.fromLTRB(20, 12, 20, 28),
            children: [
              NozeltSectionTitle(context.tr('geoDataUpdates')),
              const SizedBox(height: 10),
              NozeltSurface(
                padding: EdgeInsets.zero,
                child: Column(
                  children: [
                    ListTile(
                      contentPadding: const EdgeInsets.fromLTRB(16, 5, 12, 5),
                      leading: Icon(
                        Icons.update_rounded,
                        color: Theme.of(context).colorScheme.primary,
                      ),
                      title: Text(context.tr('updateInterval')),
                      trailing: _IntervalChoice(
                        value: settings.geoUpdateIntervalHours,
                        onChanged: (value) => _setInterval(settings, value),
                      ),
                    ),
                    const Divider(height: 1, indent: 60),
                    ListTile(
                      contentPadding: const EdgeInsets.fromLTRB(16, 5, 12, 5),
                      leading: _updating
                          ? const SizedBox.square(
                              dimension: 24,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : Icon(
                              Icons.cloud_download_rounded,
                              color: Theme.of(context).colorScheme.primary,
                            ),
                      title: Text(context.tr('updateNow')),
                      subtitle: settings.lastGeoUpdateEpochSeconds == null
                          ? null
                          : Text(
                              _formatTimestamp(
                                settings.lastGeoUpdateEpochSeconds!,
                              ),
                            ),
                      onTap: _updating ? null : _updateNow,
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 22),
              NozeltSectionTitle(context.tr('routingOrder')),
              const SizedBox(height: 10),
              NozeltSurface(
                padding: const EdgeInsets.symmetric(vertical: 6),
                child: ReorderableListView.builder(
                  shrinkWrap: true,
                  physics: const NeverScrollableScrollPhysics(),
                  buildDefaultDragHandles: false,
                  itemCount: settings.actionOrder.length,
                  onReorder: (oldIndex, newIndex) {
                    if (newIndex > oldIndex) newIndex--;
                    final order = [...settings.actionOrder];
                    final value = order.removeAt(oldIndex);
                    order.insert(newIndex, value);
                    _save(settings.copyWith(actionOrder: order));
                  },
                  itemBuilder: (context, index) {
                    final action = settings.actionOrder[index];
                    return ListTile(
                      key: ValueKey(action),
                      leading: CircleAvatar(
                        radius: 14,
                        foregroundColor: Theme.of(context).colorScheme.primary,
                        backgroundColor: Theme.of(
                          context,
                        ).colorScheme.primary.withValues(alpha: 0.12),
                        child: Text('${index + 1}'),
                      ),
                      title: Text(_actionLabel(context, action)),
                      trailing: ReorderableDragStartListener(
                        index: index,
                        child: Icon(
                          Icons.drag_handle_rounded,
                          color: Theme.of(context).colorScheme.onSurfaceVariant,
                        ),
                      ),
                    );
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  String _actionLabel(BuildContext context, RoutingRuleAction action) =>
      switch (action) {
        RoutingRuleAction.reject => context.tr('block'),
        RoutingRuleAction.proxy => context.tr('throughProxy'),
        RoutingRuleAction.direct => context.tr('direct'),
      };

  String _formatTimestamp(int seconds) {
    final value = DateTime.fromMillisecondsSinceEpoch(
      seconds * 1000,
      isUtc: true,
    ).toLocal();
    String two(int part) => part.toString().padLeft(2, '0');
    return '${two(value.day)}.${two(value.month)}.${value.year} '
        '${two(value.hour)}:${two(value.minute)}';
  }

  Future<void> _setInterval(
    RoutingProfileSettings settings,
    int selected,
  ) async {
    var value = selected;
    if (selected == -1) {
      final input = TextEditingController(
        text: settings.geoUpdateIntervalHours > 0
            ? settings.geoUpdateIntervalHours.toString()
            : '24',
      );
      final result = await showDialog<int>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: Text(context.tr('customIntervalHours')),
          content: TextField(
            controller: input,
            autofocus: true,
            keyboardType: TextInputType.number,
            inputFormatters: [FilteringTextInputFormatter.digitsOnly],
            decoration: InputDecoration(suffixText: context.tr('hoursShort')),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: Text(context.tr('cancel')),
            ),
            FilledButton(
              onPressed: () =>
                  Navigator.pop(dialogContext, int.tryParse(input.text)),
              child: Text(context.tr('save')),
            ),
          ],
        ),
      );
      input.dispose();
      if (result == null || result < 1) return;
      value = result;
    }
    await _save(settings.copyWith(geoUpdateIntervalHours: value));
  }

  Future<void> _save(RoutingProfileSettings settings) async {
    try {
      await ref
          .read(routingConfigControllerProvider)
          .updateProfileSettings(settings);
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(localizedUserError(context.l10n, error))),
      );
    }
  }

  Future<void> _updateNow() async {
    setState(() => _updating = true);
    try {
      await ref.read(routingConfigControllerProvider).markGeoDataUpdated();
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(context.tr('geoDataUpdated'))));
      }
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(localizedUserError(context.l10n, error))),
        );
      }
    } finally {
      if (mounted) setState(() => _updating = false);
    }
  }
}

class _IntervalChoice extends StatelessWidget {
  const _IntervalChoice({required this.value, required this.onChanged});

  final int value;
  final ValueChanged<int> onChanged;

  @override
  Widget build(BuildContext context) {
    const presets = {0, 1, 6, 12, 24, 72, 168};
    final menuValue = presets.contains(value) ? value : -1;
    final label = switch (value) {
      0 => context.tr('never'),
      1 => context.tr('hours', {'value': 1}),
      24 => context.tr('daily'),
      72 => context.tr('days', {'value': 3}),
      168 => context.tr('weekly'),
      _ => context.tr('hours', {'value': value}),
    };
    return NozeltPopupMenuButton<int>(
      initialValue: menuValue,
      onSelected: onChanged,
      itemBuilder: (context) =>
          [
                (1, context.tr('hours', {'value': 1})),
                (6, context.tr('hours', {'value': 6})),
                (12, context.tr('hours', {'value': 12})),
                (24, context.tr('daily')),
                (72, context.tr('days', {'value': 3})),
                (168, context.tr('weekly')),
                (0, context.tr('never')),
                (-1, context.tr('custom')),
              ]
              .map(
                (entry) =>
                    PopupMenuItem<int>(value: entry.$1, child: Text(entry.$2)),
              )
              .toList(),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 7),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              label,
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                color: Theme.of(context).colorScheme.onSurface,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(width: 5),
            Icon(
              Icons.arrow_drop_down_rounded,
              size: 20,
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ],
        ),
      ),
    );
  }
}
