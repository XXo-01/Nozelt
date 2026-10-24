import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../l10n/nozelt_l10n.dart';
import '../l10n/user_error.dart';
import '../state/engine_provider.dart';
import 'widgets/nozelt_ui.dart';

class AlwaysOnVpnScreen extends ConsumerWidget {
  const AlwaysOnVpnScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
          tooltip: MaterialLocalizations.of(context).backButtonTooltip,
          onPressed: () => Navigator.of(context).pop(),
          icon: const Icon(Icons.arrow_back_rounded),
        ),
        title: FittedBox(
          fit: BoxFit.scaleDown,
          alignment: Alignment.centerLeft,
          child: Text(context.tr('alwaysOnVpn')),
        ),
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(20, 12, 20, 28),
        children: [
          NozeltSurface(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  context.tr('alwaysOnVpnIntro'),
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                const SizedBox(height: 18),
                _InstructionStep(
                  number: 1,
                  title: context.tr('alwaysOnVpnStep1Title'),
                  description: context.tr('alwaysOnVpnStep1Description'),
                ),
                const SizedBox(height: 16),
                _InstructionStep(
                  number: 2,
                  title: context.tr('alwaysOnVpnStep2Title'),
                  description: context.tr('alwaysOnVpnStep2Description'),
                ),
                const SizedBox(height: 16),
                _InstructionStep(
                  number: 3,
                  title: context.tr('alwaysOnVpnStep3Title'),
                  description: context.tr('alwaysOnVpnStep3Description'),
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),
          SizedBox(
            width: double.infinity,
            child: FilledButton.icon(
              onPressed: () => _openSettings(context, ref),
              icon: const Icon(Icons.open_in_new_rounded),
              label: Text(context.tr('openAndroidVpnSettings')),
            ),
          ),
          const SizedBox(height: 12),
          Text(
            context.tr('alwaysOnVpnFootnote'),
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _openSettings(BuildContext context, WidgetRef ref) async {
    try {
      await ref.read(nozeltEngineProvider).openVpnSettings();
    } catch (error) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(localizedUserError(context.l10n, error))),
      );
    }
  }
}

class _InstructionStep extends StatelessWidget {
  const _InstructionStep({
    required this.number,
    required this.title,
    required this.description,
  });

  final int number;
  final String title;
  final String description;

  @override
  Widget build(BuildContext context) => Row(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Container(
        width: 32,
        height: 32,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.primary.withValues(alpha: 0.13),
          borderRadius: BorderRadius.circular(11),
        ),
        child: Text(
          number.toString(),
          style: TextStyle(
            color: Theme.of(context).colorScheme.primary,
            fontWeight: FontWeight.w800,
          ),
        ),
      ),
      const SizedBox(width: 12),
      Expanded(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title, style: Theme.of(context).textTheme.titleSmall),
            const SizedBox(height: 3),
            Text(
              description,
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
                height: 1.35,
              ),
            ),
          ],
        ),
      ),
    ],
  );
}
