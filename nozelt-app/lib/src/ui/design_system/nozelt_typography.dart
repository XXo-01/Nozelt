import 'package:flutter/material.dart';

abstract final class NozeltTypography {
  static String family(TargetPlatform platform) =>
      platform == TargetPlatform.windows ? 'Segoe UI' : 'Roboto';

  static TextTheme build(TextTheme base, TargetPlatform platform) =>
      base.copyWith(
        headlineMedium: base.headlineMedium?.copyWith(
          fontSize: platform == TargetPlatform.windows ? 26 : 28,
          fontWeight: platform == TargetPlatform.windows
              ? FontWeight.w600
              : FontWeight.w800,
          letterSpacing: -0.5,
        ),
        titleLarge: base.titleLarge?.copyWith(
          fontSize: platform == TargetPlatform.windows ? 20 : 22,
          fontWeight: FontWeight.w700,
          letterSpacing: -0.35,
        ),
        titleMedium: base.titleMedium?.copyWith(
          fontSize: platform == TargetPlatform.windows ? 15 : 16,
          fontWeight: FontWeight.w600,
        ),
        titleSmall: base.titleSmall?.copyWith(
          fontSize: 14,
          fontWeight: FontWeight.w600,
        ),
        bodyLarge: base.bodyLarge?.copyWith(
          fontSize: platform == TargetPlatform.windows ? 14 : 16,
          height: 1.4,
        ),
        bodyMedium: base.bodyMedium?.copyWith(fontSize: 14, height: 1.4),
        bodySmall: base.bodySmall?.copyWith(fontSize: 12, height: 1.4),
        labelLarge: base.labelLarge?.copyWith(
          fontSize: 14,
          fontWeight: FontWeight.w600,
          letterSpacing: 0,
        ),
        labelMedium: base.labelMedium?.copyWith(
          fontSize: 12,
          fontWeight: FontWeight.w600,
        ),
        labelSmall: base.labelSmall?.copyWith(
          fontSize: 11,
          fontWeight: FontWeight.w500,
        ),
      );
}
