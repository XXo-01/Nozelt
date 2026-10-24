import 'package:nozelt/nozelt_design_system.dart';
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/models.dart';
import '../../l10n/nozelt_l10n.dart';
import '../../state/engine_provider.dart';

class DesktopLogsTab extends ConsumerStatefulWidget {
  const DesktopLogsTab({required this.isVisible, super.key});

  final bool isVisible;

  @override
  ConsumerState<DesktopLogsTab> createState() => _DesktopLogsTabState();
}

class _DesktopLogsTabState extends ConsumerState<DesktopLogsTab> {
  final _searchController = TextEditingController();
  final _scrollController = ScrollController();
  final List<LogEntry> _entries = [];
  StreamSubscription<LogEntry>? _subscription;
  String _level = 'all';

  @override
  void initState() {
    super.initState();
    if (widget.isVisible) _subscribe();
  }

  @override
  void didUpdateWidget(covariant DesktopLogsTab oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.isVisible != oldWidget.isVisible) {
      widget.isVisible ? _subscribe() : _unsubscribe();
    }
  }

  @override
  void dispose() {
    _unsubscribe();
    _searchController.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  void _subscribe() {
    _subscription?.cancel();
    _subscription = ref.read(nozeltEngineProvider).logsStream().listen((entry) {
      if (!mounted) return;
      setState(() {
        _entries.add(entry);
        if (_entries.length > 2000) {
          _entries.removeRange(0, _entries.length - 2000);
        }
      });
    });
  }

  void _unsubscribe() {
    _subscription?.cancel();
    _subscription = null;
  }

  @override
  Widget build(BuildContext context) {
    final query = _searchController.text.trim().toLowerCase();
    final filtered = _entries
        .where((entry) {
          final matchesLevel = _level == 'all' || entry.level == _level;
          return matchesLevel &&
              (query.isEmpty || entry.message.toLowerCase().contains(query));
        })
        .toList(growable: false);

    return NozeltPageInsets(
      builder: (context, insets) => Padding(
        padding: insets,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            NozeltPageHeader(
              title: context.tr('logsTab'),
              subtitle: context.tr('logsSubtitle'),
              trailing: OutlinedButton.icon(
                onPressed: _entries.isEmpty ? null : _clear,
                icon: const Icon(Icons.delete_sweep_rounded),
                label: Text(context.tr('clearLogs')),
              ),
            ),
            const SizedBox(height: 20),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _searchController,
                    style: const TextStyle(fontSize: 14, height: 1.2),
                    onChanged: (_) => setState(() {}),
                    decoration: nozeltSearchDecoration(
                      context,
                      InputDecoration(
                        contentPadding: const EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 6,
                        ),
                        prefixIconConstraints: const BoxConstraints(
                          minWidth: 38,
                          minHeight: 38,
                        ),
                        suffixIconConstraints: const BoxConstraints(
                          minWidth: 38,
                          minHeight: 38,
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
                  ),
                ),
                const SizedBox(width: 12),
                SizedBox(
                  width: 180,
                  child: NozeltDropdownField<String>(
                    textStyle: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      color: Theme.of(context).colorScheme.onSurface,
                    ),
                    value: _level,
                    decoration: nozeltSearchDecoration(
                      context,
                      const InputDecoration(
                        contentPadding: EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 6,
                        ),
                        prefixIconConstraints: BoxConstraints(
                          minWidth: 38,
                          minHeight: 38,
                        ),
                        prefixIcon: Icon(Icons.filter_list_rounded, size: 20),
                      ),
                    ),
                    items: [
                      DropdownMenuItem(
                        value: 'all',
                        child: Text(context.tr('allLevels')),
                      ),
                      const DropdownMenuItem(
                        value: 'debug',
                        child: Text('DEBUG'),
                      ),
                      const DropdownMenuItem(
                        value: 'info',
                        child: Text('INFO'),
                      ),
                      const DropdownMenuItem(
                        value: 'warning',
                        child: Text('WARNING'),
                      ),
                      const DropdownMenuItem(
                        value: 'error',
                        child: Text('ERROR'),
                      ),
                    ],
                    onChanged: (value) =>
                        setState(() => _level = value ?? 'all'),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 14),
            Expanded(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.surfaceContainerLow,
                  borderRadius: BorderRadius.circular(
                    context.nozelt.cardRadius,
                  ),
                  border: Border.all(
                    color: Theme.of(context).colorScheme.outlineVariant,
                  ),
                ),
                child: filtered.isEmpty
                    ? Center(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(
                              Icons.subject_rounded,
                              size: 40,
                              color: Theme.of(
                                context,
                              ).colorScheme.onSurfaceVariant,
                            ),
                            const SizedBox(height: 12),
                            Text(
                              context.tr(
                                query.isEmpty && _level == 'all'
                                    ? 'noLogs'
                                    : 'noSearchResults',
                              ),
                              style: Theme.of(context).textTheme.titleMedium
                                  ?.copyWith(
                                    color: Theme.of(
                                      context,
                                    ).colorScheme.onSurfaceVariant,
                                  ),
                            ),
                          ],
                        ),
                      )
                    : ListView.builder(
                        controller: _scrollController,
                        padding: const EdgeInsets.symmetric(vertical: 8),
                        itemCount: filtered.length,
                        itemBuilder: (context, index) =>
                            _LogLine(entry: filtered[index]),
                      ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _clear() async {
    await ref.read(nozeltEngineProvider).clearLogs();
    if (mounted) setState(_entries.clear);
  }
}

class _LogLine extends StatelessWidget {
  const _LogLine({required this.entry});

  final LogEntry entry;

  @override
  Widget build(BuildContext context) {
    final date = DateTime.fromMillisecondsSinceEpoch(
      entry.timestampMs,
    ).toLocal();
    final time =
        '${date.hour.toString().padLeft(2, '0')}:'
        '${date.minute.toString().padLeft(2, '0')}:'
        '${date.second.toString().padLeft(2, '0')}.${date.millisecond.toString().padLeft(3, '0')}';
    final color = switch (entry.level) {
      'error' => Theme.of(context).colorScheme.error,
      'warning' => context.nozelt.warning,
      'debug' => Theme.of(context).colorScheme.onSurfaceVariant,
      _ => Theme.of(context).colorScheme.primary,
    };

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 92 * MediaQuery.textScalerOf(context).scale(12) / 12,
            child: Text(
              time,
              maxLines: 1,
              style: TextStyle(
                fontFamily: 'monospace',
                fontSize: 12,
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          ),
          SizedBox(
            width: 74 * MediaQuery.textScalerOf(context).scale(12) / 12,
            child: Text(
              entry.level.toUpperCase(),
              maxLines: 1,
              style: TextStyle(
                fontFamily: 'monospace',
                fontSize: 12,
                color: color,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
          Expanded(
            child: SelectableText(
              entry.message,
              style: const TextStyle(
                fontFamily: 'monospace',
                fontSize: 12.5,
                height: 1.35,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
