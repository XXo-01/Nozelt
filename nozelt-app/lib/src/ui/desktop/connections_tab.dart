import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/models.dart';
import '../../l10n/nozelt_l10n.dart';
import '../../state/engine_provider.dart';
import 'package:nozelt/nozelt_design_system.dart';
import 'process_icon.dart';

class DesktopConnectionsTab extends ConsumerStatefulWidget {
  const DesktopConnectionsTab({required this.isVisible, super.key});

  final bool isVisible;

  @override
  ConsumerState<DesktopConnectionsTab> createState() =>
      _DesktopConnectionsTabState();
}

class _DesktopConnectionsTabState extends ConsumerState<DesktopConnectionsTab> {
  final _searchController = TextEditingController();
  Timer? _timer;
  List<DesktopConnection> _connections = const [];
  bool _loading = false;
  bool _groupByProcess = true;

  @override
  void initState() {
    super.initState();
    if (widget.isVisible) _start();
  }

  @override
  void didUpdateWidget(covariant DesktopConnectionsTab oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.isVisible != oldWidget.isVisible) {
      widget.isVisible ? _start() : _stop();
    }
  }

  @override
  void dispose() {
    _stop();
    _searchController.dispose();
    super.dispose();
  }

  void _start() {
    _timer?.cancel();
    _refresh();
    _timer = Timer.periodic(const Duration(seconds: 1), (_) => _refresh());
  }

  void _stop() {
    _timer?.cancel();
    _timer = null;
  }

  Future<void> _refresh() async {
    if (_loading || !mounted || !widget.isVisible) return;
    _loading = true;
    try {
      final values = await ref.read(nozeltEngineProvider).getConnections();
      if (mounted) setState(() => _connections = values);
    } catch (_) {
      // The core can disappear while a stop operation is in progress. The
      // next one-second refresh will recover without surfacing noisy errors.
    } finally {
      _loading = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    final query = _searchController.text.trim().toLowerCase();
    final filtered = query.isEmpty
        ? _connections
        : _connections
              .where((item) {
                return '${item.host} ${item.destination} ${item.process} '
                        '${item.network} ${item.rule} ${item.chains.join(' ')}'
                    .toLowerCase()
                    .contains(query);
              })
              .toList(growable: false);

    final textScale = MediaQuery.textScalerOf(context).scale(14) / 14;
    final toolbarHeight = 38.0 + (textScale - 1).clamp(0, 2).toDouble() * 12;
    final search = TextField(
      controller: _searchController,
      style: const TextStyle(fontSize: 14, height: 1.2),
      onChanged: (_) => setState(() {}),
      decoration: nozeltSearchDecoration(
        context,
        InputDecoration(
          isDense: true,
          contentPadding: const EdgeInsets.symmetric(
            horizontal: 12,
            vertical: 6,
          ),
          prefixIconConstraints: BoxConstraints(
            minWidth: 38,
            minHeight: toolbarHeight,
          ),
          suffixIconConstraints: BoxConstraints(
            minWidth: 38,
            minHeight: toolbarHeight,
          ),
          hintText: context.tr('search'),
          prefixIcon: const Icon(Icons.search_rounded, size: 20),
          suffixIcon: query.isEmpty
              ? null
              : IconButton(
                  tooltip: context.tr('clearSearch'),
                  onPressed: () {
                    _searchController.clear();
                    setState(() {});
                  },
                  icon: const Icon(Icons.close_rounded),
                ),
        ),
      ),
    );
    final grouping = NozeltSegmentedControl<bool>(
      size: NozeltControlSize.compact,
      allowVertical: false,
      segments: [
        ButtonSegment(
          value: true,
          label: Text(
            context.tr('byProcess'),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ),
        ButtonSegment(
          value: false,
          label: Text(
            context.tr('connectionDetails'),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ),
      ],
      value: _groupByProcess,
      onChanged: (value) => setState(() => _groupByProcess = value),
    );
    return NozeltPageInsets(
      builder: (context, insets) {
        final side = EdgeInsets.only(left: insets.left, right: insets.right);
        return Padding(
          padding: EdgeInsets.only(top: insets.top),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: side,
                child: NozeltPageHeader(
                  title: context.tr('desktopConnectionsTab'),
                  subtitle: context.tr('connectionsSubtitle'),
                  trailing: OutlinedButton.icon(
                    onPressed: _connections.isEmpty ? null : _closeAll,
                    icon: const Icon(Icons.close_rounded),
                    label: Text(context.tr('closeAll')),
                  ),
                ),
              ),
              const SizedBox(height: NozeltSpacing.xl),
              Padding(
                padding: side,
                child: LayoutBuilder(
                  builder: (context, constraints) {
                    return Row(
                      children: [
                        Expanded(
                          child: SizedBox(height: toolbarHeight, child: search),
                        ),
                        const SizedBox(width: 12),
                        SizedBox(
                          width: (310 * textScale).clamp(
                            0,
                            constraints.maxWidth * 0.62,
                          ),
                          height: toolbarHeight,
                          child: grouping,
                        ),
                      ],
                    );
                  },
                ),
              ),
              const SizedBox(height: NozeltSpacing.md),
              Expanded(
                child: filtered.isEmpty
                    ? _EmptyConnections(hasFilter: query.isNotEmpty)
                    : _groupByProcess
                    ? _ProcessConnections(
                        connections: filtered,
                        padding: side.copyWith(bottom: insets.bottom),
                      )
                    : ListView.separated(
                        padding: side.copyWith(bottom: insets.bottom),
                        itemCount: filtered.length,
                        separatorBuilder: (_, _) => const SizedBox(height: 8),
                        itemBuilder: (context, index) => _ConnectionRow(
                          connection: filtered[index],
                          onClose: () => _close(filtered[index].id),
                        ),
                      ),
              ),
            ],
          ),
        );
      },
    );
  }

  Future<void> _close(String id) async {
    await ref.read(nozeltEngineProvider).closeConnection(id);
    await _refresh();
  }

  Future<void> _closeAll() async {
    await ref.read(nozeltEngineProvider).closeAllConnections();
    await _refresh();
  }
}

class _ProcessConnections extends StatelessWidget {
  const _ProcessConnections({required this.connections, required this.padding});
  final List<DesktopConnection> connections;
  final EdgeInsets padding;

  @override
  Widget build(BuildContext context) {
    final groups = <String, List<DesktopConnection>>{};
    for (final connection in connections) {
      (groups[connection.process.isEmpty ? '—' : connection.process] ??= [])
          .add(connection);
    }
    final entries = groups.entries.toList()
      ..sort((a, b) => a.key.compareTo(b.key));
    return ListView.separated(
      padding: padding,
      itemCount: entries.length,
      separatorBuilder: (_, _) => const SizedBox(height: 8),
      itemBuilder: (context, index) {
        final group = entries[index];
        final upload = group.value.fold<int>(
          0,
          (sum, value) => sum + value.upload,
        );
        final download = group.value.fold<int>(
          0,
          (sum, value) => sum + value.download,
        );
        return NozeltSurface(
          key: ValueKey(group.key),
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 2),
          child: ExpansionTile(
            key: PageStorageKey('process-${group.key}'),
            shape: const Border(),
            collapsedShape: const Border(),
            tilePadding: EdgeInsets.zero,
            minTileHeight: 56,
            dense: true,
            visualDensity: const VisualDensity(vertical: -2),
            childrenPadding: const EdgeInsets.only(bottom: 8),
            leading: ProcessIcon(group.key),
            title: Tooltip(
              message: group.key,
              child: Text(
                group.key,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            subtitle: Text(
              '${context.tr('activeProcessConnections', {'count': group.value.length})}  ·  ↓ ${_bytes(context, download)}  ↑ ${_bytes(context, upload)}',
              style: TextStyle(
                fontSize: 12,
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
            children: [
              for (final connection in group.value)
                ListTile(
                  dense: true,
                  title: Text(
                    connection.host.isEmpty
                        ? connection.destination
                        : connection.host,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  subtitle: Text(
                    '${connection.network.toUpperCase()} · ${connection.chains.join(' → ')} · ${connection.rule}',
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                  trailing: Text(
                    '↓ ${_bytes(context, connection.download)}\n↑ ${_bytes(context, connection.upload)}',
                  ),
                ),
            ],
          ),
        );
      },
    );
  }
}

class _EmptyConnections extends StatelessWidget {
  const _EmptyConnections({required this.hasFilter});

  final bool hasFilter;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.hub_outlined,
            size: 44,
            color: Theme.of(context).colorScheme.onSurfaceVariant,
          ),
          const SizedBox(height: 12),
          Text(
            hasFilter
                ? context.tr('noSearchResults')
                : context.tr('noConnections'),
            style: Theme.of(context).textTheme.titleMedium,
          ),
          if (!hasFilter) ...[
            const SizedBox(height: 5),
            Text(
              context.tr('noConnectionsHint'),
              style: TextStyle(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _ConnectionRow extends StatelessWidget {
  const _ConnectionRow({required this.connection, required this.onClose});

  final DesktopConnection connection;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    final target = connection.host.isNotEmpty
        ? connection.host
        : connection.destination;
    final process = connection.process.isEmpty ? '—' : connection.process;
    final chain = connection.chains.isEmpty
        ? 'DIRECT'
        : connection.chains.join(' → ');

    return NozeltSurface(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final icon = Container(
            width: 40,
            height: 40,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: Theme.of(
                context,
              ).colorScheme.primary.withValues(alpha: 0.1),
              borderRadius: BorderRadius.circular(13),
            ),
            child: Icon(
              Icons.language_rounded,
              color: Theme.of(context).colorScheme.primary,
              size: 20,
            ),
          );
          final close = IconButton(
            tooltip: context.tr('closeConnection'),
            onPressed: onClose,
            icon: const Icon(Icons.close_rounded, size: 19),
          );
          if (constraints.maxWidth < 720) {
            final rule = connection.rulePayload.isEmpty
                ? connection.rule
                : '${connection.rule}: ${connection.rulePayload}';
            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    icon,
                    const SizedBox(width: 13),
                    Expanded(
                      child: _Cell(
                        title: target,
                        subtitle: connection.destination,
                        padding: EdgeInsets.zero,
                      ),
                    ),
                    close,
                  ],
                ),
                const SizedBox(height: 10),
                Wrap(
                  spacing: 7,
                  runSpacing: 7,
                  children: [
                    _ConnectionTag(icon: Icons.apps_rounded, value: process),
                    _ConnectionTag(
                      icon: Icons.swap_horiz_rounded,
                      value: connection.network.toUpperCase(),
                    ),
                    _ConnectionTag(icon: Icons.route_rounded, value: chain),
                    if (rule.isNotEmpty)
                      _ConnectionTag(icon: Icons.rule_rounded, value: rule),
                    _ConnectionTag(
                      icon: Icons.south_rounded,
                      value: _bytes(context, connection.download),
                    ),
                    _ConnectionTag(
                      icon: Icons.north_rounded,
                      value: _bytes(context, connection.upload),
                    ),
                  ],
                ),
              ],
            );
          }
          return Row(
            children: [
              icon,
              const SizedBox(width: 13),
              Expanded(
                flex: 4,
                child: _Cell(title: target, subtitle: connection.destination),
              ),
              Expanded(
                flex: 3,
                child: _Cell(
                  title: process,
                  subtitle: connection.network.toUpperCase(),
                ),
              ),
              Expanded(
                flex: 3,
                child: _Cell(
                  title: chain,
                  subtitle: connection.rulePayload.isEmpty
                      ? connection.rule
                      : '${connection.rule}: ${connection.rulePayload}',
                ),
              ),
              Expanded(
                flex: 2,
                child: _Cell(
                  title: '↓ ${_bytes(context, connection.download)}',
                  subtitle: '↑ ${_bytes(context, connection.upload)}',
                ),
              ),
              close,
            ],
          );
        },
      ),
    );
  }
}

class _Cell extends StatelessWidget {
  const _Cell({
    required this.title,
    required this.subtitle,
    this.padding = const EdgeInsets.only(right: 16),
  });

  final String title;
  final String subtitle;
  final EdgeInsets padding;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: '$title\n$subtitle',
      child: Padding(
        padding: padding,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 3),
            Text(
              subtitle,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
                fontSize: 12,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ConnectionTag extends StatelessWidget {
  const _ConnectionTag({required this.icon, required this.value});

  final IconData icon;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Container(
      constraints: const BoxConstraints(maxWidth: 280),
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 6),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: Theme.of(context).colorScheme.outlineVariant),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            icon,
            size: 14,
            color: Theme.of(context).colorScheme.onSurfaceVariant,
          ),
          const SizedBox(width: 6),
          Flexible(
            child: Text(
              value,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 12),
            ),
          ),
        ],
      ),
    );
  }
}

String _bytes(BuildContext context, int bytes) {
  final russian = context.l10n.isRussian;
  final units = russian
      ? const ['Б', 'КБ', 'МБ', 'ГБ']
      : const ['B', 'KB', 'MB', 'GB'];
  var value = bytes.toDouble();
  var index = 0;
  while (value >= 1024 && index < units.length - 1) {
    value /= 1024;
    index++;
  }
  final number = value
      .toStringAsFixed(index == 0 ? 0 : 1)
      .replaceAll('.', russian ? ',' : '.');
  return '$number ${units[index]}';
}
