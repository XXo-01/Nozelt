import 'package:nozelt/nozelt_design_system.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/nozelt_l10n.dart';
import '../../state/node_health_provider.dart';
import '../../state/profiles_provider.dart';

class LatencyCard extends ConsumerWidget {
  const LatencyCard({
    required this.profileId,
    required this.nodeName,
    super.key,
  });

  final String? profileId;
  final String? nodeName;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final id = profileId;
    final name = nodeName;
    final health = ref.watch(
      nodeHealthProvider.select((state) {
        if (id == null || name == null) {
          return (testing: false, delay: null as NodeDelay?);
        }
        return (
          testing: state.isTesting(id, name),
          delay: state.delay(id, name),
        );
      }),
    );
    final milliseconds = health.delay?.milliseconds;

    return NozeltSurface(
      padding: Theme.of(context).platform == TargetPlatform.windows
          ? const EdgeInsets.fromLTRB(12, 12, 8, 12)
          : const EdgeInsets.fromLTRB(16, 10, 8, 10),
      child: Row(
        children: [
          if (Theme.of(context).platform == TargetPlatform.windows)
            // Windows home tiles put their icon in a tinted square.
            NozeltIconBadge(
              color: _latencyColor(context, milliseconds),
              icon: const Icon(Icons.speed_rounded),
            )
          else
            Icon(
              Icons.speed_rounded,
              color: _latencyColor(context, milliseconds),
            ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  context.tr('latency'),
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  _latencyLabel(context, health.delay),
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    color: _latencyColor(context, milliseconds),
                    fontFeatures: const [FontFeature.tabularFigures()],
                  ),
                ),
              ],
            ),
          ),
          IconButton(
            tooltip: context.tr('refreshPing'),
            style: nozeltOutlinedIconStyle(context),
            onPressed: id == null || name == null || health.testing
                ? null
                : () {
                    final active = ref.read(profilesProvider).value?.active;
                    if (active == null || active.id != id) return;
                    final node = active.selectedNode;
                    if (node == null || node.name != name) return;
                    ref
                        .read(nodeHealthProvider.notifier)
                        .pingNode(active, node);
                  },
            icon: health.testing
                ? const SizedBox.square(
                    dimension: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.refresh_rounded),
          ),
        ],
      ),
    );
  }

  static String _latencyLabel(BuildContext context, NodeDelay? delay) {
    if (delay?.milliseconds != null) {
      return context.tr('milliseconds', {'value': delay!.milliseconds!});
    }
    return delay == null
        ? context.tr('notMeasured')
        : context.tr('unavailable');
  }

  static Color _latencyColor(BuildContext context, int? delay) {
    if (delay == null) return Theme.of(context).colorScheme.onSurfaceVariant;
    if (delay < 180) return context.nozelt.success;
    if (delay < 450) return context.nozelt.warning;
    return Theme.of(context).colorScheme.error;
  }
}
