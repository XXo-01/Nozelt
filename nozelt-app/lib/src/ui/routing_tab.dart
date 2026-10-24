import 'package:nozelt/nozelt_design_system.dart';
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/routing_profile.dart';
import '../core/routing_rule.dart';
import '../core/split_tunnel_settings.dart';
import '../l10n/nozelt_l10n.dart';
import '../l10n/user_error.dart';
import '../state/routing_config_controller.dart';
import '../state/routing_profiles_provider.dart';
import '../state/split_tunnel_provider.dart';
import 'routing_profile_config_screen.dart';
import 'routing_profile_settings_screen.dart';
import 'routing_rule_category_screen.dart';
import 'split_tunnel_screen.dart';

class RoutingTab extends ConsumerWidget {
  const RoutingTab({this.isVisible = true, super.key});

  final bool isVisible;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (!isVisible) return const SizedBox.shrink();
    final profiles = ref.watch(routingProfilesProvider);
    final profile = profiles.active;
    final split = ref.watch(splitTunnelProvider);
    final desktop = defaultTargetPlatform == TargetPlatform.windows;

    Widget list(EdgeInsets insets) => ListView(
      key: const PageStorageKey<String>('routing-scroll'),
      physics: desktop
          ? const ClampingScrollPhysics()
          : const BouncingScrollPhysics(),
      padding: desktop ? insets : const EdgeInsets.fromLTRB(20, 18, 20, 124),
      children: [
        NozeltPageHeader(
          title: context.tr(desktop ? 'desktopRoutingTab' : 'routing'),
        ),
        const SizedBox(height: 22),
        NozeltSectionTitle(
          context.tr('routingProfile'),
          trailing: Tooltip(
            message: context.tr('addRoutingProfile'),
            // A section-level action: quieter than a page's main one.
            child: OutlinedButton.icon(
              onPressed: () => _showAddProfile(context, ref),
              icon: const Icon(Icons.add_rounded, size: 18),
              label: Text(context.tr('addProfile')),
            ),
          ),
        ),
        const SizedBox(height: 10),
        NozeltSurface(
          padding: EdgeInsets.zero,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(14, 8, 6, 8),
            child: Row(
              children: [
                Container(
                  width: 42,
                  height: 42,
                  decoration: BoxDecoration(
                    color: Theme.of(
                      context,
                    ).colorScheme.primary.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(13),
                  ),
                  child: Icon(
                    Icons.route_rounded,
                    color: nozeltIconAccent(context),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  // Same flush popup menu as every other Nozelt menu.
                  child: LayoutBuilder(
                    builder: (context, constraints) =>
                        NozeltPopupMenuButton<String>(
                          tooltip: '',
                          initialValue: profile.id,
                          constraints: BoxConstraints(
                            minWidth: constraints.maxWidth,
                            maxWidth: constraints.maxWidth,
                          ),
                          onSelected: (id) {
                            if (id != profile.id) {
                              _run(
                                context,
                                ref
                                    .read(routingConfigControllerProvider)
                                    .activateProfile(id),
                              );
                            }
                          },
                          itemBuilder: (context) => [
                            for (final value in profiles.profiles)
                              PopupMenuItem(
                                value: value.id,
                                child: Text(
                                  value.name,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: Theme.of(
                                    context,
                                  ).textTheme.titleMedium,
                                ),
                              ),
                          ],
                          child: SizedBox(
                            height: 48,
                            child: Row(
                              children: [
                                Expanded(
                                  child: Text(
                                    profile.name,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: Theme.of(
                                      context,
                                    ).textTheme.titleMedium,
                                  ),
                                ),
                                const Icon(Icons.keyboard_arrow_down_rounded),
                                const SizedBox(width: 4),
                              ],
                            ),
                          ),
                        ),
                  ),
                ),
                NozeltPopupMenuButton<String>(
                  tooltip: context.tr('profileActions'),
                  onSelected: (action) => _profileAction(context, ref, action),
                  itemBuilder: (context) => [
                    _menuItem(
                      'rename',
                      Icons.edit_rounded,
                      context.tr('rename'),
                    ),
                    _menuItem(
                      'config',
                      Icons.data_object_rounded,
                      context.tr('viewConfig'),
                    ),
                    _menuItem(
                      'share',
                      Icons.link_rounded,
                      context.tr('copyLink'),
                    ),
                    if (profiles.profiles.length > 1)
                      _menuItem(
                        'delete',
                        Icons.delete_outline_rounded,
                        context.tr('delete'),
                      ),
                  ],
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 22),
        NozeltSectionTitle(context.tr('routingSettings')),
        const SizedBox(height: 10),
        NozeltSurface(
          padding: EdgeInsets.zero,
          child: ListTile(
            contentPadding: EdgeInsets.fromLTRB(
              16,
              desktop ? 0 : 5,
              10,
              desktop ? 0 : 5,
            ),
            leading: Icon(Icons.tune_rounded, color: nozeltIconAccent(context)),
            title: Text(context.tr('settings')),
            trailing: Icon(
              Icons.chevron_right_rounded,
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute(
                builder: (_) => const RoutingProfileSettingsScreen(),
              ),
            ),
          ),
        ),
        if (!desktop) ...[
          const SizedBox(height: 22),
          NozeltSectionTitle(context.tr('applications')),
          const SizedBox(height: 10),
          NozeltSurface(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  context.tr('splitTunnel'),
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                const SizedBox(height: 16),
                NozeltSegmentedControl<SplitMode>(
                  allowVertical: false,
                  segments: [
                    ButtonSegment(
                      value: SplitMode.off,
                      label: Text(context.tr('all')),
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
                  onChanged: (mode) =>
                      ref.read(splitTunnelProvider.notifier).setMode(mode),
                ),
                const SizedBox(height: 14),
                SizedBox(
                  width: double.infinity,
                  child: NozeltButton(
                    variant: NozeltButtonVariant.secondary,
                    onPressed: split.mode == SplitMode.off
                        ? null
                        : () => Navigator.of(context).push(
                            MaterialPageRoute(
                              builder: (_) => const SplitTunnelScreen(),
                            ),
                          ),
                    icon: const Icon(Icons.apps_rounded),
                    label: split.apps.isEmpty
                        ? context.tr('selectApps')
                        : context.tr('selectedCount', {
                            'count': split.apps.length,
                          }),
                  ),
                ),
              ],
            ),
          ),
        ],
        const SizedBox(height: 22),
        NozeltSectionTitle(context.tr('rules')),
        const SizedBox(height: 10),
        LayoutBuilder(
          builder: (context, constraints) {
            final twoColumns = desktop && constraints.maxWidth >= 500;
            return Wrap(
              spacing: 12,
              runSpacing: 12,
              children: [
                for (final category in _categories(context))
                  SizedBox(
                    width: twoColumns
                        ? (constraints.maxWidth - 12) / 2
                        : constraints.maxWidth,
                    child: _CategoryTile(
                      category: category,
                      count: profile.rules
                          .where((rule) => category.types.contains(rule.type))
                          .length,
                      onTap: () => Navigator.of(context).push(
                        MaterialPageRoute(
                          builder: (_) => RoutingRuleCategoryScreen(
                            titleKey: category.titleKey,
                            types: category.types,
                          ),
                        ),
                      ),
                    ),
                  ),
              ],
            );
          },
        ),
      ],
    );
    return SafeArea(
      bottom: false,
      child: desktop
          ? NozeltPageInsets(builder: (context, insets) => list(insets))
          : list(EdgeInsets.zero),
    );
  }

  static PopupMenuItem<String> _menuItem(
    String value,
    IconData icon,
    String title,
  ) => PopupMenuItem(
    value: value,
    child: Row(
      children: [Icon(icon, size: 20), const SizedBox(width: 10), Text(title)],
    ),
  );

  List<_RuleCategory> _categories(BuildContext context) => [
    if (defaultTargetPlatform == TargetPlatform.windows)
      const _RuleCategory(
        titleKey: 'processes',
        icon: Icons.apps_rounded,
        types: {RoutingRuleType.processName},
      ),
    _RuleCategory(
      titleKey: 'geoRules',
      icon: Icons.travel_explore_rounded,
      types: {RoutingRuleType.geoIp, RoutingRuleType.geoSite},
    ),
    _RuleCategory(
      titleKey: 'exactDomain',
      icon: Icons.language_rounded,
      types: {RoutingRuleType.domain},
    ),
    _RuleCategory(
      titleKey: 'domainSuffix',
      icon: Icons.account_tree_outlined,
      types: {RoutingRuleType.domainSuffix},
    ),
    _RuleCategory(
      titleKey: 'domainKeyword',
      icon: Icons.text_fields_rounded,
      types: {RoutingRuleType.domainKeyword},
    ),
    _RuleCategory(
      titleKey: 'ipCidr',
      icon: Icons.hub_outlined,
      types: {RoutingRuleType.ipCidr},
    ),
  ];

  Future<void> _showAddProfile(BuildContext context, WidgetRef ref) async {
    final action = await showModalBottomSheet<String>(
      context: context,
      builder: (sheetContext) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ListTile(
                leading: const Icon(Icons.add_rounded),
                title: Text(context.tr('createRoutingProfile')),
                onTap: () => Navigator.pop(sheetContext, 'create'),
              ),
              ListTile(
                leading: const Icon(Icons.content_paste_rounded),
                title: Text(context.tr('importRoutingProfile')),
                onTap: () => Navigator.pop(sheetContext, 'import'),
              ),
            ],
          ),
        ),
      ),
    );
    if (!context.mounted) return;
    if (action == 'create') {
      final name = await _textDialog(
        context,
        title: context.tr('createRoutingProfile'),
        label: context.tr('profileName'),
      );
      if (name != null && context.mounted) {
        await _run(
          context,
          ref.read(routingConfigControllerProvider).createProfile(name),
        );
      }
    } else if (action == 'import') {
      final raw = await _multilineDialog(
        context,
        title: context.tr('importRoutingProfile'),
      );
      if (raw != null && context.mounted) {
        final operation = raw.trimLeft().startsWith('nozelt://')
            ? ref.read(routingConfigControllerProvider).importLink(raw)
            : ref.read(routingConfigControllerProvider).importConfig(raw);
        await _run(context, operation);
      }
    }
  }

  Future<void> _profileAction(
    BuildContext context,
    WidgetRef ref,
    String action,
  ) async {
    final profile = ref.read(routingProfilesProvider).active;
    final controller = ref.read(routingConfigControllerProvider);
    switch (action) {
      case 'rename':
        final name = await _textDialog(
          context,
          title: context.tr('renameRoutingProfile'),
          label: context.tr('profileName'),
          initial: profile.name,
        );
        if (name != null && context.mounted) {
          await _run(context, controller.renameProfile(profile.id, name));
        }
      case 'config':
        await Navigator.of(context).push(
          MaterialPageRoute(builder: (_) => const RoutingProfileConfigScreen()),
        );
      case 'share':
        await Clipboard.setData(ClipboardData(text: profile.encodeShareLink()));
        if (context.mounted) {
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(SnackBar(content: Text(context.tr('linkCopied'))));
        }
      case 'delete':
        final confirmed = await showDialog<bool>(
          context: context,
          builder: (dialogContext) => AlertDialog(
            title: Text(context.tr('deleteRoutingProfile')),
            content: Text(profile.name),
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
        );
        if (confirmed == true && context.mounted) {
          await _run(context, controller.deleteProfile(profile.id));
        }
    }
  }

  static Future<String?> _textDialog(
    BuildContext context, {
    required String title,
    required String label,
    String initial = '',
  }) async {
    final controller = TextEditingController(text: initial);
    final value = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(title),
        content: TextField(
          controller: controller,
          autofocus: true,
          maxLength: RoutingProfile.maxNameCharacters,
          decoration: InputDecoration(labelText: label),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: Text(context.tr('cancel')),
          ),
          FilledButton(
            onPressed: () {
              final text = controller.text.trim();
              if (text.isNotEmpty) Navigator.pop(dialogContext, text);
            },
            child: Text(context.tr('save')),
          ),
        ],
      ),
    );
    controller.dispose();
    return value;
  }

  static Future<String?> _multilineDialog(
    BuildContext context, {
    required String title,
  }) async {
    final controller = TextEditingController();
    final value = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(title),
        content: TextField(
          controller: controller,
          autofocus: true,
          minLines: 6,
          maxLines: 12,
          autocorrect: false,
          enableSuggestions: false,
          decoration: InputDecoration(
            hintText: context.tr('pasteConfigOrLink'),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: Text(context.tr('cancel')),
          ),
          FilledButton(
            onPressed: () {
              if (controller.text.trim().isNotEmpty) {
                Navigator.pop(dialogContext, controller.text);
              }
            },
            child: Text(context.tr('import')),
          ),
        ],
      ),
    );
    controller.dispose();
    return value;
  }

  static Future<void> _run(
    BuildContext context,
    Future<Object?> operation,
  ) async {
    try {
      await operation;
    } catch (error) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            error is FormatException
                ? context.tr('invalidRoutingConfig')
                : localizedUserError(context.l10n, error),
          ),
        ),
      );
    }
  }
}

class _RuleCategory {
  const _RuleCategory({
    required this.titleKey,
    required this.icon,
    required this.types,
  });

  final String titleKey;
  final IconData icon;
  final Set<RoutingRuleType> types;
}

class _CategoryTile extends StatelessWidget {
  const _CategoryTile({
    required this.category,
    required this.count,
    required this.onTap,
  });

  final _RuleCategory category;
  final int count;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => NozeltSurface(
    padding: EdgeInsets.zero,
    onTap: onTap,
    child: ListTile(
      contentPadding: EdgeInsets.fromLTRB(
        16,
        defaultTargetPlatform == TargetPlatform.windows ? 0 : 7,
        8,
        defaultTargetPlatform == TargetPlatform.windows ? 0 : 7,
      ),
      leading: Icon(category.icon, color: nozeltIconAccent(context), size: 22),
      title: Text(
        context.tr(category.titleKey),
        style: defaultTargetPlatform == TargetPlatform.windows
            ? const TextStyle(fontSize: 14)
            : null,
      ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (count > 0)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
              decoration: BoxDecoration(
                color: Theme.of(
                  context,
                ).colorScheme.primary.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(999),
              ),
              child: Text(
                '$count',
                style: TextStyle(
                  color: Theme.of(context).colorScheme.primary,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
          const SizedBox(width: 5),
          Icon(
            Icons.chevron_right_rounded,
            color: Theme.of(context).colorScheme.onSurfaceVariant,
          ),
        ],
      ),
    ),
  );
}
