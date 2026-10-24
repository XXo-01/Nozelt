import 'package:flutter/material.dart';
import 'package:nozelt/nozelt_design_system.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/app_metadata.dart';
import '../../core/models.dart';
import '../../core/tun_settings.dart';
import '../../l10n/nozelt_l10n.dart';
import '../../state/engine_provider.dart';
import '../../state/settings_provider.dart';
import '../../state/routing_config_controller.dart';

class DesktopShell extends ConsumerStatefulWidget {
  const DesktopShell({
    required this.index,
    required this.onChanged,
    required this.child,
    super.key,
  });

  final int index;
  final ValueChanged<int> onChanged;
  final Widget child;

  @override
  ConsumerState<DesktopShell> createState() => _DesktopShellState();
}

class _DesktopShellState extends ConsumerState<DesktopShell> {
  final _navigator = GlobalKey<NavigatorState>();

  void _select(int index) {
    FocusManager.instance.primaryFocus?.unfocus();
    _navigator.currentState?.popUntil((route) => route.isFirst);
    widget.onChanged(index);
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final compact = constraints.maxWidth < 960;
        return Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // The sidebar floats as a rounded panel inside the window.
            Padding(
              padding: const EdgeInsets.fromLTRB(
                NozeltSpacing.md,
                NozeltSpacing.md,
                0,
                NozeltSpacing.md,
              ),
              child: RepaintBoundary(
                key: const ValueKey('desktop-sidebar'),
                child: _Sidebar(
                  index: widget.index,
                  onChanged: _select,
                  compact: compact,
                  versions: ref.watch(engineVersionsProvider),
                ),
              ),
            ),
            Expanded(
              // Pages centre their own content column; the navigator stays
              // full width so scrolling also works in the side margins.
              child: Navigator(
                key: _navigator,
                onDidRemovePage: (_) {},
                pages: [
                  MaterialPage(
                    key: const ValueKey('desktop-content'),
                    child: ColoredBox(
                      color: Theme.of(context).scaffoldBackgroundColor,
                      child: widget.child,
                    ),
                  ),
                ],
              ),
            ),
          ],
        );
      },
    );
  }
}

class _Sidebar extends StatelessWidget {
  const _Sidebar({
    required this.index,
    required this.onChanged,
    required this.compact,
    required this.versions,
  });

  final int index;
  final ValueChanged<int> onChanged;
  final bool compact;
  final AsyncValue<EngineVersions> versions;

  static const _items = [
    (Icons.home_rounded, 'mainTab'),
    (Icons.dns_rounded, 'proxiesTab'),
    (Icons.alt_route_rounded, 'desktopRoutingTab'),
    (Icons.language_rounded, 'desktopConnectionsTab'),
    (Icons.subject_rounded, 'logsTab'),
    (Icons.settings_rounded, 'settingsTab'),
  ];

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final largeText = MediaQuery.textScalerOf(context).scale(14) > 16;
    return Container(
      width: compact ? 72 : (largeText ? 248 : 216),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(context.nozelt.cardRadius + 2),
        border: Border.all(color: theme.colorScheme.outlineVariant),
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            Color.alphaBlend(
              context.nozelt.glow.withValues(alpha: .06),
              theme.colorScheme.surfaceContainerLow,
            ),
            theme.colorScheme.surfaceContainerLow,
          ],
        ),
      ),
      padding: EdgeInsets.fromLTRB(
        compact ? NozeltSpacing.md : NozeltSpacing.lg,
        NozeltSpacing.xxl,
        compact ? NozeltSpacing.md : NozeltSpacing.lg,
        NozeltSpacing.lg,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _Brand(compact: compact, versions: versions),
          const SizedBox(height: NozeltSpacing.section),
          Expanded(
            child: LayoutBuilder(
              builder: (context, constraints) {
                final dense = constraints.maxHeight < _items.length * 48;
                return SingleChildScrollView(
                  primary: false,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      for (
                        var itemIndex = 0;
                        itemIndex < _items.length;
                        itemIndex++
                      ) ...[
                        if (itemIndex > 0)
                          const SizedBox(height: NozeltSpacing.xs),
                        _NavItem(
                          icon: _items[itemIndex].$1,
                          label: context.tr(_items[itemIndex].$2),
                          selected: itemIndex == index,
                          compact: compact,
                          dense: dense,
                          onTap: () => onChanged(itemIndex),
                        ),
                      ],
                    ],
                  ),
                );
              },
            ),
          ),
          const SizedBox(height: NozeltSpacing.md),
          _SidebarRoutingMode(compact: compact),
        ],
      ),
    );
  }
}

/// Logo, name and version. Component versions stay one hover away; the full
/// list is also in Settings → About.
class _Brand extends StatelessWidget {
  const _Brand({required this.compact, required this.versions});

  final bool compact;
  final AsyncValue<EngineVersions> versions;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final lines = versions.when(
      data: (value) => <String>[
        'Nozelt ${AppMetadata.version}',
        'Mihomo ${value.mihomo}',
        'Xray ${value.xray}',
        'sing-box ${value.singBox}',
      ],
      loading: () => <String>[
        'Nozelt ${AppMetadata.version}',
        context.tr('componentsLoading'),
      ],
      error: (_, _) => <String>[
        'Nozelt ${AppMetadata.version}',
        context.tr('coreUnavailable'),
      ],
    );
    final logo = Image.asset(
      'assets/branding/nozelt_desktop_logo.png',
      width: 44,
      height: 44,
      fit: BoxFit.contain,
      filterQuality: FilterQuality.high,
    );
    return Tooltip(
      message: lines.join('\n'),
      child: compact
          ? Center(child: logo)
          : Padding(
              padding: const EdgeInsets.only(left: NozeltSpacing.xs),
              child: Row(
                children: [
                  logo,
                  const SizedBox(width: NozeltSpacing.md),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Nozelt',
                          maxLines: 1,
                          overflow: TextOverflow.fade,
                          softWrap: false,
                          style: theme.textTheme.titleLarge?.copyWith(
                            fontFamily: 'Runzoe',
                            fontSize: 30,
                            fontWeight: FontWeight.w400,
                            letterSpacing: 0.2,
                            height: 0.9,
                          ),
                        ),
                        Padding(
                          padding: const EdgeInsets.only(top: 4),
                          child: Text(
                            AppMetadata.version,
                            style: theme.textTheme.labelMedium?.copyWith(
                              color: theme.colorScheme.primary,
                              fontFamily: 'Runzoe',
                              fontStyle: FontStyle.italic,
                              fontWeight: FontWeight.w400,
                              height: 0.9,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
    );
  }
}

class _SidebarRoutingMode extends ConsumerWidget {
  const _SidebarRoutingMode({required this.compact});
  final bool compact;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final mode = ref.watch(
      tunSettingsProvider.select((value) => value.routingMode),
    );
    Future<void> select(RoutingMode value) async {
      try {
        await ref.read(routingConfigControllerProvider).setMode(value);
      } catch (_) {
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(context.tr('routingApplyFailed'))),
          );
        }
      }
    }

    // Same order and icons as the routing card on Home.
    final options = [
      (RoutingMode.global, Icons.public_rounded, 'globalMode', 'globalMode'),
      (RoutingMode.rule, Icons.rule_rounded, 'sidebarRules', 'ruleMode'),
    ];
    return _ModeSwitch(
      value: mode,
      vertical: compact,
      options: [
        for (final option in options)
          (option.$1, option.$2, context.tr(option.$3), context.tr(option.$4)),
      ],
      onChanged: select,
    );
  }
}

/// Routing mode switch of the sidebar. Its height matches a navigation item
/// (40 px). The narrow sidebar has no room for labels side by side, so there
/// it stacks two icon segments vertically.
class _ModeSwitch extends StatelessWidget {
  const _ModeSwitch({
    required this.value,
    required this.vertical,
    required this.options,
    required this.onChanged,
  });

  final RoutingMode value;
  final bool vertical;
  final List<(RoutingMode, IconData, String, String)> options;
  final ValueChanged<RoutingMode> onChanged;

  static const _inset = 3.0;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    Widget segment((RoutingMode, IconData, String, String) option) {
      final selected = option.$1 == value;
      final color = selected
          ? scheme.onPrimaryContainer
          : scheme.onSurfaceVariant;
      return Semantics(
        button: true,
        selected: selected,
        label: option.$4,
        child: Tooltip(
          message: option.$4,
          child: Material(
            color: selected ? scheme.primaryContainer : Colors.transparent,
            // Same selected capsule as NozeltPillTrack on the pages.
            shape: StadiumBorder(
              side: BorderSide(
                color: selected
                    ? scheme.primary.withValues(alpha: .3)
                    : Colors.transparent,
              ),
            ),
            clipBehavior: Clip.antiAlias,
            child: InkWell(
              onTap: selected ? null : () => onChanged(option.$1),
              child: ConstrainedBox(
                constraints: const BoxConstraints(
                  minHeight: _NavItem.height - _inset * 2,
                ),
                child: Center(
                  child: vertical
                      ? Icon(option.$2, size: 20, color: color)
                      : Padding(
                          padding: const EdgeInsets.symmetric(
                            horizontal: NozeltSpacing.xs,
                            vertical: NozeltSpacing.xs,
                          ),
                          child: Text(
                            option.$3,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.labelLarge?.copyWith(
                              color: color,
                              fontWeight: selected
                                  ? FontWeight.w600
                                  : FontWeight.w500,
                            ),
                          ),
                        ),
                ),
              ),
            ),
          ),
        ),
      );
    }

    final children = [
      for (var index = 0; index < options.length; index++) ...[
        if (index > 0) const SizedBox(width: _inset, height: _inset),
        vertical
            ? segment(options[index])
            : Expanded(child: segment(options[index])),
      ],
    ];
    return Container(
      padding: const EdgeInsets.all(_inset - 1),
      decoration: BoxDecoration(
        color: theme.brightness == Brightness.dark
            ? scheme.surfaceContainerLowest
            : scheme.surfaceContainer,
        // A capsule in both orientations.
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: scheme.outlineVariant),
      ),
      child: vertical
          ? Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: children,
            )
          : Row(children: children),
    );
  }
}

class _NavItem extends StatelessWidget {
  const _NavItem({
    required this.icon,
    required this.label,
    required this.selected,
    required this.compact,
    required this.dense,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final bool selected;
  final bool compact;
  final bool dense;
  final VoidCallback onTap;

  /// Shared with the routing mode switch below the navigation.
  static const height = 40.0;

  @override
  Widget build(BuildContext context) {
    final glow = context.nozelt.glow;
    final dark = Theme.of(context).brightness == Brightness.dark;
    return Semantics(
      selected: selected,
      button: true,
      label: label,
      child: Tooltip(
        message: compact ? label : '',
        child: AnimatedContainer(
          duration: NozeltStates.transition,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(height / 2),
            gradient: selected
                ? LinearGradient(
                    colors: [
                      glow.withValues(alpha: dark ? .24 : .2),
                      glow.withValues(alpha: dark ? .08 : .07),
                    ],
                  )
                : null,
            border: Border.all(
              color: selected
                  ? glow.withValues(alpha: dark ? .35 : .45)
                  : Colors.transparent,
            ),
            boxShadow: selected
                ? [
                    BoxShadow(
                      color: glow.withValues(alpha: dark ? .18 : .2),
                      blurRadius: 16,
                      offset: const Offset(0, 4),
                    ),
                  ]
                : null,
          ),
          child: Material(
            type: MaterialType.transparency,
            shape: const StadiumBorder(),
            clipBehavior: Clip.antiAlias,
            child: InkWell(
              onTap: onTap,
              customBorder: const StadiumBorder(),
              child: Container(
                constraints: const BoxConstraints(minHeight: height),
                padding: EdgeInsets.symmetric(
                  horizontal: compact ? 0 : NozeltSpacing.md,
                  vertical: NozeltSpacing.xs,
                ),
                child: Row(
                  mainAxisAlignment: compact
                      ? MainAxisAlignment.center
                      : MainAxisAlignment.start,
                  children: [
                    Icon(
                      icon,
                      size: 20,
                      color: selected
                          ? nozeltIconAccent(context)
                          : Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                    if (!compact) ...[
                      const SizedBox(width: NozeltSpacing.md),
                      Expanded(
                        child: Text(
                          label,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: Theme.of(context).textTheme.titleSmall
                              ?.copyWith(
                                color: selected
                                    ? Theme.of(context).colorScheme.onSurface
                                    : Theme.of(
                                        context,
                                      ).colorScheme.onSurfaceVariant,
                                fontWeight: selected
                                    ? FontWeight.w600
                                    : FontWeight.w500,
                              ),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
