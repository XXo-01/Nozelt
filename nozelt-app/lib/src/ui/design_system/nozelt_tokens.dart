import 'dart:math' as math;

import 'package:flutter/material.dart';

/// Layout values are logical pixels. Scale text, never the entire widget tree.
abstract final class NozeltSpacing {
  static const xs = 4.0;
  static const sm = 8.0;
  static const md = 12.0;
  static const lg = 16.0;
  static const xl = 20.0;
  static const xxl = 24.0;
  static const section = 32.0;
  static const spacious = 48.0;
}

abstract final class NozeltRadii {
  static const control = 16.0;
  static const card = 22.0;
  static const overlay = 20.0;
  static const tooltip = 8.0;
}

abstract final class NozeltLayout {
  static const compact = 600.0;
  static const wide = 1024.0;
  static const formMaxWidth = 960.0;
  static const dialogMaxWidth = 560.0;
  static const minSegmentWidth = 104.0;
  static const icon = 20.0;
  static const progress = 18.0;
  static const dropdownContentMin = 24.0;
  static const desktopPagePadding = EdgeInsets.all(desktopGutter);

  /// Every Windows page shares one centred content column, so titles, cards
  /// and editors keep the same left edge when switching pages or windows.
  static const desktopColumnMaxWidth = 1040.0;
  static const desktopGutter = 32.0;
  static const desktopPageTop = 28.0;

  /// Insets for a full-width scroll view whose content is the desktop column.
  /// The scrollable itself stays full width so the wheel works in the margins.
  static EdgeInsets desktopInsets(
    double width, {
    double top = desktopPageTop,
    double bottom = desktopGutter,
  }) {
    final side = math.max(desktopGutter, (width - desktopColumnMaxWidth) / 2);
    return EdgeInsets.fromLTRB(side, top, side, bottom);
  }
}

abstract final class NozeltStates {
  static const hoverOpacity = 0.08;
  static const focusOpacity = 0.12;
  static const pressedOpacity = 0.16;
  static const disabledOpacity = 0.38;
  static const disabledFillOpacity = 0.12;
  static const transition = Duration(milliseconds: 180);
  static const borderWidth = 1.0;
  static const focusBorderWidth = 2.0;
}

enum NozeltControlSize { regular, compact }

/// Additional semantic roles and platform density; standard roles live in
/// ColorScheme/TextTheme. Keeping these in ThemeData supports nested previews,
/// theme animation and platform changes without global platform overrides.
@immutable
class NozeltTokens extends ThemeExtension<NozeltTokens> {
  const NozeltTokens({
    required this.success,
    required this.warning,
    required this.info,
    this.glow = const Color(0xFF08C7F4),
    required this.buttonMinHeight,
    required this.fieldMinHeight,
    required this.segmentMinHeight,
    required this.tapTarget,
    this.controlRadius = NozeltRadii.control,
    this.cardRadius = NozeltRadii.card,
    this.overlayRadius = NozeltRadii.overlay,
  });

  factory NozeltTokens.forTheme(
    Brightness brightness,
    TargetPlatform platform,
  ) {
    final dark = brightness == Brightness.dark;
    final desktop = switch (platform) {
      TargetPlatform.windows ||
      TargetPlatform.linux ||
      TargetPlatform.macOS => true,
      _ => false,
    };
    return NozeltTokens(
      success: Color(dark ? 0xFF29D391 : 0xFF00764D),
      warning: Color(dark ? 0xFFFFB84D : 0xFF8A4B00),
      info: Color(dark ? 0xFF08C7F4 : 0xFF006E8C),
      buttonMinHeight: desktop ? 40 : 48,
      fieldMinHeight: desktop ? 44 : 48,
      segmentMinHeight: desktop ? 44 : 48,
      tapTarget: desktop ? 36 : 48,
      controlRadius: desktop ? 14 : NozeltRadii.control,
      cardRadius: desktop ? 22 : NozeltRadii.card,
      overlayRadius: desktop ? 18 : NozeltRadii.overlay,
    );
  }

  final Color success;
  final Color warning;
  final Color info;

  /// Brand cyan for tints and glows in both themes. The light theme's darker
  /// primary would turn low-alpha tints grey.
  final Color glow;
  final double buttonMinHeight;
  final double fieldMinHeight;
  final double segmentMinHeight;
  final double tapTarget;
  final double controlRadius;
  final double cardRadius;
  final double overlayRadius;

  double fieldHeight(NozeltControlSize size) =>
      size == NozeltControlSize.compact ? tapTarget : fieldMinHeight;
  double segmentHeight(NozeltControlSize size) =>
      size == NozeltControlSize.compact ? tapTarget : segmentMinHeight;

  @override
  NozeltTokens copyWith({
    Color? success,
    Color? warning,
    Color? info,
    Color? glow,
    double? buttonMinHeight,
    double? fieldMinHeight,
    double? segmentMinHeight,
    double? tapTarget,
    double? controlRadius,
    double? cardRadius,
    double? overlayRadius,
  }) => NozeltTokens(
    success: success ?? this.success,
    warning: warning ?? this.warning,
    info: info ?? this.info,
    glow: glow ?? this.glow,
    buttonMinHeight: buttonMinHeight ?? this.buttonMinHeight,
    fieldMinHeight: fieldMinHeight ?? this.fieldMinHeight,
    segmentMinHeight: segmentMinHeight ?? this.segmentMinHeight,
    tapTarget: tapTarget ?? this.tapTarget,
    controlRadius: controlRadius ?? this.controlRadius,
    cardRadius: cardRadius ?? this.cardRadius,
    overlayRadius: overlayRadius ?? this.overlayRadius,
  );

  @override
  NozeltTokens lerp(covariant NozeltTokens? other, double t) {
    if (other == null) return this;
    double mix(double a, double b) => a + (b - a) * t;
    return NozeltTokens(
      success: Color.lerp(success, other.success, t)!,
      warning: Color.lerp(warning, other.warning, t)!,
      info: Color.lerp(info, other.info, t)!,
      glow: Color.lerp(glow, other.glow, t)!,
      buttonMinHeight: mix(buttonMinHeight, other.buttonMinHeight),
      fieldMinHeight: mix(fieldMinHeight, other.fieldMinHeight),
      segmentMinHeight: mix(segmentMinHeight, other.segmentMinHeight),
      tapTarget: mix(tapTarget, other.tapTarget),
      controlRadius: mix(controlRadius, other.controlRadius),
      cardRadius: mix(cardRadius, other.cardRadius),
      overlayRadius: mix(overlayRadius, other.overlayRadius),
    );
  }
}

extension NozeltDesignContext on BuildContext {
  NozeltTokens get nozelt {
    final theme = Theme.of(this);
    return theme.extension<NozeltTokens>() ??
        NozeltTokens.forTheme(theme.brightness, theme.platform);
  }
}
