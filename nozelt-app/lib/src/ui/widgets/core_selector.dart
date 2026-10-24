import 'package:nozelt/nozelt_design_system.dart';
import 'package:flutter/material.dart';

import '../../core/vpn_core.dart';
import '../../l10n/nozelt_l10n.dart';

class CoreSelector extends StatelessWidget {
  const CoreSelector({
    required this.mode,
    required this.manualCore,
    required this.onModeChanged,
    required this.onManualCoreChanged,
    this.detectedCore,
    this.showAutomaticHint = true,
    super.key,
  });

  final ProfileCoreMode mode;
  final VpnCore manualCore;
  final VpnCore? detectedCore;
  final bool showAutomaticHint;
  final ValueChanged<ProfileCoreMode> onModeChanged;
  final ValueChanged<VpnCore> onManualCoreChanged;

  @override
  Widget build(BuildContext context) {
    final russian = context.l10n.isRussian;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          russian ? 'Ядро' : 'Core',
          style: Theme.of(context).textTheme.titleMedium,
        ),
        const SizedBox(height: 8),
        NozeltSegmentedControl<ProfileCoreMode>(
          segments: [
            ButtonSegment(
              value: ProfileCoreMode.automatic,
              icon: const Icon(Icons.auto_awesome_rounded),
              label: Text(russian ? 'Автоматически' : 'Automatic'),
            ),
            ButtonSegment(
              value: ProfileCoreMode.manual,
              icon: const Icon(Icons.tune_rounded),
              label: Text(russian ? 'Вручную' : 'Manual'),
            ),
          ],
          value: mode,
          onChanged: onModeChanged,
        ),
        const SizedBox(height: 10),
        if (mode == ProfileCoreMode.manual)
          NozeltDropdownField<VpnCore>(
            value: manualCore,
            label: russian ? 'Выбранное ядро' : 'Selected core',
            items: [
              for (final core in VpnCore.values)
                DropdownMenuItem(value: core, child: Text(core.displayName)),
            ],
            onChanged: (value) {
              if (value != null) onManualCoreChanged(value);
            },
          )
        else if (showAutomaticHint)
          Row(
            children: [
              const Icon(Icons.info_outline_rounded, size: 18),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  detectedCore == null
                      ? (russian
                            ? 'Формат будет определён при импорте'
                            : 'The format will be detected during import')
                      : (russian
                            ? 'Определено: ${detectedCore!.displayName}'
                            : 'Detected: ${detectedCore!.displayName}'),
                ),
              ),
            ],
          ),
      ],
    );
  }
}
