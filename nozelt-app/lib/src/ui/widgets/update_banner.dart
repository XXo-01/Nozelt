import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:nozelt/nozelt_design_system.dart';

import '../../l10n/nozelt_l10n.dart';
import '../../state/app_update_provider.dart';

/// Offers a newer Nozelt from GitHub Releases. The main-screen banner can be
/// closed and carries the "don't offer updates" switch; the settings banner
/// stays while an update exists.
class UpdateBanner extends ConsumerWidget {
  const UpdateBanner({required this.dismissible, super.key});

  final bool dismissible;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final update = ref.watch(appUpdateProvider);
    final release = update.release;
    if (release == null) return const SizedBox.shrink();
    final notifier = ref.read(appUpdateProvider.notifier);
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final busy = update.busy;
    final progress = update.progress;

    final title = Text(
      context.tr('updateAvailable', {'version': release.version.toString()}),
      style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600),
    );
    final status = switch (update.phase) {
      UpdatePhase.downloading => Padding(
        padding: const EdgeInsets.only(top: NozeltSpacing.sm),
        child: Row(
          children: [
            Expanded(
              child: ClipRRect(
                borderRadius: BorderRadius.circular(999),
                child: LinearProgressIndicator(
                  value: progress,
                  minHeight: 4,
                  backgroundColor: scheme.outlineVariant.withValues(alpha: .55),
                  color: context.nozelt.glow,
                ),
              ),
            ),
            if (progress != null) ...[
              const SizedBox(width: NozeltSpacing.sm),
              Text(
                '${(progress * 100).floor()}%',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: scheme.onSurfaceVariant,
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
            ],
          ],
        ),
      ),
      UpdatePhase.failed when update.errorKey != null => Padding(
        padding: const EdgeInsets.only(top: NozeltSpacing.xs),
        child: Text(
          context.tr(update.errorKey!),
          style: theme.textTheme.bodySmall?.copyWith(color: scheme.error),
        ),
      ),
      _ => null,
    };
    final action = FilledButton(
      onPressed: busy ? null : notifier.update,
      child: busy && update.phase == UpdatePhase.installing
          ? const SizedBox.square(
              dimension: 18,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          : Text(
              context.tr(
                update.phase == UpdatePhase.awaitingPermission
                    ? 'updateInstall'
                    : 'appUpdateNow',
              ),
            ),
    );
    final close = dismissible
        ? IconButton(
            tooltip: context.tr('close'),
            onPressed: busy ? null : notifier.dismiss,
            icon: const Icon(Icons.close_rounded),
          )
        : null;

    return NozeltSurface(
      padding: const EdgeInsets.fromLTRB(
        NozeltSpacing.md,
        NozeltSpacing.md,
        NozeltSpacing.sm,
        NozeltSpacing.md,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          LayoutBuilder(
            builder: (context, constraints) {
              final badge = NozeltIconBadge(
                color: context.nozelt.glow,
                icon: const Icon(Icons.system_update_alt_rounded),
              );
              final text = Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [title, ?status],
              );
              // A phone puts the button under the text.
              if (constraints.maxWidth < 440) {
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.center,
                      children: [
                        badge,
                        const SizedBox(width: NozeltSpacing.md),
                        Expanded(child: text),
                        ?close,
                      ],
                    ),
                    const SizedBox(height: NozeltSpacing.md),
                    Padding(
                      padding: const EdgeInsets.only(right: NozeltSpacing.xs),
                      child: action,
                    ),
                  ],
                );
              }
              return Row(
                children: [
                  badge,
                  const SizedBox(width: NozeltSpacing.md),
                  Expanded(child: text),
                  const SizedBox(width: NozeltSpacing.md),
                  action,
                  if (close != null) ...[
                    const SizedBox(width: NozeltSpacing.xs),
                    close,
                  ] else
                    const SizedBox(width: NozeltSpacing.xs),
                ],
              );
            },
          ),
          if (dismissible)
            Padding(
              padding: const EdgeInsets.only(top: NozeltSpacing.xs),
              child: NozeltSwitchTile(
                contentPadding: const EdgeInsetsDirectional.only(
                  start: NozeltSpacing.xs,
                  end: NozeltSpacing.xs,
                ),
                title: Text(context.tr('updateDontOffer')),
                value: !update.offerUpdates,
                onChanged: busy
                    ? null
                    : (value) => notifier.setOfferUpdates(!value),
              ),
            ),
        ],
      ),
    );
  }
}

/// The closable banner on the main screen, with the space below it.
class MainUpdateBanner extends ConsumerWidget {
  const MainUpdateBanner({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final show = ref.watch(
      appUpdateProvider.select((state) => state.showMainBanner),
    );
    if (!show) return const SizedBox.shrink();
    return const Padding(
      padding: EdgeInsets.only(bottom: NozeltSpacing.md),
      child: UpdateBanner(dismissible: true),
    );
  }
}

/// The settings banner above the app version: shown while an update exists.
class SettingsUpdateBanner extends ConsumerWidget {
  const SettingsUpdateBanner({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final available = ref.watch(
      appUpdateProvider.select((state) => state.available),
    );
    if (!available) return const SizedBox.shrink();
    return const Padding(
      padding: EdgeInsets.only(bottom: NozeltSpacing.md),
      child: UpdateBanner(dismissible: false),
    );
  }
}
