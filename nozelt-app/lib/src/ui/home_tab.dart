import 'package:flutter/material.dart';
import 'package:nozelt/nozelt_design_system.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/app_metadata.dart';
import '../core/models.dart';
import '../core/tun_settings.dart';
import '../l10n/nozelt_l10n.dart';
import '../l10n/user_error.dart';
import '../state/app_lifecycle_provider.dart';
import '../state/engine_provider.dart';
import '../state/profiles_provider.dart';
import '../state/routing_config_controller.dart';
import '../state/routing_profiles_provider.dart';
import 'widgets/connection_button.dart';
import 'widgets/home_cards.dart';
import 'widgets/latency_card.dart';

typedef _HomeProfileSummary = ({
  String? profileId,
  String? profileName,
  String? nodeName,
  String? nodeDisplayName,
  String flagEmoji,
});

final _homeProfileSummaryProvider = Provider.autoDispose<_HomeProfileSummary>((
  ref,
) {
  final active = ref.watch(profilesProvider).value?.active;
  final selectedNode = active?.selectedNode;
  return (
    profileId: active?.id,
    profileName: active?.name,
    nodeName: selectedNode?.name,
    nodeDisplayName: selectedNode?.displayName,
    flagEmoji: selectedNode?.flagEmoji ?? '🌐',
  );
});

class HomeTab extends ConsumerWidget {
  const HomeTab({
    required this.onOpenProxies,
    required this.isVisible,
    super.key,
  });

  final VoidCallback onOpenProxies;
  final bool isVisible;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // IndexedStack deliberately preserves the tab's scroll state, but an
    // invisible home tab must not subscribe to one-second engine/traffic ticks.
    if (!isVisible) return const SizedBox.shrink();
    final profile = ref.watch(_homeProfileSummaryProvider);
    final routingMode = ref.watch(
      routingProfilesProvider.select((state) => state.active.routingMode),
    );

    return SafeArea(
      bottom: false,
      child: ListView(
        key: const PageStorageKey<String>('home-scroll'),
        physics: const BouncingScrollPhysics(),
        padding: const EdgeInsets.fromLTRB(20, 18, 20, 124),
        children: [
          const _BrandHeader(),
          const SizedBox(height: 6),
          // A soft cyan spotlight behind the button, as on Windows.
          Center(
            child: DecoratedBox(
              decoration: BoxDecoration(
                gradient: RadialGradient(
                  colors: [
                    context.nozelt.glow.withValues(alpha: .07),
                    context.nozelt.glow.withValues(alpha: 0),
                  ],
                ),
              ),
              child: const Padding(
                padding: EdgeInsets.symmetric(horizontal: 48, vertical: 4),
                child: ConnectionButton(showUptime: true, useBrandLogo: true),
              ),
            ),
          ),
          const SizedBox(height: 18),
          NozeltCurrentProxyCard(
            profileName: profile.profileName,
            nodeName: profile.profileId == null
                ? null
                : profile.nodeDisplayName,
            flag: profile.flagEmoji,
            onTap: onOpenProxies,
          ),
          const SizedBox(height: NozeltSpacing.md),
          LatencyCard(profileId: profile.profileId, nodeName: profile.nodeName),
          const SizedBox(height: NozeltSpacing.md),
          const _TrafficSection(),
          const SizedBox(height: NozeltSpacing.md),
          NozeltRoutingModeCard(
            selected: routingMode,
            onSelected: (mode) => _setRoutingMode(context, ref, mode),
          ),
        ],
      ),
    );
  }

  Future<void> _setRoutingMode(
    BuildContext context,
    WidgetRef ref,
    RoutingMode mode,
  ) async {
    try {
      await ref.read(routingConfigControllerProvider).setMode(mode);
    } catch (error) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(localizedUserError(context.l10n, error))),
      );
    }
  }
}

/// Isolates one-second traffic updates from the brand, connection button,
/// selected-node card and routing controls above it.
class _TrafficSection extends ConsumerWidget {
  const _TrafficSection();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final connected = ref.watch(
      engineStateProvider.select(
        (state) => state.connection == EngineConnectionState.connected,
      ),
    );
    final resumed = ref.watch(appResumedProvider);
    final traffic = connected && resumed
        ? ref
              .watch(trafficStreamProvider)
              .maybeWhen(data: (value) => value, orElse: () => Traffic.zero)
        : Traffic.zero;

    return NozeltTrafficRow(traffic: traffic);
  }
}

class _BrandHeader extends StatelessWidget {
  const _BrandHeader();

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Transform.scale(
          scale: 1.1,
          alignment: Alignment.bottomCenter,
          child: ClipRRect(
            borderRadius: BorderRadius.circular(14),
            child: Image.asset(
              'assets/branding/nozelt_new_logo.png',
              width: 58,
              height: 58,
              filterQuality: FilterQuality.high,
            ),
          ),
        ),
        const SizedBox(width: 14),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Nozelt',
                style: Theme.of(context).textTheme.headlineMedium?.copyWith(
                  fontFamily: 'Runzoe',
                  fontSize: 34,
                  fontWeight: FontWeight.w400,
                  letterSpacing: 0.2,
                  height: 0.88,
                ),
              ),
              Text(
                AppMetadata.version,
                style: Theme.of(context).textTheme.titleMedium?.copyWith(
                  color: Theme.of(context).colorScheme.primary,
                  fontFamily: 'Runzoe',
                  fontStyle: FontStyle.italic,
                  fontWeight: FontWeight.w400,
                  letterSpacing: 0.6,
                  height: 0.82,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}
