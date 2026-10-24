import 'package:flutter/material.dart';

import '../../l10n/nozelt_l10n.dart';
import '../design_system/nozelt_controls.dart';
import '../design_system/nozelt_tokens.dart';

class NozeltPageHeader extends StatelessWidget {
  const NozeltPageHeader({
    required this.title,
    this.subtitle,
    this.trailing,
    super.key,
  });

  final String title;
  final String? subtitle;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final heading = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(title, style: Theme.of(context).textTheme.headlineMedium),
        if (subtitle != null) ...[
          const SizedBox(height: 4),
          Text(
            subtitle!,
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ],
    );
    return LayoutBuilder(
      builder: (context, constraints) {
        if (trailing != null &&
            (constraints.maxWidth < 340 ||
                MediaQuery.textScalerOf(context).scale(14) > 20)) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              heading,
              const SizedBox(height: 12),
              Align(alignment: Alignment.centerLeft, child: trailing!),
            ],
          );
        }
        return Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Expanded(child: heading),
            if (trailing != null) ...[const SizedBox(width: 12), trailing!],
          ],
        );
      },
    );
  }
}

class NozeltSectionTitle extends StatelessWidget {
  const NozeltSectionTitle(this.title, {this.trailing, super.key});

  final String title;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(
          child: Text(title, style: Theme.of(context).textTheme.titleMedium),
        ),
        ?trailing,
      ],
    );
  }
}

class NozeltSurface extends StatelessWidget {
  const NozeltSurface({
    required this.child,
    this.padding = const EdgeInsets.all(16),
    this.onTap,
    this.color,
    this.outlined = true,
    super.key,
  });

  final Widget child;
  final EdgeInsetsGeometry padding;
  final VoidCallback? onTap;
  final Color? color;
  final bool outlined;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    // Cards share a faint cyan tint from the top left on every platform.
    final sheen = color == null;
    final body = Padding(padding: padding, child: child);
    final content = sheen
        ? Ink(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [
                  Color.alphaBlend(
                    context.nozelt.glow.withValues(alpha: .045),
                    scheme.surface,
                  ),
                  scheme.surface,
                ],
              ),
            ),
            child: body,
          )
        : body;
    return Material(
      color: color ?? scheme.surface,
      clipBehavior: Clip.antiAlias,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(context.nozelt.cardRadius),
        side: BorderSide(
          color: outlined
              ? Theme.of(context).colorScheme.outlineVariant
              : Colors.transparent,
          width: 0.7,
        ),
      ),
      child: onTap == null
          ? content
          : InkWell(
              borderRadius: BorderRadius.circular(context.nozelt.cardRadius),
              onTap: onTap,
              child: content,
            ),
    );
  }
}

/// A tinted square behind an icon, as on the Windows home cards: a soft
/// gradient of [color] with a thin outline of the same hue.
class NozeltIconBadge extends StatelessWidget {
  const NozeltIconBadge({
    required this.icon,
    required this.color,
    this.size = 40,
    super.key,
  });

  final Widget icon;
  final Color color;
  final double size;

  @override
  Widget build(BuildContext context) => Container(
    width: size,
    height: size,
    alignment: Alignment.center,
    decoration: BoxDecoration(
      borderRadius: BorderRadius.circular(context.nozelt.controlRadius),
      gradient: LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        colors: [color.withValues(alpha: .22), color.withValues(alpha: .07)],
      ),
      border: Border.all(color: color.withValues(alpha: .22)),
    ),
    child: IconTheme.merge(
      data: IconThemeData(color: color, size: 20),
      child: icon,
    ),
  );
}

/// Related settings in one clipped surface with a shared heading.
class NozeltSettingsGroup extends StatelessWidget {
  const NozeltSettingsGroup({
    required this.title,
    required this.children,
    this.icon,
    super.key,
  });
  final String title;
  final List<Widget> children;
  final IconData? icon;

  @override
  Widget build(BuildContext context) => NozeltSurface(
    padding: EdgeInsets.zero,
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.all(NozeltSpacing.lg),
          child: Row(
            children: [
              if (icon != null) ...[
                Icon(
                  icon,
                  size: NozeltLayout.icon,
                  color: Theme.of(context).colorScheme.primary,
                ),
                const SizedBox(width: NozeltSpacing.md),
              ],
              Expanded(
                child: Text(
                  title,
                  style: Theme.of(context).textTheme.titleSmall,
                ),
              ),
            ],
          ),
        ),
        const Divider(height: 1),
        for (var i = 0; i < children.length; i++) ...[
          if (i > 0)
            const Divider(
              height: 1,
              indent: NozeltSpacing.lg,
              endIndent: NozeltSpacing.lg,
            ),
          Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: NozeltSpacing.lg,
              vertical: NozeltSpacing.sm,
            ),
            child: children[i],
          ),
        ],
      ],
    ),
  );
}

/// A settings editor with a persistent label and responsive composition.
class NozeltSettingsField extends StatelessWidget {
  const NozeltSettingsField({
    required this.label,
    required this.child,
    this.help,
    this.controlMaxWidth = double.infinity,
    super.key,
  });
  final String label;
  final Widget child;
  final String? help;
  final double controlMaxWidth;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final caption = Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Flexible(
            child: Text(label, style: Theme.of(context).textTheme.bodyMedium),
          ),
          if (help != null)
            IconButton(
              tooltip: help,
              icon: const Icon(Icons.info_outline_rounded, size: 16),
              onPressed: () => showDialog<void>(
                context: context,
                builder: (context) => AlertDialog(
                  title: Text(label),
                  content: NozeltDialogBody(child: Text(help!)),
                  actions: [
                    TextButton(
                      onPressed: () => Navigator.pop(context),
                      child: Text(context.tr('appearanceClose')),
                    ),
                  ],
                ),
              ),
            ),
        ],
      );
      final control = Semantics(label: label, child: child);
      final desktop = Theme.of(context).platform == TargetPlatform.windows;
      if (constraints.maxWidth >= (desktop ? 520 : 640) &&
          MediaQuery.textScalerOf(context).scale(14) <= 19) {
        return Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            SizedBox(
              width: desktop
                  ? (constraints.maxWidth * .38).clamp(180.0, 280.0)
                  : 224,
              child: caption,
            ),
            const SizedBox(width: NozeltSpacing.lg),
            Expanded(
              child: Align(
                alignment: Alignment.centerRight,
                child: ConstrainedBox(
                  constraints: BoxConstraints(maxWidth: controlMaxWidth),
                  child: control,
                ),
              ),
            ),
          ],
        );
      }
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          caption,
          const SizedBox(height: NozeltSpacing.sm),
          control,
        ],
      );
    },
  );
}

/// Keeps a page-level save action visible while the editable content scrolls.
/// On Windows each page places its own content in the shared desktop column
/// with [NozeltPageInsets], so the scrollable can stay full width.
class NozeltEditorBody extends StatelessWidget {
  const NozeltEditorBody({required this.child, super.key});
  final Widget child;

  @override
  Widget build(BuildContext context) => child;
}

/// Capsule borders for single-line search fields.
InputDecoration nozeltSearchDecoration(
  BuildContext context,
  InputDecoration decoration,
) {
  final theme = Theme.of(context);
  OutlineInputBorder capsule(Color color, [double width = 1]) =>
      OutlineInputBorder(
        borderRadius: BorderRadius.circular(999),
        borderSide: BorderSide(color: color, width: width),
      );
  final scheme = theme.colorScheme;
  return decoration.copyWith(
    border: capsule(scheme.outlineVariant),
    enabledBorder: capsule(scheme.outlineVariant),
    focusedBorder: capsule(scheme.primary, NozeltStates.focusBorderWidth),
  );
}

/// Icon actions that should read as buttons (ping, refresh, more): a round
/// button with a thin outline.
ButtonStyle? nozeltOutlinedIconStyle(BuildContext context) {
  final theme = Theme.of(context);
  return IconButton.styleFrom(
    shape: const CircleBorder(),
    side: BorderSide(color: theme.colorScheme.outlineVariant),
    backgroundColor: theme.colorScheme.surface,
    // The circle itself is the touch target. Android's padded 48 dp target
    // otherwise spread neighbouring round buttons twice as far apart as on
    // Windows.
    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
  );
}

/// Accent for decorative icons: the brand cyan in both themes.
Color nozeltIconAccent(BuildContext context) => context.nozelt.glow;

/// Gives a Windows page body the insets of the shared, centred content column.
/// Pass the insets to a full-width scroll view's padding, or use them directly
/// for a fixed body such as a search field above a list.
class NozeltPageInsets extends StatelessWidget {
  const NozeltPageInsets({
    required this.builder,
    this.top = NozeltLayout.desktopPageTop,
    this.bottom = NozeltLayout.desktopGutter,
    super.key,
  });

  final Widget Function(BuildContext context, EdgeInsets insets) builder;
  final double top;
  final double bottom;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) => builder(
      context,
      NozeltLayout.desktopInsets(
        constraints.maxWidth,
        top: top,
        bottom: bottom,
      ),
    ),
  );
}

/// Windows header of a nested page: back action, title and actions aligned to
/// the same column as the page content, instead of the window edge.
class NozeltDesktopAppBar extends StatelessWidget
    implements PreferredSizeWidget {
  const NozeltDesktopAppBar({
    required this.title,
    this.actions = const [],
    this.bottom,
    super.key,
  });

  final Widget title;
  final List<Widget> actions;
  final PreferredSizeWidget? bottom;

  static const _barHeight = 76.0;

  @override
  Size get preferredSize =>
      Size.fromHeight(_barHeight + (bottom?.preferredSize.height ?? 0));

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final canPop = ModalRoute.of(context)?.impliesAppBarDismissal ?? false;
    return Material(
      color: theme.scaffoldBackgroundColor,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final insets = NozeltLayout.desktopInsets(constraints.maxWidth);
          return Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              SizedBox(
                height: _barHeight,
                child: Padding(
                  // Icon buttons keep 8 px of their own padding, so glyphs line
                  // up with the column edge.
                  padding: EdgeInsets.fromLTRB(
                    insets.left - NozeltSpacing.sm,
                    NozeltSpacing.xl,
                    insets.right - NozeltSpacing.sm,
                    NozeltSpacing.sm,
                  ),
                  child: Row(
                    children: [
                      if (canPop) ...[
                        // A round, outlined back button like the other capsules.
                        IconButton(
                          tooltip: MaterialLocalizations.of(
                            context,
                          ).backButtonTooltip,
                          onPressed: () => Navigator.of(context).maybePop(),
                          style: IconButton.styleFrom(
                            backgroundColor: theme.colorScheme.surface,
                            side: BorderSide(
                              color: theme.colorScheme.outlineVariant,
                            ),
                          ),
                          icon: const Icon(Icons.arrow_back_rounded),
                        ),
                        const SizedBox(width: NozeltSpacing.sm),
                      ] else
                        const SizedBox(width: NozeltSpacing.sm),
                      Expanded(
                        child: DefaultTextStyle.merge(
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.titleLarge?.copyWith(
                            fontSize: 22,
                            fontWeight: FontWeight.w600,
                            color: theme.colorScheme.onSurface,
                          ),
                          child: title,
                        ),
                      ),
                      if (actions.isNotEmpty) ...[
                        const SizedBox(width: NozeltSpacing.md),
                        ...actions,
                      ],
                    ],
                  ),
                ),
              ),
              if (bottom != null)
                Padding(
                  padding: EdgeInsets.only(
                    left: insets.left,
                    right: insets.right,
                  ),
                  child: bottom,
                ),
            ],
          );
        },
      ),
    );
  }
}

/// Gives AlertDialog a finite intrinsic width before responsive children are
/// laid out, and lets a long form scroll without hiding the dialog's actions.
class NozeltDialogBody extends StatelessWidget {
  const NozeltDialogBody({required this.child, super.key});
  final Widget child;

  @override
  Widget build(BuildContext context) => SizedBox(
    width: NozeltLayout.dialogMaxWidth,
    child: SingleChildScrollView(child: child),
  );
}

/// Keeps page-level actions outside the scrolling form.
class NozeltPageSaveBar extends StatelessWidget {
  const NozeltPageSaveBar({
    required this.onPressed,
    this.saving = false,
    this.onCancel,
    super.key,
  });

  final VoidCallback? onPressed;
  final bool saving;
  final VoidCallback? onCancel;

  @override
  Widget build(BuildContext context) {
    final desktop = Theme.of(context).platform == TargetPlatform.windows;
    if (desktop) return _desktop(context);
    final buttons = Row(
      children: [
        if (onCancel != null) ...[
          Expanded(
            child: NozeltButton(
              variant: NozeltButtonVariant.secondary,
              onPressed: saving ? null : onCancel,
              label: context.tr('cancel'),
            ),
          ),
          const SizedBox(width: 12),
        ],
        Expanded(
          child: NozeltButton(
            onPressed: onPressed,
            loading: saving,
            icon: const Icon(Icons.save_rounded),
            label: context.tr('save'),
          ),
        ),
      ],
    );
    return Material(
      color: Theme.of(context).scaffoldBackgroundColor,
      child: DecoratedBox(
        decoration: BoxDecoration(
          border: Border(
            top: BorderSide(
              color: Theme.of(context).colorScheme.outlineVariant,
            ),
          ),
        ),
        child: SafeArea(
          top: false,
          minimum: const EdgeInsets.fromLTRB(20, 10, 20, 12),
          child: Align(
            alignment: Alignment.centerRight,
            heightFactor: 1,
            child: SizedBox(width: double.infinity, child: buttons),
          ),
        ),
      ),
    );
  }

  /// Windows: no divider; Cancel and Save share one floating capsule at the
  /// right edge of the content column.
  Widget _desktop(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: Theme.of(context).scaffoldBackgroundColor,
      child: NozeltPageInsets(
        top: NozeltSpacing.sm,
        bottom: NozeltSpacing.lg,
        builder: (context, insets) => Padding(
          padding: insets,
          child: Align(
            alignment: Alignment.centerRight,
            heightFactor: 1,
            child: DecoratedBox(
              decoration: ShapeDecoration(
                shape: StadiumBorder(
                  side: BorderSide(color: scheme.outlineVariant),
                ),
                color: scheme.surface,
                shadows: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: .18),
                    blurRadius: 18,
                    offset: const Offset(0, 6),
                  ),
                ],
              ),
              child: Padding(
                padding: const EdgeInsets.all(NozeltSpacing.xs),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (onCancel != null) ...[
                      NozeltButton(
                        variant: NozeltButtonVariant.tertiary,
                        onPressed: saving ? null : onCancel,
                        label: context.tr('cancel'),
                      ),
                      const SizedBox(width: NozeltSpacing.xs),
                    ],
                    NozeltButton(
                      onPressed: onPressed,
                      loading: saving,
                      icon: const Icon(Icons.save_rounded),
                      label: context.tr('save'),
                    ),
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

class NozeltShieldIcon extends StatelessWidget {
  const NozeltShieldIcon({
    this.size = 24,
    this.color,
    this.lineWidth,
    this.preserveInnerContour = false,
    super.key,
  });

  final double size;
  final Color? color;
  final double? lineWidth;
  final bool preserveInnerContour;

  @override
  Widget build(BuildContext context) => SizedBox(
    width: size,
    height: size,
    child: CustomPaint(
      painter: _NozeltShieldPainter(
        color ?? Theme.of(context).colorScheme.primary,
        lineWidth: lineWidth,
        preserveInnerContour: preserveInnerContour,
      ),
    ),
  );
}

class _NozeltShieldPainter extends CustomPainter {
  const _NozeltShieldPainter(
    this.color, {
    this.lineWidth,
    required this.preserveInnerContour,
  });

  final Color color;
  final double? lineWidth;
  final bool preserveInnerContour;

  static const _viewBoxSize = 445.87;
  static const _originalLineWidth = 54.2;
  static final Path _shield = Path()
    ..moveTo(222.935, 35)
    ..cubicTo(277, 78, 347, 94, 418.77, 94.4)
    ..cubicTo(418.77, 148, 410, 201, 388, 254)
    ..cubicTo(359, 323, 310, 373, 222.935, 415.63)
    ..cubicTo(135.87, 373, 86.87, 323, 57.87, 254)
    ..cubicTo(35.87, 201, 27.1, 148, 27.1, 94.4)
    ..cubicTo(98.87, 94, 168.87, 78, 222.935, 35)
    ..close();
  static final Path _cross = Path()
    ..moveTo(225.61, 295.55)
    ..relativeLineTo(0.14, -48.14)
    ..relativeLineTo(46.22, -0.2)
    ..relativeCubicTo(6.8, -0.03, 11.73, -6.66, 11.92, -12.71)
    ..relativeLineTo(0, -28.71)
    ..relativeCubicTo(-0.17, -6.92, -5.65, -12.75, -12.98, -12.77)
    ..relativeLineTo(-45.23, -0.12)
    ..relativeLineTo(0.09, -47.32)
    ..relativeCubicTo(0.01, -7.05, -3.8, -13.01, -11.41, -14.07)
    ..relativeLineTo(-31.88, 0.02)
    ..relativeCubicTo(-4.57, 1.37, -10.49, 5.56, -10.51, 11.04)
    ..relativeLineTo(-0.17, 50.33)
    ..relativeLineTo(-47.69, 0.09)
    ..relativeCubicTo(-6.71, 0, -11.92, 5.43, -12.74, 11.5)
    ..relativeLineTo(0.07, 30.13)
    ..relativeCubicTo(0.26, 7.44, 6.06, 12.71, 13.61, 12.71)
    ..relativeLineTo(46.85, 0)
    ..relativeLineTo(-0.06, 46.32)
    ..relativeCubicTo(0, 6.64, 5.19, 11.94, 11.79, 12.8)
    ..relativeLineTo(30.51, 0.03)
    ..relativeCubicTo(5.44, -0.84, 11.45, -5.25, 11.47, -10.94)
    ..close();

  @override
  void paint(Canvas canvas, Size size) {
    final scale = size.shortestSide / _viewBoxSize;
    final viewBoxLineWidth = lineWidth == null
        ? _originalLineWidth
        : lineWidth! / scale;
    final dx = (size.width - (_viewBoxSize * scale)) / 2;
    final dy = (size.height - (_viewBoxSize * scale)) / 2;
    canvas
      ..save()
      ..translate(dx, dy)
      ..scale(scale, scale);

    _drawShield(canvas, viewBoxLineWidth);
    if (lineWidth == null) {
      final crossPaint = Paint()
        ..color = color
        ..style = PaintingStyle.fill;
      canvas
        ..save()
        ..translate(29.15, 0)
        ..drawPath(_cross, crossPaint)
        ..restore();
    } else {
      _drawThinCross(canvas, viewBoxLineWidth);
    }
    canvas.restore();
  }

  void _drawShield(Canvas canvas, double viewBoxLineWidth) {
    var pathScale = 1.0;
    if (preserveInnerContour && viewBoxLineWidth < _originalLineWidth) {
      final removedOutside = (_originalLineWidth - viewBoxLineWidth) / 2;
      pathScale = (_viewBoxSize - (removedOutside * 2)) / _viewBoxSize;
      canvas
        ..save()
        ..translate(_viewBoxSize / 2, _viewBoxSize / 2)
        ..scale(pathScale, pathScale)
        ..translate(-_viewBoxSize / 2, -_viewBoxSize / 2);
    }

    final shieldPaint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = viewBoxLineWidth / pathScale
      ..strokeJoin = StrokeJoin.miter
      ..strokeMiterLimit = 10;
    canvas.drawPath(_shield, shieldPaint);
    if (pathScale != 1) canvas.restore();
  }

  void _drawThinCross(Canvas canvas, double viewBoxLineWidth) {
    const left = 140.52;
    const right = 313.04;
    const top = 131.51;
    const bottom = 320.52;
    const centerX = 227.4;
    const centerY = 227.2;
    final halfLine = viewBoxLineWidth / 2;
    final crossPaint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = viewBoxLineWidth
      ..strokeCap = StrokeCap.square;
    canvas
      ..drawLine(
        Offset(centerX, top + halfLine),
        Offset(centerX, bottom - halfLine),
        crossPaint,
      )
      ..drawLine(
        Offset(left + halfLine, centerY),
        Offset(right - halfLine, centerY),
        crossPaint,
      );
  }

  @override
  bool shouldRepaint(_NozeltShieldPainter oldDelegate) =>
      oldDelegate.color != color ||
      oldDelegate.lineWidth != lineWidth ||
      oldDelegate.preserveInnerContour != preserveInnerContour;
}

class NozeltBottomBar extends StatelessWidget {
  const NozeltBottomBar({
    required this.index,
    required this.onChanged,
    super.key,
  });

  final int index;
  final ValueChanged<int> onChanged;

  static const _items = [
    (Icons.home_rounded, 'mainTab'),
    (Icons.dns_rounded, 'proxiesTab'),
    (Icons.alt_route_rounded, 'routingTab'),
    (Icons.settings_rounded, 'settingsTab'),
  ];

  @override
  Widget build(BuildContext context) {
    // Above Android's gesture line the bar keeps a small gap of its own, so
    // the two never visually merge; without a system inset it keeps 10 dp.
    final systemBottom = MediaQuery.viewPaddingOf(context).bottom;
    return SafeArea(
      minimum: EdgeInsets.fromLTRB(
        14,
        0,
        14,
        systemBottom > 0 ? systemBottom + 8 : 10,
      ),
      child: Container(
        height: 76,
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(28),
          border: Border.all(
            color: Theme.of(context).colorScheme.outlineVariant,
          ),
          boxShadow: [
            BoxShadow(
              color: Theme.of(context).colorScheme.shadow.withValues(
                alpha: Theme.of(context).brightness == Brightness.dark
                    ? .2
                    : .05,
              ),
              blurRadius: 28,
              offset: Offset(0, 12),
            ),
          ],
        ),
        child: Row(
          children: List.generate(_items.length, (itemIndex) {
            final selected = itemIndex == index;
            final item = _items[itemIndex];
            final label = context.tr(item.$2);
            return Expanded(
              child: Semantics(
                selected: selected,
                button: true,
                label: label,
                child: InkWell(
                  borderRadius: BorderRadius.circular(24),
                  onTap: () => onChanged(itemIndex),
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 180),
                    curve: Curves.easeOut,
                    margin: const EdgeInsets.all(6),
                    decoration: BoxDecoration(
                      color: selected
                          ? Theme.of(
                              context,
                            ).colorScheme.primary.withValues(alpha: 0.09)
                          : Colors.transparent,
                      borderRadius: BorderRadius.circular(21),
                    ),
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(
                          item.$1,
                          size: 25,
                          color: selected
                              ? Theme.of(context).colorScheme.primary
                              : Theme.of(context).colorScheme.onSurfaceVariant,
                        ),
                        const SizedBox(height: 3),
                        FittedBox(
                          fit: BoxFit.scaleDown,
                          child: Text(
                            label,
                            maxLines: 1,
                            style: Theme.of(context).textTheme.labelSmall
                                ?.copyWith(
                                  color: selected
                                      ? Theme.of(context).colorScheme.primary
                                      : Theme.of(
                                          context,
                                        ).colorScheme.onSurfaceVariant,
                                  fontWeight: selected
                                      ? FontWeight.w700
                                      : FontWeight.w500,
                                ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            );
          }),
        ),
      ),
    );
  }
}
