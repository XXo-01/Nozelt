import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/app_info.dart';
import '../core/split_tunnel_settings.dart';
import '../l10n/nozelt_l10n.dart';
import '../l10n/user_error.dart';
import '../state/split_tunnel_provider.dart';
import 'design_system/nozelt_controls.dart';
import 'widgets/nozelt_ui.dart';

/// Per-app split-tunneling picker. Mode + selection persist immediately and
/// are coalesced into one fail-closed TUN replacement after editing pauses.
/// Nozelt UI traffic follows the selected policy; only mihomo's actual
/// outbound socket descriptors bypass the TUN.
class SplitTunnelScreen extends ConsumerStatefulWidget {
  const SplitTunnelScreen({super.key});

  @override
  ConsumerState<SplitTunnelScreen> createState() => _SplitTunnelScreenState();
}

class _SplitTunnelScreenState extends ConsumerState<SplitTunnelScreen> {
  String _query = '';
  bool _hideSystemApps = true;

  @override
  Widget build(BuildContext context) {
    final split = ref.watch(splitTunnelProvider);
    final notifier = ref.read(splitTunnelProvider.notifier);

    return Scaffold(
      appBar: AppBar(title: Text(context.tr('splitScreenTitle'))),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
            child: NozeltSegmentedControl<SplitMode>(
              allowVertical: false,
              segments: [
                ButtonSegment(
                  value: SplitMode.off,
                  label: Text(context.tr('allApps')),
                ),
                ButtonSegment(
                  value: SplitMode.allowed,
                  label: Text(context.tr('only')),
                ),
                ButtonSegment(
                  value: SplitMode.disallowed,
                  label: Text(context.tr('except')),
                ),
              ],
              value: split.mode,
              onChanged: notifier.setMode,
            ),
          ),
          if (split.mode == SplitMode.off)
            const Spacer()
          else
            Expanded(child: _appList(split)),
        ],
      ),
    );
  }

  Widget _appList(SplitTunnelSettings split) {
    final appsAsync = ref.watch(installedAppsProvider);
    return appsAsync.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (e, _) => Center(
        child: Text(
          context.tr('appsLoadError', {
            'error': localizedUserError(context.l10n, e),
          }),
        ),
      ),
      data: (apps) {
        final filtered = filterAndSortSplitTunnelApps(
          apps: apps,
          selected: split.apps,
          query: _query,
          hideSystemApps: _hideSystemApps,
        );
        return Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 10),
              child: NozeltSurface(
                padding: EdgeInsets.zero,
                child: SwitchListTile(
                  contentPadding: const EdgeInsets.fromLTRB(16, 4, 12, 4),
                  secondary: Icon(
                    Icons.visibility_off_outlined,
                    color: Theme.of(context).colorScheme.primary,
                  ),
                  title: Text(context.tr('hideSystemApps')),
                  value: _hideSystemApps,
                  onChanged: (value) {
                    setState(() => _hideSystemApps = value);
                  },
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
              child: TextField(
                decoration: InputDecoration(
                  isDense: true,
                  prefixIcon: const Icon(Icons.search),
                  hintText: context.tr('searchApps'),
                  border: const OutlineInputBorder(),
                ),
                onChanged: (v) => setState(() => _query = v),
              ),
            ),
            Expanded(
              child: ListView.builder(
                itemCount: filtered.length,
                itemBuilder: (context, i) => _AppRow(
                  key: ValueKey(filtered[i].packageName),
                  app: filtered[i],
                  selected: split.apps,
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}

/// Applies the picker visibility rules and keeps selected applications at the
/// top. Selected system applications stay visible while the system-app filter
/// is enabled so an active rule can always be reviewed and removed.
List<AppInfo> filterAndSortSplitTunnelApps({
  required List<AppInfo> apps,
  required Set<String> selected,
  required String query,
  required bool hideSystemApps,
}) {
  final normalizedQuery = query.trim().toLowerCase();
  final visible = apps.where((app) {
    final isSelected = selected.contains(app.packageName);
    if (hideSystemApps && app.system && !isSelected) return false;
    return normalizedQuery.isEmpty ||
        app.label.toLowerCase().contains(normalizedQuery) ||
        app.packageName.toLowerCase().contains(normalizedQuery);
  }).toList();

  visible.sort((left, right) {
    final leftSelected = selected.contains(left.packageName);
    final rightSelected = selected.contains(right.packageName);
    if (leftSelected != rightSelected) return leftSelected ? -1 : 1;
    final byLabel = left.label.toLowerCase().compareTo(
      right.label.toLowerCase(),
    );
    return byLabel != 0
        ? byLabel
        : left.packageName.compareTo(right.packageName);
  });
  return visible;
}

/// One app row with a lazily-loaded icon. The icon provider only fires when
/// the row scrolls into view (ListView.builder), and its result is cached by
/// the `.family` provider so scroll-back is instant.
class _AppRow extends ConsumerWidget {
  const _AppRow({super.key, required this.app, required this.selected});

  final AppInfo app;
  final Set<String> selected;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final notifier = ref.read(splitTunnelProvider.notifier);
    final iconAsync = ref.watch(appIconProvider(app.packageName));

    return CheckboxListTile(
      controlAffinity: ListTileControlAffinity.trailing,
      secondary: SizedBox(
        width: 40,
        height: 40,
        child: iconAsync.maybeWhen(
          data: (bytes) => bytes == null
              ? const Icon(Icons.android)
              : Image.memory(
                  bytes,
                  width: 40,
                  height: 40,
                  gaplessPlayback: true,
                ),
          orElse: () => const Icon(Icons.android),
        ),
      ),
      title: Text(app.label, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: Text(
        app.packageName,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      value: selected.contains(app.packageName),
      onChanged: (v) => notifier.toggleApp(app.packageName, v ?? false),
    );
  }
}
