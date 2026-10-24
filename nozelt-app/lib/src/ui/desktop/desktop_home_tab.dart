import 'package:nozelt/nozelt_design_system.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/models.dart';
import '../../core/tun_settings.dart';
import '../../l10n/nozelt_l10n.dart';
import '../../l10n/user_error.dart';
import '../../state/engine_provider.dart';
import '../../state/profiles_provider.dart';
import '../../state/routing_config_controller.dart';
import '../../state/settings_provider.dart';
import '../widgets/connection_button.dart';
import '../widgets/home_cards.dart';
import '../widgets/latency_card.dart';

class DesktopHomeTab extends ConsumerWidget {
  const DesktopHomeTab({required this.onOpenProxies, super.key});

  final VoidCallback onOpenProxies;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final engine = ref.watch(engineStateProvider);
    final active = ref.watch(profilesProvider).value?.active;
    final node = active?.selectedNode;
    final settings = ref.watch(tunSettingsProvider);
    final traffic = engine.connection == EngineConnectionState.connected
        ? ref
              .watch(trafficStreamProvider)
              .maybeWhen(data: (value) => value, orElse: () => Traffic.zero)
        : Traffic.zero;

    final hero = Center(
      // A soft cyan spotlight behind the button, like the sidebar tint.
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
          padding: EdgeInsets.symmetric(horizontal: 120),
          child: ConnectionButton(showUptime: true, useBrandLogo: true),
        ),
      ),
    );
    // One block per row, like Android: the button, server, latency, then
    // traffic and routing.
    final summary = <Widget>[
      NozeltPageHeader(title: context.tr('mainTab')),
      hero,
      Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          NozeltCurrentProxyCard(
            profileName: active?.name,
            nodeName: node?.displayName,
            flag: node?.flagEmoji,
            onTap: onOpenProxies,
          ),
          const SizedBox(height: NozeltSpacing.md),
          LatencyCard(profileId: active?.id, nodeName: node?.name),
        ],
      ),
    ];

    return NozeltPageInsets(
      builder: (context, insets) => LayoutBuilder(
        builder: (context, constraints) {
          final scale = MediaQuery.textScalerOf(context).scale(14) / 14;
          // In a short window the button, server and latency fill the first
          // screen exactly, so the traffic row starts below the fold instead
          // of peeking out as a cut-off strip.
          final fold = constraints.maxHeight < 600 * scale;
          return SingleChildScrollView(
            padding: insets,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (fold)
                  ConstrainedBox(
                    constraints: BoxConstraints(
                      minHeight:
                          constraints.maxHeight - insets.top - NozeltSpacing.xl,
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: summary,
                    ),
                  )
                else ...[
                  summary[0],
                  const SizedBox(height: NozeltSpacing.xxl),
                  summary[1],
                  const SizedBox(height: NozeltSpacing.xxl),
                  summary[2],
                ],
                SizedBox(
                  height: fold
                      ? NozeltSpacing.xl + NozeltSpacing.md
                      : NozeltSpacing.md,
                ),
                NozeltTrafficRow(traffic: traffic),
                const SizedBox(height: NozeltSpacing.md),
                NozeltRoutingModeCard(
                  selected: settings.routingMode,
                  onSelected: (mode) => _setMode(context, ref, mode),
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  Future<void> _setMode(
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
