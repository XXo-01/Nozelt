import 'package:flutter/material.dart';

import '../../core/models.dart';
import '../../core/tun_settings.dart';
import '../../l10n/nozelt_l10n.dart';
import '../design_system/nozelt_controls.dart';
import '../design_system/nozelt_tokens.dart';
import 'country_flag.dart';
import 'nozelt_ui.dart';

/// Home cards shared by the Android and Windows home pages: the selected
/// server, the routing mode switch and the traffic tiles.
class NozeltCurrentProxyCard extends StatelessWidget {
  const NozeltCurrentProxyCard({
    super.key,
    required this.profileName,
    required this.nodeName,
    required this.flag,
    required this.onTap,
  });

  final String? profileName;
  final String? nodeName;
  final String? flag;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return NozeltSurface(
      onTap: onTap,
      padding: const EdgeInsets.all(NozeltSpacing.md),
      child: Row(
        children: [
          NozeltIconBadge(
            size: 44,
            color: nozeltIconAccent(context),
            icon: CountryFlag(flag ?? '🌐', size: 28),
          ),
          const SizedBox(width: NozeltSpacing.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  nodeName ?? context.tr('profileNotSelected'),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  profileName ?? context.tr('addProfileHint'),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: NozeltSpacing.lg),
          Icon(
            Icons.chevron_right_rounded,
            color: Theme.of(context).colorScheme.onSurfaceVariant,
          ),
        ],
      ),
    );
  }
}

class NozeltRoutingModeCard extends StatelessWidget {
  const NozeltRoutingModeCard({
    required this.selected,
    required this.onSelected,
    super.key,
  });

  final RoutingMode selected;
  final ValueChanged<RoutingMode> onSelected;

  @override
  Widget build(BuildContext context) {
    return NozeltSurface(
      padding: const EdgeInsets.all(NozeltSpacing.md),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              NozeltIconBadge(
                color: nozeltIconAccent(context),
                icon: const Icon(Icons.route_rounded),
              ),
              const SizedBox(width: NozeltSpacing.md),
              Text(
                context.tr('routing'),
                style: Theme.of(context).textTheme.titleMedium,
              ),
            ],
          ),
          const SizedBox(height: NozeltSpacing.md),
          NozeltSegmentedControl<RoutingMode>(
            segments: [
              ButtonSegment(
                value: RoutingMode.global,
                icon: const Icon(Icons.public_rounded),
                label: Text(context.tr('globalMode')),
              ),
              ButtonSegment(
                value: RoutingMode.rule,
                icon: const Icon(Icons.rule_rounded),
                label: Text(context.tr('ruleMode')),
              ),
            ],
            value: selected,
            onChanged: onSelected,
          ),
        ],
      ),
    );
  }
}

/// Download and upload side by side: the current speed on the left and the
/// session total on the right of each tile.
class NozeltTrafficRow extends StatelessWidget {
  const NozeltTrafficRow({required this.traffic, super.key});

  final Traffic traffic;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return LayoutBuilder(
      // A phone tile is too narrow for two values side by side, so the
      // session total moves under the speed.
      builder: (context, constraints) => _row(
        context,
        scheme,
        narrow: (constraints.maxWidth - NozeltSpacing.md) / 2 < 240,
      ),
    );
  }

  Widget _row(
    BuildContext context,
    ColorScheme scheme, {
    required bool narrow,
  }) {
    return IntrinsicHeight(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(
            child: _TrafficTile(
              icon: Icons.south_rounded,
              label: context.tr('download'),
              speed: nozeltFormatSpeed(context, traffic.downloadSpeedBps),
              total: nozeltFormatBytes(context, traffic.downloadBytes),
              color: context.nozelt.glow,
              narrow: narrow,
            ),
          ),
          const SizedBox(width: NozeltSpacing.md),
          Expanded(
            child: _TrafficTile(
              icon: Icons.north_rounded,
              label: context.tr('upload'),
              speed: nozeltFormatSpeed(context, traffic.uploadSpeedBps),
              total: nozeltFormatBytes(context, traffic.uploadBytes),
              color: scheme.secondary,
              narrow: narrow,
            ),
          ),
        ],
      ),
    );
  }
}

class _TrafficTile extends StatelessWidget {
  const _TrafficTile({
    required this.icon,
    required this.label,
    required this.speed,
    required this.total,
    required this.color,
    required this.narrow,
  });

  final IconData icon;
  final String label;
  final String speed;
  final String total;
  final Color color;
  final bool narrow;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    Widget metric(String caption, String value, CrossAxisAlignment align) =>
        Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: align,
          children: [
            Text(
              caption,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 2),
            FittedBox(
              fit: BoxFit.scaleDown,
              child: Text(
                value,
                maxLines: 1,
                style: theme.textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.w600,
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
            ),
          ],
        );
    return NozeltSurface(
      padding: const EdgeInsets.all(NozeltSpacing.md),
      child: Row(
        children: [
          NozeltIconBadge(color: color, icon: Icon(icon)),
          const SizedBox(width: NozeltSpacing.md),
          Expanded(
            child: narrow
                ? Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      metric(label, speed, CrossAxisAlignment.start),
                      const SizedBox(height: 2),
                      Text(
                        context.tr('total', {'value': total}),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.labelSmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  )
                : metric(label, speed, CrossAxisAlignment.start),
          ),
          if (!narrow) ...[
            const SizedBox(width: NozeltSpacing.md),
            metric(context.tr('totalLabel'), total, CrossAxisAlignment.end),
          ],
        ],
      ),
    );
  }
}

String nozeltFormatBytes(BuildContext context, int bytes) {
  final russian = context.l10n.isRussian;
  final units = russian
      ? const ['Б', 'КБ', 'МБ', 'ГБ', 'ТБ']
      : const ['B', 'KB', 'MB', 'GB', 'TB'];
  var value = bytes.toDouble();
  var index = 0;
  while (value >= 1024 && index < units.length - 1) {
    value /= 1024;
    index++;
  }
  final number = value
      .toStringAsFixed(index == 0 || value >= 100 ? 0 : 1)
      .replaceAll('.', russian ? ',' : '.');
  return '$number ${units[index]}';
}

String nozeltFormatSpeed(BuildContext context, int bytesPerSecond) =>
    '${nozeltFormatBytes(context, bytesPerSecond)}/${context.l10n.isRussian ? 'с' : 's'}';
