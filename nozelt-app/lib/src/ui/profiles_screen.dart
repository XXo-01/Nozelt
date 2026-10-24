import 'package:nozelt/nozelt_design_system.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/profile.dart';
import '../l10n/nozelt_l10n.dart';
import '../l10n/user_error.dart';
import '../state/profiles_provider.dart';
import 'add_profile_screen.dart';

class ProfilesScreen extends ConsumerWidget {
  const ProfilesScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final asyncState = ref.watch(profilesProvider);
    return Scaffold(
      appBar: AppBar(title: Text(context.tr('profilesTitle'))),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => Navigator.of(
          context,
        ).push(MaterialPageRoute(builder: (_) => const AddProfileScreen())),
        icon: const Icon(Icons.add),
        label: Text(context.tr('addProfile')),
      ),
      body: asyncState.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (error, _) =>
            Center(child: Text(localizedUserError(context.l10n, error))),
        data: (state) {
          if (state.profiles.isEmpty) return const _EmptyState();
          return RefreshIndicator(
            onRefresh: () => _refreshAll(ref, state),
            child: ListView.builder(
              padding: const EdgeInsets.only(bottom: 88),
              itemCount: state.profiles.length,
              itemBuilder: (context, index) {
                final profile = state.profiles[index];
                return _ProfileCard(
                  profile: profile,
                  active: profile.id == state.activeId,
                );
              },
            ),
          );
        },
      ),
    );
  }

  Future<void> _refreshAll(WidgetRef ref, ProfilesState state) async {
    for (final profile in state.profiles) {
      if (profile.isSubscription) {
        try {
          await ref.read(profilesProvider.notifier).refresh(profile.id);
        } catch (_) {}
      }
    }
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState();

  @override
  Widget build(BuildContext context) => Center(
    child: Padding(
      padding: const EdgeInsets.all(32),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.dns_outlined, size: 48),
          const SizedBox(height: 12),
          Text(
            context.tr('profilesEmpty'),
            style: Theme.of(context).textTheme.titleMedium,
          ),
          const SizedBox(height: 4),
          Text(
            context.tr('profilesEmptyHint'),
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    ),
  );
}

class _ProfileCard extends ConsumerWidget {
  const _ProfileCard({required this.profile, required this.active});

  final Profile profile;
  final bool active;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final color = Theme.of(context).colorScheme.primary;
    return Card(
      margin: const EdgeInsets.fromLTRB(12, 6, 12, 6),
      clipBehavior: Clip.antiAlias,
      child: Stack(
        children: [
          ListTile(
            leading: Icon(
              _typeIcon(profile.type),
              color: active ? color : null,
            ),
            title: Text(
              profile.name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            subtitle: Text(
              '${_typeLabel(context, profile)} • '
              '${context.l10n.nodeCount(profile.nodes.length)} • '
              '${_ago(context, profile.updatedAt)}',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (!active)
                  TextButton(
                    onPressed: () => _setActive(context, ref),
                    child: Text(context.tr('use')),
                  ),
                NozeltPopupMenuButton<String>(
                  onSelected: (action) => _onAction(context, ref, action),
                  itemBuilder: (_) => [
                    if (profile.isSubscription)
                      PopupMenuItem(
                        value: 'refresh',
                        child: Text(context.tr('refresh')),
                      ),
                    PopupMenuItem(
                      value: 'rename',
                      child: Text(context.tr('rename')),
                    ),
                    PopupMenuItem(
                      value: 'delete',
                      child: Text(context.tr('delete')),
                    ),
                  ],
                ),
              ],
            ),
          ),
          if (active)
            Positioned(
              left: 0,
              top: 8,
              bottom: 8,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: color,
                  borderRadius: const BorderRadius.horizontal(
                    right: Radius.circular(4),
                  ),
                ),
                child: const SizedBox(width: 4),
              ),
            ),
        ],
      ),
    );
  }

  Future<void> _setActive(BuildContext context, WidgetRef ref) async {
    try {
      await ref.read(profilesProvider.notifier).setActive(profile.id);
    } catch (error) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(localizedUserError(context.l10n, error))),
      );
    }
  }

  Future<void> _onAction(
    BuildContext context,
    WidgetRef ref,
    String action,
  ) async {
    final notifier = ref.read(profilesProvider.notifier);
    final messenger = ScaffoldMessenger.of(context);
    final l10n = context.l10n;
    switch (action) {
      case 'refresh':
        messenger.showSnackBar(
          SnackBar(content: Text(context.tr('refreshingSubscription'))),
        );
        try {
          await notifier.refresh(profile.id);
          messenger.showSnackBar(
            SnackBar(content: Text(l10n.text('subscriptionUpdated'))),
          );
        } catch (error) {
          messenger.showSnackBar(
            SnackBar(
              content: Text(
                l10n.text('refreshError', {
                  'error': localizedUserError(l10n, error),
                }),
              ),
            ),
          );
        }
      case 'rename':
        final name = await _promptName(context, profile.name);
        if (name != null && name.trim().isNotEmpty) {
          await notifier.rename(profile.id, name.trim());
        }
      case 'delete':
        if (await _confirmDelete(context)) {
          try {
            await notifier.delete(profile.id);
          } catch (error) {
            if (!context.mounted) return;
            messenger.showSnackBar(
              SnackBar(content: Text(localizedUserError(l10n, error))),
            );
          }
        }
    }
  }

  Future<String?> _promptName(BuildContext context, String initial) {
    var input = initial;
    return showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(context.tr('renameProfile')),
        content: TextFormField(
          initialValue: input,
          onChanged: (value) => input = value,
          autofocus: true,
          inputFormatters: [
            LengthLimitingTextInputFormatter(maxProfileNameRunes),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: Text(context.tr('cancel')),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, input),
            child: Text(context.tr('save')),
          ),
        ],
      ),
    );
  }

  Future<bool> _confirmDelete(BuildContext context) async =>
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

  static IconData _typeIcon(ProfileType type) => switch (type) {
    ProfileType.manual => Icons.link,
    ProfileType.subscription => Icons.cloud_sync,
    ProfileType.file => Icons.description,
  };

  static String _typeLabel(BuildContext context, Profile profile) =>
      switch (profile.type) {
        ProfileType.manual => context.tr('manual'),
        ProfileType.subscription =>
          '${context.tr('subscription')}: ${_maskUrl(profile.source)}',
        ProfileType.file => context.tr('file'),
      };

  static String _maskUrl(String url) {
    try {
      final host = Uri.parse(url).host;
      return host.isEmpty ? 'subscription' : host;
    } catch (_) {
      return 'subscription';
    }
  }

  static String _ago(BuildContext context, DateTime? time) {
    if (time == null) return context.tr('neverUpdated');
    final difference = DateTime.now().difference(time);
    if (difference.inMinutes < 1) return context.tr('justNow');
    if (difference.inMinutes < 60) {
      return context.tr('minutesAgo', {'value': difference.inMinutes});
    }
    if (difference.inHours < 24) {
      return context.tr('hoursAgo', {'value': difference.inHours});
    }
    return context.tr('daysAgo', {'value': difference.inDays});
  }
}
