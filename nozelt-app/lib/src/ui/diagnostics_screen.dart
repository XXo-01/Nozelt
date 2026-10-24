import 'package:nozelt/nozelt_design_system.dart';
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/models.dart';
import '../core/nozelt_engine.dart';
import '../l10n/nozelt_l10n.dart';
import '../state/engine_provider.dart';

final _diagnosticsStatusProvider =
    FutureProvider.autoDispose<_DiagnosticsSnapshot>((ref) async {
      final engine = ref.watch(nozeltEngineProvider);
      final status = await engine.getStatus();
      final policy = await engine.getVpnPolicyState();
      return _DiagnosticsSnapshot(status: status, policy: policy);
    });

class _DiagnosticsSnapshot {
  const _DiagnosticsSnapshot({required this.status, required this.policy});

  final Status status;
  final VpnPolicyState policy;
}

/// A deliberately secret-free runtime report. It exposes only aggregate
/// engine state and security invariants; profiles, endpoints, DNS queries,
/// logs, and application lists never enter this screen or its clipboard text.
class DiagnosticsScreen extends ConsumerWidget {
  const DiagnosticsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final status = ref.watch(_diagnosticsStatusProvider);
    return Scaffold(
      appBar: Theme.of(context).platform == TargetPlatform.windows
          ? NozeltDesktopAppBar(
              title: Text(context.tr('diagnostics')),
              actions: [
                IconButton(
                  tooltip: context.tr('refreshDiagnostics'),
                  onPressed: () => ref.invalidate(_diagnosticsStatusProvider),
                  icon: const Icon(Icons.refresh_rounded),
                ),
              ],
            )
          : AppBar(
              title: Text(context.tr('diagnostics')),
              actions: [
                IconButton(
                  tooltip: context.tr('refreshDiagnostics'),
                  onPressed: () => ref.invalidate(_diagnosticsStatusProvider),
                  icon: const Icon(Icons.refresh_rounded),
                ),
                const SizedBox(width: 8),
              ],
            ),
      body: NozeltEditorBody(
        child: status.when(
          loading: () => const Center(child: CircularProgressIndicator()),
          error: (_, _) => _DiagnosticsError(
            onRetry: () => ref.invalidate(_diagnosticsStatusProvider),
          ),
          data: (value) =>
              _DiagnosticsContent(status: value.status, policy: value.policy),
        ),
      ),
    );
  }
}

class _DiagnosticsContent extends StatelessWidget {
  const _DiagnosticsContent({required this.status, required this.policy});

  final Status status;
  final VpnPolicyState policy;

  bool get _hasOpenListener {
    final listeners = status.listeners;
    return listeners.mixedPort != 0 ||
        listeners.httpPort != 0 ||
        listeners.socksPort != 0 ||
        listeners.redirPort != 0 ||
        listeners.tproxyPort != 0;
  }

  bool get _privacyHealthy =>
      !_hasOpenListener &&
      status.protectionFailures == 0 &&
      (!status.running ||
          (status.tun.enabled &&
              (defaultTargetPlatform == TargetPlatform.windows
                  ? status.networkGuard
                  : status.socketProtection) &&
              (!policy.lockdownKnown || policy.lockdown)));

  @override
  Widget build(BuildContext context) {
    return NozeltPageInsets(
      top: NozeltSpacing.sm,
      builder: (context, insets) => ListView(
        physics: const BouncingScrollPhysics(),
        padding: Theme.of(context).platform == TargetPlatform.windows
            ? insets
            : const EdgeInsets.fromLTRB(20, 12, 20, 32),
        children: [
          NozeltSectionTitle(context.tr('diagnosticsPrivacy')),
          const SizedBox(height: 10),
          NozeltSurface(
            child: Column(
              children: [
                _SummaryBanner(healthy: _privacyHealthy),
                const SizedBox(height: 14),
                _DiagnosticRow(
                  icon: Icons.router_rounded,
                  title: context.tr('localListeners'),
                  value: context.tr(
                    _hasOpenListener ? 'listenersOpen' : 'listenersClosed',
                  ),
                  healthy: !_hasOpenListener,
                ),
                const Divider(height: 22),
                _DiagnosticRow(
                  icon: Icons.shield_outlined,
                  title: context.tr('socketProtection'),
                  value: context.tr(
                    (defaultTargetPlatform == TargetPlatform.windows
                            ? status.networkGuard
                            : status.socketProtection)
                        ? 'socketProtectionOn'
                        : status.running
                        ? 'socketProtectionMissing'
                        : 'socketProtectionOff',
                  ),
                  healthy: !status.running || status.socketProtection,
                ),
                const Divider(height: 22),
                _DiagnosticRow(
                  icon: Icons.vpn_lock_rounded,
                  title: context.tr('tunInterface'),
                  value: context.tr(status.tun.enabled ? 'active' : 'inactive'),
                  healthy: !status.running || status.tun.enabled,
                ),
                const Divider(height: 22),
                _DiagnosticRow(
                  icon: Icons.phonelink_lock_rounded,
                  title: context.tr('systemKillSwitch'),
                  value: context.tr(
                    defaultTargetPlatform == TargetPlatform.windows &&
                            status.networkGuard
                        ? 'killSwitchOn'
                        : !policy.lockdownKnown
                        ? (defaultTargetPlatform == TargetPlatform.windows
                              ? 'killSwitchWindowsUnknown'
                              : 'killSwitchUnknown')
                        : policy.lockdown
                        ? 'killSwitchOn'
                        : 'killSwitchOff',
                  ),
                  healthy:
                      defaultTargetPlatform == TargetPlatform.windows &&
                          status.networkGuard
                      ? true
                      : !policy.lockdownKnown &&
                            defaultTargetPlatform == TargetPlatform.windows
                      ? null
                      : !status.running ||
                            !policy.lockdownKnown ||
                            policy.lockdown,
                ),
                const Divider(height: 22),
                _DiagnosticRow(
                  icon: Icons.error_outline_rounded,
                  title: context.tr('protectionFailures'),
                  value: status.protectionFailures.toString(),
                  healthy: status.protectionFailures == 0,
                ),
              ],
            ),
          ),
          const SizedBox(height: 22),
          NozeltSectionTitle(context.tr('diagnosticsRuntime')),
          const SizedBox(height: 10),
          NozeltSurface(
            padding: EdgeInsets.zero,
            child: Column(
              children: [
                _ValueTile(
                  title: context.tr('engineState'),
                  value: context.tr(status.running ? 'running' : 'stopped'),
                ),
                _ValueTile(
                  title: context.tr('networkStackValue'),
                  value: status.tun.stack.isEmpty ? '—' : status.tun.stack,
                ),
                _ValueTile(
                  title: context.tr('routingModeValue'),
                  value: status.mode.isEmpty ? '—' : status.mode,
                ),
                _ValueTile(
                  title: context.tr('uptime'),
                  value: _formatDuration(status.uptimeSeconds),
                ),
                _ValueTile(
                  title: context.tr('activeConnections'),
                  value: status.connectionsCount.toString(),
                ),
                _ValueTile(
                  title: context.tr('protectedSockets'),
                  value: status.protectedSockets.toString(),
                ),
                _ValueTile(
                  title: context.tr('openFileDescriptors'),
                  value: status.openFileDescriptors < 0
                      ? '—'
                      : status.openFileDescriptors.toString(),
                ),
                _ValueTile(
                  title: context.tr('goRoutines'),
                  value: status.goRoutines.toString(),
                ),
                _ValueTile(title: 'mihomo', value: status.mihomoVersion),
                _ValueTile(
                  title: 'Nozelt Core',
                  value: status.nozeltCoreVersion,
                  last: true,
                ),
              ],
            ),
          ),
          const SizedBox(height: 14),
          Text(
            context.tr('diagnosticsNoSecrets'),
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 16),
          FilledButton.icon(
            onPressed: () => _copyReport(context),
            icon: const Icon(Icons.copy_rounded),
            label: Text(context.tr('copyDiagnostics')),
          ),
        ],
      ),
    );
  }

  Future<void> _copyReport(BuildContext context) async {
    final listeners = status.listeners;
    final report = <String>[
      'Nozelt safe diagnostics',
      'running=${status.running}',
      'mihomo=${status.mihomoVersion}',
      'nozeltCore=${status.nozeltCoreVersion}',
      'mode=${status.mode}',
      'tun.enabled=${status.tun.enabled}',
      'tun.stack=${status.tun.stack}',
      'socketProtection=${status.socketProtection}',
      'protectedSockets=${status.protectedSockets}',
      'protectionFailures=${status.protectionFailures}',
      'alwaysOn=${policy.alwaysOn}',
      'lockdown=${policy.lockdown}',
      'lockdownKnown=${policy.lockdownKnown}',
      'listeners=mixed:${listeners.mixedPort},http:${listeners.httpPort},socks:${listeners.socksPort},redir:${listeners.redirPort},tproxy:${listeners.tproxyPort}',
      'connections=${status.connectionsCount}',
      'openFileDescriptors=${status.openFileDescriptors}',
      'goRoutines=${status.goRoutines}',
      'uptimeSeconds=${status.uptimeSeconds}',
    ].join('\n');
    await Clipboard.setData(ClipboardData(text: report));
    if (context.mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(context.tr('diagnosticsCopied'))));
    }
  }
}

class _SummaryBanner extends StatelessWidget {
  const _SummaryBanner({required this.healthy});

  final bool healthy;

  @override
  Widget build(BuildContext context) {
    final color = healthy ? context.nozelt.success : context.nozelt.warning;
    return Container(
      padding: const EdgeInsets.all(13),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: color.withValues(alpha: 0.3)),
      ),
      child: Row(
        children: [
          Icon(
            healthy ? Icons.verified_user_rounded : Icons.warning_amber_rounded,
            color: color,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              context.tr(
                healthy ? 'privacyChecksPassed' : 'privacyCheckWarning',
              ),
              style: TextStyle(color: color, fontWeight: FontWeight.w700),
            ),
          ),
        ],
      ),
    );
  }
}

class _DiagnosticRow extends StatelessWidget {
  const _DiagnosticRow({
    required this.icon,
    required this.title,
    required this.value,
    required this.healthy,
  });

  final IconData icon;
  final String title;
  final String value;
  final bool? healthy;

  @override
  Widget build(BuildContext context) {
    final color = healthy == null
        ? Theme.of(context).colorScheme.onSurfaceVariant
        : healthy!
        ? context.nozelt.success
        : context.nozelt.warning;
    return Row(
      children: [
        Icon(icon, size: 21, color: color),
        const SizedBox(width: 11),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title, style: Theme.of(context).textTheme.bodyMedium),
              const SizedBox(height: 2),
              Text(
                value,
                style: Theme.of(
                  context,
                ).textTheme.bodySmall?.copyWith(color: color),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _ValueTile extends StatelessWidget {
  const _ValueTile({
    required this.title,
    required this.value,
    this.last = false,
  });

  final String title;
  final String value;
  final bool last;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        ListTile(
          dense: true,
          title: Text(title),
          trailing: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 150),
            child: Text(
              value,
              textAlign: TextAlign.end,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          ),
        ),
        if (!last) const Divider(height: 1, indent: 16, endIndent: 16),
      ],
    );
  }
}

class _DiagnosticsError extends StatelessWidget {
  const _DiagnosticsError({required this.onRetry});

  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.error_outline_rounded, size: 44),
            const SizedBox(height: 12),
            Text(context.tr('diagnosticsUnavailable')),
            const SizedBox(height: 14),
            FilledButton(onPressed: onRetry, child: Text(context.tr('retry'))),
          ],
        ),
      ),
    );
  }
}

String _formatDuration(int seconds) {
  final safe = seconds < 0 ? 0 : seconds;
  final hours = safe ~/ 3600;
  final minutes = (safe % 3600) ~/ 60;
  final remainingSeconds = safe % 60;
  return '${hours.toString().padLeft(2, '0')}:'
      '${minutes.toString().padLeft(2, '0')}:'
      '${remainingSeconds.toString().padLeft(2, '0')}';
}
