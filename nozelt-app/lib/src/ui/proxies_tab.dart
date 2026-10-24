import 'package:nozelt/nozelt_design_system.dart';
import 'package:flutter/foundation.dart';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/models.dart';
import '../core/profile.dart';
import '../core/proxy_node.dart';
import '../l10n/nozelt_l10n.dart';
import '../l10n/user_error.dart';
import '../state/engine_provider.dart';
import '../state/node_health_provider.dart';
import '../state/nozelt_auto_provider.dart';
import '../state/profiles_provider.dart';
import 'add_profile_screen.dart';
import 'widgets/country_flag.dart';
import 'proxy_settings_screen.dart';
import 'widgets/auto_update_interval_field.dart';
import 'widgets/core_selector.dart';

class ProxiesTab extends ConsumerStatefulWidget {
  const ProxiesTab({this.isVisible = true, super.key});

  final bool isVisible;

  @override
  ConsumerState<ProxiesTab> createState() => _ProxiesTabState();
}

class _ProxiesTabState extends ConsumerState<ProxiesTab> {
  final Set<String> _refreshingProfiles = {};
  final Set<String> _collapsedProfiles = {};

  @override
  Widget build(BuildContext context) {
    if (!widget.isVisible) return const SizedBox.shrink();
    final profilesAsync = ref.watch(profilesProvider);

    return SafeArea(
      bottom: false,
      child: profilesAsync.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (error, _) => _ErrorState(
          message: localizedUserError(context.l10n, error),
          onRetry: () => ref.invalidate(profilesProvider),
        ),
        data: (state) => _buildContent(context, state),
      ),
    );
  }

  Widget _buildContent(BuildContext context, ProfilesState state) {
    final desktop = defaultTargetPlatform == TargetPlatform.windows;
    final orderedProfiles = <Profile>[
      ...state.profiles.where((profile) => profile.pinned),
      ...state.profiles.where((profile) => !profile.pinned),
    ];
    final entries = <_ProfileListEntry>[];
    for (final profile in orderedProfiles) {
      final expanded = !_collapsedProfiles.contains(profile.id);
      entries.add(_ProfileListEntry.header(profile, expanded: expanded));
      if (expanded) {
        // Nozelt's own auto server leads the list when it is turned on.
        if (profile.supportsNozeltAuto) {
          entries.add(
            _ProfileListEntry.node(profile, _autoEntryNode, last: false),
          );
        }
        for (var index = 0; index < profile.nodes.length; index++) {
          entries.add(
            _ProfileListEntry.node(
              profile,
              profile.nodes[index],
              last: index == profile.nodes.length - 1,
            ),
          );
        }
      }
    }

    Widget list(EdgeInsets insets) => CustomScrollView(
      key: const PageStorageKey<String>('proxies-scroll'),
      physics: desktop
          ? const ClampingScrollPhysics()
          : const BouncingScrollPhysics(),
      slivers: [
        SliverPadding(
          padding: desktop
              ? insets.copyWith(bottom: 0)
              : const EdgeInsets.fromLTRB(20, 18, 20, 0),
          sliver: SliverList(
            delegate: SliverChildListDelegate([
              NozeltPageHeader(
                title: context.tr('proxiesTab'),
                trailing: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    FilledButton.icon(
                      onPressed: _addProfile,
                      icon: const Icon(Icons.add_rounded, size: 20),
                      label: Text(context.tr('addProfile')),
                    ),
                  ],
                ),
              ),
              SizedBox(height: desktop ? NozeltSpacing.xxl : 22),
              if (state.profiles.isEmpty) _EmptyProfiles(onAdd: _addProfile),
            ]),
          ),
        ),
        if (entries.isNotEmpty)
          SliverPadding(
            padding: desktop
                ? EdgeInsets.only(left: insets.left, right: insets.right)
                : const EdgeInsets.symmetric(horizontal: 20),
            sliver: SliverList.builder(
              itemCount: entries.length,
              itemBuilder: (context, index) {
                final entry = entries[index];
                final profile = entry.profile;
                final expanded = entry.expanded;
                final active = profile.id == state.activeId;
                final isHeader = entry.node == null;
                final closesFrame = isHeader
                    ? !expanded || profile.nodes.isEmpty
                    : entry.last;

                return _ProfileFrameSegment(
                  top: isHeader,
                  bottom: closesFrame,
                  active: active,
                  child: isHeader
                      ? _ProfileOverviewCard(
                          profile: profile,
                          active: active,
                          expanded: expanded,
                          refreshing: _refreshingProfiles.contains(profile.id),
                          onToggleExpanded: () {
                            setState(() {
                              if (expanded) {
                                _collapsedProfiles.add(profile.id);
                              } else {
                                _collapsedProfiles.remove(profile.id);
                              }
                            });
                          },
                          onRefresh:
                              profile.isSubscription &&
                                  !_refreshingProfiles.contains(profile.id)
                              ? () => _refresh(profile)
                              : null,
                          onSettings: () => _showProfileActions(profile),
                          onAction: (action) => _profileAction(profile, action),
                          onTelegram:
                              profile.subscriptionMetadata?.telegramUrl == null
                              ? null
                              : () => _openExternalUrl(
                                  profile.subscriptionMetadata!.telegramUrl!,
                                ),
                        )
                      : Padding(
                          padding: EdgeInsets.fromLTRB(
                            9,
                            0,
                            9,
                            closesFrame ? 9 : 2,
                          ),
                          child: entry.node!.name == Profile.nozeltAutoId
                              ? _NodeTile(
                                  profileId: profile.id,
                                  node: entry.node!,
                                  autoPick: profile.autoPick,
                                  selected: active && profile.autoSelected,
                                  onTap: () =>
                                      _selectNode(profile, entry.node!),
                                  onPing: active && profile.autoSelected
                                      ? () => ref
                                            .read(
                                              nozeltAutoServerProvider.notifier,
                                            )
                                            .evaluate()
                                      : () => ref
                                            .read(nodeHealthProvider.notifier)
                                            .pingAll(profile),
                                  onSettings: null,
                                )
                              : _NodeTile(
                                  profileId: profile.id,
                                  node: entry.node!,
                                  selected:
                                      active &&
                                      !profile.autoSelected &&
                                      profile.effectiveSelectedNodeName ==
                                          entry.node!.name,
                                  onTap: () =>
                                      _selectNode(profile, entry.node!),
                                  onPing: () => ref
                                      .read(nodeHealthProvider.notifier)
                                      .pingNode(profile, entry.node!),
                                  onSettings: () =>
                                      _editNode(profile, entry.node!),
                                ),
                        ),
                );
              },
            ),
          ),
        SliverToBoxAdapter(
          child: SizedBox(height: desktop ? insets.bottom : 124),
        ),
      ],
    );
    return desktop
        ? NozeltPageInsets(builder: (context, insets) => list(insets))
        : list(EdgeInsets.zero);
  }

  Future<void> _selectNode(Profile profile, ProxyNode node) async {
    final wasConnected =
        ref.read(engineStateProvider).connection ==
        EngineConnectionState.connected;
    try {
      final profiles = ref.read(profilesProvider).value;
      final notifier = ref.read(profilesProvider.notifier);
      // Persist the node first while the profile is inactive, then activate
      // it. A connected VPN therefore performs one fail-closed profile
      // replacement already containing the requested node.
      await notifier.setSelectedNode(profile.id, node.name);
      if (profiles?.activeId != profile.id) {
        await notifier.setActive(profile.id);
      }
      if (mounted && wasConnected) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(context.tr('nodeSwitched'))));
      }
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(localizedUserError(context.l10n, error))),
      );
    }
  }

  Future<void> _refresh(Profile profile) async {
    setState(() => _refreshingProfiles.add(profile.id));
    try {
      await ref.read(profilesProvider.notifier).refresh(profile.id);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(context.tr('subscriptionUpdated'))),
        );
      }
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              context.tr('refreshError', {
                'error': localizedUserError(context.l10n, error),
              }),
            ),
          ),
        );
      }
    } finally {
      if (mounted) {
        setState(() => _refreshingProfiles.remove(profile.id));
      }
    }
  }

  Future<void> _editNode(Profile profile, ProxyNode node) async {
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => ProxySettingsScreen(profile: profile, node: node),
      ),
    );
  }

  Future<void> _openExternalUrl(String url) async {
    try {
      await ref.read(nozeltEngineProvider).openExternalUrl(url);
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(localizedUserError(context.l10n, error))),
      );
    }
  }

  Future<void> _showProfileActions(Profile profile) async {
    final action = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: Theme.of(context).colorScheme.surfaceContainerHighest,
      showDragHandle: true,
      builder: (sheetContext) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(10, 0, 10, 12),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ListTile(
                leading: Icon(
                  profile.pinned
                      ? Icons.push_pin_outlined
                      : Icons.push_pin_rounded,
                  color: profile.pinned
                      ? Theme.of(context).colorScheme.onSurfaceVariant
                      : Theme.of(context).colorScheme.primary,
                ),
                title: Text(
                  context.tr(profile.pinned ? 'unpinProfile' : 'pinProfile'),
                ),
                onTap: () => Navigator.pop(sheetContext, 'pin'),
              ),
              ListTile(
                leading: const Icon(Icons.edit_rounded),
                title: Text(context.tr('editProfile')),
                onTap: () => Navigator.pop(sheetContext, 'edit'),
              ),
              ListTile(
                leading: Icon(
                  Icons.delete_outline_rounded,
                  color: Theme.of(context).colorScheme.error,
                ),
                title: Text(
                  context.tr('delete'),
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
                onTap: () => Navigator.pop(sheetContext, 'delete'),
              ),
            ],
          ),
        ),
      ),
    );
    if (!mounted) return;
    await _profileAction(profile, action);
  }

  Future<void> _profileAction(Profile profile, String? action) async {
    switch (action) {
      case 'pin':
        await ref.read(profilesProvider.notifier).togglePinned(profile.id);
      case 'edit':
        await _editProfile(profile);
      case 'delete':
        await _deleteProfile(profile);
    }
  }

  Future<void> _editProfile(Profile profile) async {
    final controller = TextEditingController(text: profile.name);
    var autoUpdateMinutes = profile.autoUpdateMinutes;
    var coreMode = profile.coreMode;
    var manualCore = profile.manualCore;
    var nozeltAuto = profile.nozeltAuto;
    final accepted = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: Text(context.tr('editProfile')),
          content: NozeltDialogBody(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  controller: controller,
                  inputFormatters: [
                    LengthLimitingTextInputFormatter(maxProfileNameRunes),
                  ],
                  decoration: InputDecoration(labelText: context.tr('name')),
                ),
                if (profile.isSubscription) ...[
                  const SizedBox(height: 16),
                  AutoUpdateIntervalField(
                    valueMinutes: autoUpdateMinutes,
                    onChanged: (value) =>
                        setDialogState(() => autoUpdateMinutes = value),
                  ),
                ],
                const SizedBox(height: 16),
                CoreSelector(
                  mode: coreMode,
                  manualCore: manualCore,
                  detectedCore: profile.detectedCore,
                  onModeChanged: (value) =>
                      setDialogState(() => coreMode = value),
                  onManualCoreChanged: (value) =>
                      setDialogState(() => manualCore = value),
                ),
                // Works on every core; it needs at least two servers.
                if (profile.nodes.length >= 2) ...[
                  const SizedBox(height: 8),
                  NozeltSwitchTile(
                    contentPadding: EdgeInsets.zero,
                    title: Text(context.tr('nozeltAutoServer')),
                    value: nozeltAuto,
                    onChanged: (value) =>
                        setDialogState(() => nozeltAuto = value),
                  ),
                ],
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext, false),
              child: Text(context.tr('cancel')),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(dialogContext, true),
              child: Text(context.tr('save')),
            ),
          ],
        ),
      ),
    );
    final name = controller.text.trim();
    controller.dispose();
    if (accepted != true || name.isEmpty || !mounted) return;
    try {
      await ref
          .read(profilesProvider.notifier)
          .updateDetails(
            profile.id,
            name: name,
            autoUpdateMinutes: autoUpdateMinutes,
            coreMode: coreMode,
            manualCore: manualCore,
            nozeltAuto: nozeltAuto,
          );
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(localizedUserError(context.l10n, error))),
      );
    }
  }

  Future<void> _deleteProfile(Profile profile) async {
    final confirmed =
        await showDialog<bool>(
          context: context,
          builder: (dialogContext) => AlertDialog(
            title: Text(context.tr('deleteProfile')),
            content: Text(
              context.tr('deleteProfileHint', {'name': profile.name}),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(dialogContext, false),
                child: Text(context.tr('cancel')),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(dialogContext, true),
                child: Text(context.tr('delete')),
              ),
            ],
          ),
        ) ??
        false;
    if (!confirmed || !mounted) return;
    try {
      await ref.read(profilesProvider.notifier).delete(profile.id);
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(localizedUserError(context.l10n, error))),
      );
    }
  }

  Future<void> _addProfile() => Navigator.of(
    context,
  ).push(MaterialPageRoute(builder: (_) => const AddProfileScreen()));
}

class _ProfileListEntry {
  const _ProfileListEntry.header(this.profile, {required this.expanded})
    : node = null,
      last = false;

  const _ProfileListEntry.node(this.profile, this.node, {required this.last})
    : expanded = true;

  final Profile profile;
  final ProxyNode? node;
  final bool expanded;
  final bool last;
}

class _ProfileFrameSegment extends StatelessWidget {
  const _ProfileFrameSegment({
    required this.top,
    required this.bottom,
    required this.active,
    required this.child,
  });

  final bool top;
  final bool bottom;
  final bool active;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final radius = BorderRadius.vertical(
      top: top ? Radius.circular(context.nozelt.cardRadius) : Radius.zero,
      bottom: bottom ? Radius.circular(context.nozelt.cardRadius) : Radius.zero,
    );
    return Padding(
      padding: EdgeInsets.only(bottom: bottom ? 14 : 0),
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.surface,
          borderRadius: radius,
          border: Border(
            left: BorderSide(
              color: Theme.of(context).colorScheme.outlineVariant,
              width: 0.8,
            ),
            right: BorderSide(
              color: Theme.of(context).colorScheme.outlineVariant,
              width: 0.8,
            ),
            top: top
                ? BorderSide(
                    color: Theme.of(context).colorScheme.outlineVariant,
                    width: 0.8,
                  )
                : BorderSide.none,
            bottom: bottom
                ? BorderSide(
                    color: Theme.of(context).colorScheme.outlineVariant,
                    width: 0.8,
                  )
                : BorderSide.none,
          ),
        ),
        child: ClipRRect(borderRadius: radius, child: child),
      ),
    );
  }
}

/// Placeholder row for Nozelt's auto server; it is never a real server.
final _autoEntryNode = ProxyNode.fromRaw(const {
  'name': Profile.nozeltAutoId,
  'type': 'auto',
});

class _NodeTile extends ConsumerWidget {
  const _NodeTile({
    required this.profileId,
    required this.node,
    required this.selected,
    required this.onTap,
    required this.onPing,
    required this.onSettings,
    this.autoPick,
  });

  final String profileId;
  final ProxyNode node;
  final bool selected;
  final VoidCallback onTap;
  final VoidCallback? onPing;
  final VoidCallback? onSettings;

  /// Set for the Nozelt auto server row: the server it currently uses.
  final ProxyNode? autoPick;

  bool get _auto => node.name == Profile.nozeltAutoId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // The auto row shows the latency of the server it currently uses.
    final measured = _auto ? autoPick?.name ?? '' : node.name;
    final evaluating = _auto && ref.watch(nozeltAutoServerProvider);
    final health = ref.watch(
      nodeHealthProvider.select(
        (state) => (
          testing: _auto
              ? state.isTestingAll(profileId)
              : state.isTesting(profileId, node.name),
          delay: state.delay(profileId, measured),
        ),
      ),
    );
    final testing = health.testing || evaluating;
    final desktop = Theme.of(context).platform == TargetPlatform.windows;
    return ClipRRect(
      borderRadius: BorderRadius.circular(context.nozelt.cardRadius),
      child: Stack(
        children: [
          NozeltSurface(
            onTap: onTap,
            outlined: false,
            color: selected
                ? Theme.of(context).colorScheme.primaryContainer
                : Theme.of(context).colorScheme.surface,
            padding: EdgeInsets.fromLTRB(13, 8, _desktopNodeEndPadding, 8),
            child: Row(
              children: [
                Container(
                  width: desktop ? 36 : 40,
                  height: desktop ? 36 : 40,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: Theme.of(
                      context,
                    ).colorScheme.surfaceContainerHighest,
                    borderRadius: BorderRadius.circular(
                      context.nozelt.controlRadius,
                    ),
                  ),
                  child: _auto
                      ? Icon(
                          Icons.bolt_rounded,
                          size: desktop ? 22 : 24,
                          color: nozeltIconAccent(context),
                        )
                      : CountryFlag(node.flagEmoji, size: desktop ? 24 : 26),
                ),
                const SizedBox(width: 11),
                Expanded(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      _AdaptiveNodeTitle(
                        _auto ? Profile.nozeltAutoName : node.displayName,
                      ),
                      const SizedBox(height: 4),
                      Wrap(
                        spacing: 6,
                        runSpacing: 4,
                        children: [
                          // The auto row names the server it is using now.
                          _SmallChip(
                            label: _auto
                                ? autoPick?.displayName ?? ''
                                : node.displayType,
                          ),
                          _SmallChip(
                            label: _delayLabel(context, health.delay),
                            color: _delayColor(
                              context,
                              health.delay?.milliseconds,
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 6),
                IconButton(
                  tooltip: context.tr(_auto ? 'pingAll' : 'pingNode'),
                  style: nozeltOutlinedIconStyle(context),
                  onPressed: testing ? null : onPing,
                  constraints: desktop
                      ? _desktopRowButtonSize
                      : const BoxConstraints.tightFor(width: 44, height: 44),
                  padding: desktop ? EdgeInsets.zero : null,
                  icon: testing
                      ? const SizedBox.square(
                          dimension: 20,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : Icon(Icons.speed_rounded, size: desktop ? 23 : 24),
                ),
                // The auto server has no settings: its ping button takes the
                // right-hand place of the settings button.
                if (onSettings != null) ...[
                  const SizedBox(width: NozeltSpacing.sm),
                  IconButton(
                    tooltip: context.tr('nodeSettings'),
                    style: nozeltOutlinedIconStyle(context),
                    onPressed: onSettings,
                    constraints: desktop
                        ? _desktopRowButtonSize
                        : const BoxConstraints.tightFor(width: 44, height: 44),
                    padding: desktop ? EdgeInsets.zero : null,
                    icon: Icon(
                      Icons.more_horiz_rounded,
                      size: desktop ? 23 : 24,
                    ),
                  ),
                ],
              ],
            ),
          ),
          // The selected server is marked like the other selections: a thin
          // cyan outline around the filled row.
          if (selected)
            Positioned.fill(
              child: IgnorePointer(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(
                      context.nozelt.cardRadius,
                    ),
                    border: Border.all(
                      color: context.nozelt.glow.withValues(alpha: .35),
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  static String _delayLabel(BuildContext context, NodeDelay? delay) {
    if (delay?.milliseconds != null) {
      return context.tr('milliseconds', {'value': delay!.milliseconds!});
    }
    return delay == null
        ? context.tr('notMeasured')
        : context.tr('unavailable');
  }

  static Color _delayColor(BuildContext context, int? delay) {
    if (delay == null) return Theme.of(context).colorScheme.onSurfaceVariant;
    if (delay < 180) return context.nozelt.success;
    if (delay < 450) return context.nozelt.warning;
    return Theme.of(context).colorScheme.error;
  }
}

class _AdaptiveNodeTitle extends StatelessWidget {
  const _AdaptiveNodeTitle(this.value);

  final String value;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final baseStyle = Theme.of(context).textTheme.titleMedium?.copyWith(
        fontWeight: FontWeight.w600,
        height: 1.06,
        letterSpacing: -0.15,
      );
      const sizes = <double>[16.5, 15.5, 14.5, 13.5, 12.5];
      for (final size in sizes) {
        final style = baseStyle?.copyWith(fontSize: size);
        final painter = TextPainter(
          text: TextSpan(text: value, style: style),
          maxLines: 1,
          textDirection: Directionality.of(context),
        )..layout(maxWidth: constraints.maxWidth);
        if (!painter.didExceedMaxLines &&
            painter.width <= constraints.maxWidth) {
          return Text(
            value,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: style,
          );
        }
      }
      return Text(
        value,
        maxLines: 2,
        softWrap: true,
        overflow: TextOverflow.ellipsis,
        style: baseStyle?.copyWith(fontSize: 12.5),
      );
    },
  );
}

class _SmallChip extends StatelessWidget {
  const _SmallChip({required this.label, this.color});

  final String label;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final foreground = color ?? Theme.of(context).colorScheme.onSurfaceVariant;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
      decoration: BoxDecoration(
        color: foreground.withValues(alpha: 0.1),
        // Capsule tags, matching the other rounded elements.
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        label,
        style: Theme.of(context).textTheme.labelSmall?.copyWith(
          color: foreground,
          fontSize: defaultTargetPlatform == TargetPlatform.windows ? 11 : 10,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}

class _ProfileOverviewCard extends ConsumerWidget {
  const _ProfileOverviewCard({
    required this.profile,
    required this.active,
    required this.expanded,
    required this.refreshing,
    required this.onToggleExpanded,
    required this.onRefresh,
    required this.onSettings,
    required this.onTelegram,
    required this.onAction,
  });

  final Profile profile;
  final bool active;
  final bool expanded;
  final bool refreshing;
  final VoidCallback onToggleExpanded;
  final VoidCallback? onRefresh;
  final VoidCallback onSettings;
  final VoidCallback? onTelegram;
  final ValueChanged<String> onAction;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final metadata = profile.subscriptionMetadata;
    final showUsage =
        (metadata?.hasTrafficUsage ?? false) ||
        (metadata?.hasTrafficLimit ?? false);
    final showExpiry = metadata?.expiresAt != null;
    final description = metadata?.description;
    final showInfo =
        showUsage || showExpiry || description != null || onTelegram != null;
    final testingAll = ref.watch(
      nodeHealthProvider.select((state) => state.isTestingAll(profile.id)),
    );
    return Semantics(
      selected: active,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            // On Windows the right edge matches the server rows (frame inset
            // plus row padding), so header and row buttons share one column.
            padding: EdgeInsets.fromLTRB(
              7,
              8,
              _desktopCardInset + _desktopNodeEndPadding,
              8,
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                IconButton(
                  tooltip: expanded
                      ? context.tr('collapseNodes')
                      : context.tr('expandNodes'),
                  onPressed: onToggleExpanded,
                  constraints: const BoxConstraints.tightFor(
                    width: 40,
                    height: 42,
                  ),
                  padding: EdgeInsets.zero,
                  icon: AnimatedRotation(
                    turns: expanded ? 0 : -0.25,
                    duration: const Duration(milliseconds: 180),
                    child: const Icon(Icons.keyboard_arrow_down_rounded),
                  ),
                ),
                const SizedBox(width: 5),
                Expanded(child: _AdaptiveProfileTitle(profile.name)),
                const SizedBox(width: 5),
                if (profile.isSubscription)
                  IconButton(
                    tooltip: context.tr('refreshSubscription'),
                    style: nozeltOutlinedIconStyle(context),
                    onPressed: refreshing ? null : onRefresh,
                    constraints: const BoxConstraints.tightFor(
                      width: 40,
                      height: 42,
                    ),
                    padding: EdgeInsets.zero,
                    icon: refreshing
                        ? const SizedBox.square(
                            dimension: 18,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.refresh_rounded, size: 23),
                  ),
                const SizedBox(width: NozeltSpacing.sm),
                IconButton(
                  tooltip: context.tr('pingAll'),
                  style: nozeltOutlinedIconStyle(context),
                  onPressed: testingAll
                      ? null
                      : () => ref
                            .read(nodeHealthProvider.notifier)
                            .pingAll(profile),
                  constraints: const BoxConstraints.tightFor(
                    width: 40,
                    height: 42,
                  ),
                  padding: EdgeInsets.zero,
                  icon: testingAll
                      ? const SizedBox.square(
                          dimension: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.speed_rounded, size: 23),
                ),
                const SizedBox(width: NozeltSpacing.sm),
                if (defaultTargetPlatform == TargetPlatform.windows)
                  NozeltPopupMenuButton<String>(
                    tooltip: context.tr('profileSettings'),
                    // Same round size as the refresh and ping buttons.
                    style: nozeltOutlinedIconStyle(context)?.copyWith(
                      fixedSize: WidgetStatePropertyAll(
                        _desktopRowButtonSize.biggest,
                      ),
                      minimumSize: WidgetStatePropertyAll(
                        _desktopRowButtonSize.biggest,
                      ),
                    ),
                    padding: EdgeInsets.zero,
                    icon: const Icon(Icons.more_horiz_rounded, size: 23),
                    onSelected: onAction,
                    itemBuilder: (context) => [
                      PopupMenuItem(
                        value: 'pin',
                        child: Text(
                          context.tr(
                            profile.pinned ? 'unpinProfile' : 'pinProfile',
                          ),
                        ),
                      ),
                      PopupMenuItem(
                        value: 'edit',
                        child: Text(context.tr('editProfile')),
                      ),
                      // A hairline keeps "Delete" the same distance from the
                      // line as the item above it; the default 16 px divider
                      // pushed it visibly lower.
                      const PopupMenuDivider(height: 1),
                      PopupMenuItem(
                        value: 'delete',
                        child: Text(
                          context.tr('delete'),
                          style: TextStyle(
                            color: Theme.of(context).colorScheme.error,
                          ),
                        ),
                      ),
                    ],
                  )
                else
                  IconButton(
                    tooltip: context.tr('profileSettings'),
                    style: nozeltOutlinedIconStyle(context),
                    onPressed: onSettings,
                    constraints: const BoxConstraints.tightFor(
                      width: 40,
                      height: 42,
                    ),
                    padding: EdgeInsets.zero,
                    icon: const Icon(Icons.more_horiz_rounded, size: 23),
                  ),
              ],
            ),
          ),
          if (showInfo) ...[
            // The description sits right under the name, centred;
            // traffic, expiry and Telegram follow in one tidy strip.
            if (description != null)
              Padding(
                padding: const EdgeInsets.fromLTRB(
                  NozeltSpacing.lg,
                  0,
                  NozeltSpacing.lg,
                  NozeltSpacing.md,
                ),
                child: Text(
                  description,
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                    height: 1.35,
                  ),
                ),
              ),
            if (showUsage || showExpiry || onTelegram != null)
              Padding(
                padding: const EdgeInsets.fromLTRB(
                  _desktopCardInset,
                  0,
                  _desktopCardInset,
                  _desktopCardInset,
                ),
                child: _DesktopSubscriptionStats(
                  metadata: metadata,
                  showUsage: showUsage,
                  showExpiry: showExpiry,
                  onTelegram: onTelegram,
                ),
              ),
          ],
        ],
      ),
    );
  }

  static String _shortDate(DateTime value) =>
      '${_two(value.day)}.${_two(value.month)}.${value.year}';

  static String _two(int value) => value.toString().padLeft(2, '0');
}

/// Gap between the card frame and its inner Windows tiles, shared with the
/// server rows so the stats line up with them.
const double _desktopCardInset = 9;

/// Space after the last button of a Windows server row.
const double _desktopNodeEndPadding = 7;

/// Round buttons of Windows profile headers and server rows share one size.
const _desktopRowButtonSize = BoxConstraints.tightFor(width: 40, height: 42);

/// Clock for the "days left" tile; tests pin it so renders stay stable.
@visibleForTesting
DateTime Function() subscriptionClock = DateTime.now;

/// Windows subscription summary: traffic, days left and Telegram as matching
/// rounded tiles under the profile header.
class _DesktopSubscriptionStats extends StatelessWidget {
  const _DesktopSubscriptionStats({
    required this.metadata,
    required this.showUsage,
    required this.showExpiry,
    required this.onTelegram,
  });

  final SubscriptionMetadata? metadata;
  final bool showUsage;
  final bool showExpiry;
  final VoidCallback? onTelegram;

  @override
  Widget build(BuildContext context) {
    final usage = showUsage ? _trafficTile(context, metadata!) : null;
    final expiry = showExpiry
        ? _expiryTile(context, metadata!.expiresAt!)
        : null;
    final telegram = onTelegram == null
        ? null
        : _StatTile(
            badgeColor: Theme.of(context).colorScheme.onSurfaceVariant,
            icon: _TelegramLogo(
              size: 20,
              color: Theme.of(context).colorScheme.onSurface,
            ),
            caption: context.tr('telegramOpen'),
            value: 'Telegram',
            onTap: onTelegram,
          );
    final tiles = <Widget>[?usage, ?expiry, ?telegram];
    const gap = SizedBox.square(dimension: NozeltSpacing.sm);
    Widget row(List<Widget> items) => IntrinsicHeight(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (var i = 0; i < items.length; i++) ...[
            if (i > 0) gap,
            Expanded(child: items[i]),
          ],
        ],
      ),
    );
    return LayoutBuilder(
      builder: (context, constraints) {
        // A tile needs about 240 px; a narrower card puts traffic on its own
        // line and the other tiles under it.
        final fitsInRow = constraints.maxWidth >= tiles.length * 240;
        if (fitsInRow || tiles.length == 1) return row(tiles);
        final rest = <Widget>[?expiry, ?telegram];
        // A phone is too narrow even for two tiles side by side.
        if (usage != null && constraints.maxWidth >= rest.length * 240) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [usage, gap, row(rest)],
          );
        }
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            for (var i = 0; i < tiles.length; i++) ...[
              if (i > 0) gap,
              tiles[i],
            ],
          ],
        );
      },
    );
  }

  static Widget _trafficTile(
    BuildContext context,
    SubscriptionMetadata metadata,
  ) {
    final used = metadata.usedBytes;
    final total = metadata.hasTrafficLimit ? metadata.totalBytes : null;
    final separator = context.l10n.isRussian ? ',' : '.';
    final unit = context.l10n.isRussian ? 'ГБ' : 'GB';
    String gigabytes(int bytes) =>
        '${_SubscriptionUsage._formatGigabytes(bytes).replaceAll('.', separator)} $unit';
    final progress = total == null ? null : (used / total).clamp(0.0, 1.0);
    final nearLimit = progress != null && progress >= .9;
    return _StatTile(
      badgeColor: nearLimit
          ? Theme.of(context).colorScheme.error
          : context.nozelt.glow,
      icon: const Icon(Icons.swap_vert_rounded),
      caption: context.tr('traffic'),
      value: gigabytes(used),
      endCaption: context.tr('trafficLimit'),
      endValue: total == null ? '∞' : gigabytes(total),
      footer: progress == null
          ? null
          : ClipRRect(
              borderRadius: BorderRadius.circular(999),
              child: LinearProgressIndicator(
                value: progress,
                minHeight: 4,
                backgroundColor: Theme.of(
                  context,
                ).colorScheme.outlineVariant.withValues(alpha: .55),
                color: nearLimit
                    ? Theme.of(context).colorScheme.error
                    : context.nozelt.glow,
              ),
            ),
    );
  }

  static Widget _expiryTile(BuildContext context, DateTime expiresAt) {
    final date = _ProfileOverviewCard._shortDate(expiresAt);
    final remaining = expiresAt.difference(subscriptionClock());
    if (remaining.isNegative) {
      final error = Theme.of(context).colorScheme.error;
      return _StatTile(
        badgeColor: error,
        icon: const Icon(Icons.event_busy_rounded),
        caption: context.tr('subscription'),
        value: context.tr('subscriptionExpired'),
        valueColor: error,
        endCaption: context.tr('subscriptionUntilLabel'),
        endValue: date,
      );
    }
    final days = (remaining.inMinutes / Duration.minutesPerDay).ceil();
    final soon = days <= 3;
    return _StatTile(
      badgeColor: soon ? context.nozelt.warning : context.nozelt.glow,
      icon: const Icon(Icons.event_available_rounded),
      caption: context.tr('subscriptionLeft'),
      value: context.l10n.dayCount(days),
      valueColor: soon ? context.nozelt.warning : null,
      endCaption: context.tr('subscriptionUntilLabel'),
      endValue: date,
    );
  }
}

/// A subscription fact in the style of the Windows home cards: a tinted icon
/// square, a caption over a value, and an optional second value on the right.
class _StatTile extends StatelessWidget {
  const _StatTile({
    required this.badgeColor,
    required this.icon,
    required this.caption,
    required this.value,
    this.valueColor,
    this.endCaption,
    this.endValue,
    this.footer,
    this.onTap,
  });

  final Color badgeColor;
  final Widget icon;
  final String caption;
  final String value;
  final Color? valueColor;
  final String? endCaption;
  final String? endValue;
  final Widget? footer;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    Widget metric(
      String caption,
      String value,
      CrossAxisAlignment align, {
      Color? color,
    }) => Column(
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
              color: color,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
        ),
      ],
    );
    final row = Row(
      children: [
        NozeltIconBadge(color: badgeColor, icon: icon),
        const SizedBox(width: NozeltSpacing.md),
        Expanded(
          child: metric(
            caption,
            value,
            CrossAxisAlignment.start,
            color: valueColor,
          ),
        ),
        if (endValue != null) ...[
          const SizedBox(width: NozeltSpacing.md),
          metric(endCaption ?? '', endValue!, CrossAxisAlignment.end),
        ],
        if (onTap != null) ...[
          const SizedBox(width: NozeltSpacing.sm),
          Icon(
            Icons.chevron_right_rounded,
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ],
      ],
    );
    final body = Column(
      mainAxisAlignment: MainAxisAlignment.center,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        row,
        if (footer != null) ...[
          const SizedBox(height: NozeltSpacing.sm),
          footer!,
        ],
      ],
    );
    final surface = NozeltSurface(
      padding: const EdgeInsets.all(NozeltSpacing.md),
      onTap: onTap,
      child: body,
    );
    return onTap == null
        ? surface
        : Semantics(
            button: true,
            label: '$caption $value',
            excludeSemantics: true,
            child: surface,
          );
  }
}

class _AdaptiveProfileTitle extends StatelessWidget {
  const _AdaptiveProfileTitle(this.value);

  final String value;

  @override
  Widget build(BuildContext context) {
    final length = value.runes.length;
    final fontSize = switch (length) {
      <= 16 => 18.0,
      <= 26 => 16.5,
      <= 40 => 15.0,
      _ => 14.0,
    };
    return Text(
      value,
      maxLines: 2,
      softWrap: true,
      overflow: TextOverflow.ellipsis,
      style: Theme.of(context).textTheme.titleLarge?.copyWith(
        fontSize: fontSize,
        height: 1.08,
        letterSpacing: -0.2,
        fontWeight: FontWeight.w700,
      ),
    );
  }
}

class _SubscriptionUsage extends StatelessWidget {
  const _SubscriptionUsage({required this.metadata});

  final SubscriptionMetadata metadata;

  @override
  Widget build(BuildContext context) {
    final used = metadata.usedBytes;
    final total = metadata.totalBytes;
    final decimalSeparator = context.l10n.isRussian ? ',' : '.';
    final usedText = _formatGigabytes(used).replaceAll('.', decimalSeparator);
    final totalText = total == null
        ? '∞'
        : _formatGigabytes(total).replaceAll('.', decimalSeparator);
    final unit = context.l10n.isRussian ? 'ГБ' : 'GB';
    final progress = total == null || total <= 0
        ? null
        : (used / total).clamp(0.0, 1.0);
    return Semantics(
      label: '$usedText / $totalText $unit',
      excludeSemantics: true,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox.square(
            dimension: 19,
            child: CustomPaint(
              painter: _TrafficRingPainter(
                progress: progress,
                trackColor: Theme.of(context).colorScheme.onSurfaceVariant,
                valueColor: Theme.of(context).colorScheme.primary,
              ),
            ),
          ),
          const SizedBox(width: 7),
          Text.rich(
            TextSpan(
              children: [
                TextSpan(
                  text: usedText,
                  style: TextStyle(
                    color: Theme.of(context).colorScheme.onSurface,
                  ),
                ),
                TextSpan(
                  text: ' / ',
                  style: TextStyle(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                ),
                TextSpan(
                  text: totalText,
                  style: TextStyle(
                    color: progress == null
                        ? Theme.of(context).colorScheme.onSurfaceVariant
                        : Theme.of(context).colorScheme.onSurface,
                  ),
                ),
                TextSpan(
                  text: ' $unit',
                  style: TextStyle(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: Theme.of(context).textTheme.labelSmall?.copyWith(
              fontSize: 11,
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
      ),
    );
  }

  static String _formatGigabytes(int bytes) {
    final value = bytes / (1024 * 1024 * 1024);
    return value >= 100 ? value.toStringAsFixed(0) : value.toStringAsFixed(1);
  }
}

class _TrafficRingPainter extends CustomPainter {
  const _TrafficRingPainter({
    required this.progress,
    required this.trackColor,
    required this.valueColor,
  });

  final double? progress;
  final Color trackColor;
  final Color valueColor;

  @override
  void paint(Canvas canvas, Size size) {
    final strokeWidth = math.max(2.0, size.shortestSide * 0.13);
    final center = size.center(Offset.zero);
    final radius = (size.shortestSide - strokeWidth) / 2;
    final rect = Rect.fromCircle(center: center, radius: radius);
    final basePaint = Paint()
      ..isAntiAlias = true
      ..color = trackColor.withValues(alpha: 0.62)
      ..style = PaintingStyle.stroke
      ..strokeWidth = strokeWidth
      ..strokeCap = StrokeCap.round;
    canvas.drawCircle(center, radius, basePaint);

    final value = progress;
    if (value == null || value <= 0) return;
    canvas.drawArc(
      rect,
      -math.pi / 2,
      math.pi * 2 * value,
      false,
      Paint()
        ..isAntiAlias = true
        ..color = valueColor
        ..style = PaintingStyle.stroke
        ..strokeWidth = strokeWidth
        ..strokeCap = StrokeCap.round,
    );
  }

  @override
  bool shouldRepaint(covariant _TrafficRingPainter oldDelegate) =>
      oldDelegate.progress != progress ||
      oldDelegate.trackColor != trackColor ||
      oldDelegate.valueColor != valueColor;
}

class _TelegramLogo extends StatelessWidget {
  const _TelegramLogo({this.size = 28, this.color = Colors.white});

  final double size;
  final Color color;

  @override
  Widget build(BuildContext context) => SizedBox.square(
    dimension: size,
    child: CustomPaint(painter: _TelegramLogoPainter(color)),
  );
}

class _TelegramLogoPainter extends CustomPainter {
  const _TelegramLogoPainter(this.color);

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final scale = size.shortestSide / 24;
    canvas.scale(scale);
    final plane = Path()
      ..moveTo(20.9, 5.45)
      ..lineTo(17.95, 19.35)
      ..cubicTo(17.73, 20.33, 17.15, 20.57, 16.32, 20.1)
      ..lineTo(11.84, 16.8)
      ..lineTo(9.67, 18.89)
      ..cubicTo(9.43, 19.13, 9.23, 19.32, 8.77, 19.32)
      ..lineTo(9.09, 14.78)
      ..lineTo(17.36, 7.31)
      ..cubicTo(17.72, 6.99, 17.28, 6.83, 16.81, 7.14)
      ..lineTo(6.58, 13.59)
      ..lineTo(2.18, 12.21)
      ..cubicTo(1.23, 11.91, 1.21, 11.26, 2.38, 10.81)
      ..lineTo(19.62, 4.17)
      ..cubicTo(20.42, 3.88, 21.12, 4.37, 20.9, 5.45)
      ..close();
    canvas.drawPath(
      plane,
      Paint()
        ..isAntiAlias = true
        ..color = color,
    );
  }

  @override
  bool shouldRepaint(covariant _TelegramLogoPainter oldDelegate) =>
      oldDelegate.color != color;
}

class _EmptyProfiles extends StatelessWidget {
  const _EmptyProfiles({required this.onAdd});
  final VoidCallback onAdd;

  @override
  Widget build(BuildContext context) => NozeltSurface(
    padding: const EdgeInsets.all(24),
    child: Column(
      children: [
        Icon(
          Icons.add_link_rounded,
          size: 48,
          color: Theme.of(context).colorScheme.primary,
        ),
        const SizedBox(height: 16),
        Text(
          context.tr('noProfiles'),
          style: Theme.of(context).textTheme.titleLarge,
        ),
        const SizedBox(height: 7),
        Text(
          context.tr('noProfilesHint'),
          textAlign: TextAlign.center,
          style: Theme.of(context).textTheme.bodyMedium?.copyWith(
            color: Theme.of(context).colorScheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: 18),
        FilledButton.icon(
          onPressed: onAdd,
          icon: const Icon(Icons.add_rounded),
          label: Text(context.tr('addProfile')),
        ),
      ],
    ),
  );
}

class _ErrorState extends StatelessWidget {
  const _ErrorState({required this.message, required this.onRetry});
  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) => Center(
    child: Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.error_outline_rounded, size: 44),
          const SizedBox(height: 12),
          Text(message, textAlign: TextAlign.center),
          const SizedBox(height: 16),
          FilledButton(onPressed: onRetry, child: Text(context.tr('retry'))),
        ],
      ),
    ),
  );
}
