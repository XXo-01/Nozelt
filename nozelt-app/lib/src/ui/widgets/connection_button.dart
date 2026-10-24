import 'package:nozelt/nozelt_design_system.dart';
import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/models.dart';
import '../../l10n/nozelt_l10n.dart';
import '../../state/engine_provider.dart';

class ConnectionButton extends ConsumerWidget {
  const ConnectionButton({
    this.showUptime = false,
    this.useBrandLogo = false,
    super.key,
  });

  final bool showUptime;
  final bool useBrandLogo;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final engine = ref.watch(
      engineStateProvider.select(
        (state) => (
          connection: state.connection,
          startedAtUnix: state.status.startedAtUnix,
          recovering: state.status.recovering,
        ),
      ),
    );
    final initialUptimeSeconds = ref
        .read(engineStateProvider)
        .status
        .uptimeSeconds;
    final notifier = ref.read(engineStateProvider.notifier);
    final spec = _spec(
      engine.recovering ? EngineConnectionState.connecting : engine.connection,
      context,
    );
    final disconnecting =
        engine.connection == EngineConnectionState.disconnecting;
    final scheme = Theme.of(context).colorScheme;

    final state = engine.recovering
        ? EngineConnectionState.connecting
        : engine.connection;
    return Semantics(
      button: true,
      label: spec.label,
      child: _PowerButton(
        state: state,
        label: engine.recovering
            ? context.tr('connectionRecovering')
            : spec.label,
        // The ring carries the state; the glyph stays a power symbol.
        icon: state == EngineConnectionState.error
            ? Icons.refresh_rounded
            : Icons.power_settings_new_rounded,
        uptime: showUptime && state == EngineConnectionState.connected
            ? _UptimeLabel(
                key: ValueKey(engine.startedAtUnix),
                initialSeconds: initialUptimeSeconds,
                color: scheme.onSurface,
                fontSize: 15,
              )
            : null,
        onTap: disconnecting
            ? null
            : () => _handleTap(context, ref, engine.connection, notifier),
      ),
    );
  }

  Future<void> _handleTap(
    BuildContext context,
    WidgetRef ref,
    EngineConnectionState state,
    EngineNotifier notifier,
  ) async {
    switch (state) {
      case EngineConnectionState.disconnected:
      case EngineConnectionState.error:
        await notifier.connect();
      case EngineConnectionState.connected:
        if (await ref.read(nozeltEngineProvider).isAlwaysOnVpn()) {
          if (context.mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(content: Text(context.tr('disableAlwaysOnFirst'))),
            );
          }
          return;
        }
        await notifier.disconnect();
      case EngineConnectionState.connecting:
        await notifier.disconnect();
      case EngineConnectionState.disconnecting:
        break;
    }
  }

  _ButtonSpec _spec(EngineConnectionState state, BuildContext context) =>
      switch (state) {
        EngineConnectionState.disconnected => _ButtonSpec(
          label: context.tr('connect'),
          icon: Icons.power_settings_new_rounded,
          glow: Theme.of(context).colorScheme.primary,
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [
              Theme.of(context).colorScheme.surfaceContainerHighest,
              Theme.of(context).colorScheme.surface,
            ],
          ),
        ),
        EngineConnectionState.connecting => _ButtonSpec(
          label: context.tr('connecting'),
          icon: Icons.hourglass_top_rounded,
          glow: Theme.of(context).colorScheme.primary,
          gradient: LinearGradient(
            colors: [
              Theme.of(context).colorScheme.primary,
              Theme.of(context).colorScheme.primary,
            ],
          ),
        ),
        EngineConnectionState.connected => _ButtonSpec(
          label: context.tr('connected'),
          icon: Icons.shield_rounded,
          glow: context.nozelt.success,
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [
              Theme.of(context).colorScheme.primary,
              Theme.of(context).colorScheme.primary,
            ],
          ),
        ),
        EngineConnectionState.disconnecting => _ButtonSpec(
          label: context.tr('disconnecting'),
          icon: Icons.hourglass_bottom_rounded,
          glow: context.nozelt.warning,
          gradient: LinearGradient(
            colors: [context.nozelt.warning, context.nozelt.warning],
          ),
        ),
        EngineConnectionState.error => _ButtonSpec(
          label: context.tr('retry'),
          icon: Icons.refresh_rounded,
          glow: Theme.of(context).colorScheme.error,
          gradient: LinearGradient(
            colors: [
              Theme.of(context).colorScheme.error,
              Theme.of(context).colorScheme.error,
            ],
          ),
        ),
      };
}

/// Power button: a dark disc inside a thin ring. The ring shows the
/// state: grey when off, a spinning arc while switching, and a cyan-to-blue
/// gradient with a soft glow when connected.
class _PowerButton extends StatefulWidget {
  const _PowerButton({
    required this.state,
    required this.label,
    required this.icon,
    required this.uptime,
    required this.onTap,
  });

  final EngineConnectionState state;
  final String label;
  final IconData icon;
  final Widget? uptime;
  final VoidCallback? onTap;

  @override
  State<_PowerButton> createState() => _PowerButtonState();
}

class _PowerButtonState extends State<_PowerButton>
    with SingleTickerProviderStateMixin {
  late final AnimationController _spin = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1100),
  );

  bool get _busy =>
      widget.state == EngineConnectionState.connecting ||
      widget.state == EngineConnectionState.disconnecting;

  /// Stopping waits until the core has closed every connection. When that
  /// takes unusually long, say so instead of looking frozen.
  Timer? _slowStop;
  bool _stopIsSlow = false;

  void _watchStop() {
    final stopping = widget.state == EngineConnectionState.disconnecting;
    if (!stopping) {
      _slowStop?.cancel();
      _slowStop = null;
      _stopIsSlow = false;
    } else {
      _slowStop ??= Timer(const Duration(seconds: 15), () {
        if (mounted) setState(() => _stopIsSlow = true);
      });
    }
  }

  @override
  void initState() {
    super.initState();
    if (_busy) _spin.repeat();
    _watchStop();
  }

  @override
  void didUpdateWidget(covariant _PowerButton oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (_busy && !_spin.isAnimating) {
      _spin.repeat();
    } else if (!_busy && _spin.isAnimating) {
      _spin.stop();
    }
    _watchStop();
  }

  @override
  void dispose() {
    _slowStop?.cancel();
    _spin.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final dark = Theme.of(context).brightness == Brightness.dark;
    final connected = widget.state == EngineConnectionState.connected;
    final off = widget.state == EngineConnectionState.disconnected;
    // The same brand cyan in both themes; only text gets a deeper shade on
    // white so it stays readable.
    final brand = context.nozelt.glow;
    final accent = switch (widget.state) {
      EngineConnectionState.disconnected => scheme.onSurfaceVariant,
      EngineConnectionState.error => scheme.error,
      EngineConnectionState.disconnecting => context.nozelt.warning,
      _ => brand,
    };
    final textAccent = accent == brand && !dark
        ? const Color(0xFF0590C4)
        : accent;
    const disc = 172.0;
    return SizedBox.square(
      dimension: 208,
      child: Stack(
        alignment: Alignment.center,
        children: [
          // A soft glow only while the connection is protected.
          AnimatedOpacity(
            opacity: connected ? 1 : 0,
            duration: const Duration(milliseconds: 300),
            child: Container(
              width: disc,
              height: disc,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                boxShadow: [
                  BoxShadow(
                    color: brand.withValues(alpha: dark ? .28 : .24),
                    blurRadius: 42,
                    spreadRadius: 2,
                  ),
                ],
              ),
            ),
          ),
          RepaintBoundary(
            child: AnimatedBuilder(
              animation: _spin,
              builder: (context, _) => CustomPaint(
                size: const Size.square(disc + 16),
                painter: _PowerRingPainter(
                  track: scheme.outlineVariant,
                  colors: connected
                      ? [brand, scheme.secondary, brand]
                      : [accent, accent],
                  full:
                      connected || widget.state == EngineConnectionState.error,
                  arc: _busy,
                  rotation: _spin.value,
                ),
              ),
            ),
          ),
          SizedBox.square(
            dimension: disc,
            child: Material(
              shape: const CircleBorder(),
              clipBehavior: Clip.antiAlias,
              color: dark
                  ? scheme.surfaceContainerLow
                  : scheme.surfaceContainerLowest,
              child: InkWell(
                customBorder: const CircleBorder(),
                onTap: widget.onTap,
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    gradient: RadialGradient(
                      colors: [
                        accent.withValues(alpha: connected ? .16 : .05),
                        Colors.transparent,
                      ],
                    ),
                  ),
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(
                        widget.icon,
                        size: 44,
                        color: off ? scheme.onSurface : accent,
                      ),
                      const SizedBox(height: 10),
                      Text(
                        _stopIsSlow
                            ? context.tr('disconnectingSlow')
                            : widget.label,
                        textAlign: TextAlign.center,
                        style: Theme.of(context).textTheme.titleSmall?.copyWith(
                          color: off ? scheme.onSurface : textAccent,
                          fontSize: 17,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      if (widget.uptime != null) ...[
                        const SizedBox(height: 4),
                        widget.uptime!,
                      ],
                    ],
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _PowerRingPainter extends CustomPainter {
  const _PowerRingPainter({
    required this.track,
    required this.colors,
    required this.full,
    required this.arc,
    required this.rotation,
  });

  final Color track;
  final List<Color> colors;
  final bool full;
  final bool arc;
  final double rotation;

  static const _stroke = 4.0;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    final ring = rect.deflate(_stroke / 2);
    canvas.drawOval(
      ring,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = _stroke
        ..color = track,
    );
    if (!full && !arc) return;
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = _stroke
      ..strokeCap = StrokeCap.round
      ..shader = SweepGradient(
        colors: colors,
        transform: GradientRotation(rotation * 2 * math.pi),
      ).createShader(rect);
    if (full) {
      canvas.drawOval(ring, paint);
    } else {
      canvas.drawArc(
        ring,
        rotation * 2 * math.pi - math.pi / 2,
        math.pi * .6,
        false,
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(_PowerRingPainter old) =>
      old.track != track ||
      old.full != full ||
      old.arc != arc ||
      old.rotation != rotation ||
      !listEquals(old.colors, colors);
}

/// Advances the visible counter locally, so one-second native status snapshots
/// do not rebuild the complete power button and its blurred decorations.
class _UptimeLabel extends StatefulWidget {
  const _UptimeLabel({
    required this.initialSeconds,
    required this.color,
    this.fontSize,
    super.key,
  });

  final int initialSeconds;
  final Color color;
  final double? fontSize;

  @override
  State<_UptimeLabel> createState() => _UptimeLabelState();
}

class _UptimeLabelState extends State<_UptimeLabel> {
  late final Stopwatch _elapsed = Stopwatch()..start();
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    _elapsed.stop();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => RepaintBoundary(
    child: Text(
      _format(widget.initialSeconds + _elapsed.elapsed.inSeconds),
      style: Theme.of(context).textTheme.labelMedium?.copyWith(
        color: widget.color,
        fontSize: widget.fontSize,
        fontFeatures: const [FontFeature.tabularFigures()],
        fontWeight: FontWeight.w700,
      ),
    ),
  );

  static String _format(int seconds) {
    final safeSeconds = seconds < 0 ? 0 : seconds;
    final hours = safeSeconds ~/ 3600;
    final minutes = (safeSeconds % 3600) ~/ 60;
    final remaining = safeSeconds % 60;
    return '${hours.toString().padLeft(2, '0')}:'
        '${minutes.toString().padLeft(2, '0')}:'
        '${remaining.toString().padLeft(2, '0')}';
  }
}

class _ButtonSpec {
  const _ButtonSpec({
    required this.label,
    required this.icon,
    required this.glow,
    required this.gradient,
  });

  final String label;
  final IconData icon;
  final Color glow;
  final Gradient gradient;
}
