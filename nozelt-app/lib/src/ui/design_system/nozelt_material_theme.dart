import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'nozelt_tokens.dart';
import 'nozelt_typography.dart';

/// Compatibility palette for pages awaiting migration. New UI uses ColorScheme
/// and context.nozelt; these constants cannot adapt to a nested/light theme.
abstract final class NozeltColors {
  static const background = Color(0xFF05070A);
  static const surface = Color(0xFF10141A);
  static const surfaceRaised = Color(0xFF171C24);
  static const surfaceSoft = Color(0xFF0B1118);
  static const primary = Color(0xFF08C7F4);
  static const primaryDeep = Color(0xFF086ADE);
  static const success = Color(0xFF29D391);
  static const warning = Color(0xFFFFB84D);
  static const text = Color(0xFFF4F7FB);
  static const textMuted = Color(0xFF8F9BAA);
  static const outline = Color(0xFF27313D);
}

abstract final class NozeltTheme {
  static final Map<(TargetPlatform, Brightness), ThemeData> _cache = {};
  static ThemeData get dark => forPlatform(defaultTargetPlatform);
  static ThemeData get light =>
      forPlatform(defaultTargetPlatform, brightness: Brightness.light);
  static ThemeData forPlatform(
    TargetPlatform platform, {
    Brightness brightness = Brightness.dark,
  }) => _cache.putIfAbsent((
    platform,
    brightness,
  ), () => _build(platform, brightness));

  static ThemeData _build(TargetPlatform platform, Brightness brightness) {
    final dark = brightness == Brightness.dark;
    final desktop = switch (platform) {
      TargetPlatform.windows ||
      TargetPlatform.macOS ||
      TargetPlatform.linux => true,
      _ => false,
    };
    final tokens = NozeltTokens.forTheme(brightness, platform);
    final baseScheme = dark
        ? const ColorScheme.dark(
            primary: NozeltColors.primary,
            onPrimary: Color(0xFF00232D),
            primaryContainer: Color(0xFF0C303E),
            onPrimaryContainer: NozeltColors.primary,
            secondary: NozeltColors.primaryDeep,
            onSecondary: Colors.white,
            surface: NozeltColors.surface,
            onSurface: NozeltColors.text,
            onSurfaceVariant: NozeltColors.textMuted,
            surfaceContainerLowest: NozeltColors.background,
            surfaceContainerLow: NozeltColors.surfaceSoft,
            surfaceContainer: NozeltColors.surface,
            surfaceContainerHigh: Color(0xFF141A22),
            surfaceContainerHighest: NozeltColors.surfaceRaised,
            error: Color(0xFFFF6B75),
            onError: Color(0xFF350008),
            errorContainer: Color(0xFF49171D),
            onErrorContainer: Color(0xFFFFDADD),
            outline: Color(0xFF596777),
            outlineVariant: NozeltColors.outline,
          )
        : const ColorScheme.light(
            primary: Color(0xFF006E8C),
            onPrimary: Colors.white,
            primaryContainer: Color(0xFFDDF4FA),
            onPrimaryContainer: Color(0xFF00485B),
            secondary: Color(0xFF086ADE),
            onSecondary: Colors.white,
            surface: Colors.white,
            onSurface: Color(0xFF17212C),
            onSurfaceVariant: Color(0xFF536174),
            surfaceContainerLowest: Colors.white,
            surfaceContainerLow: Color(0xFFF8FAFC),
            surfaceContainer: Color(0xFFF1F5F9),
            surfaceContainerHigh: Color(0xFFEBF0F5),
            surfaceContainerHighest: Color(0xFFE5ECF3),
            error: Color(0xFFBA1A1A),
            onError: Colors.white,
            errorContainer: Color(0xFFFFDAD6),
            onErrorContainer: Color(0xFF410002),
            outline: Color(0xFF687889),
            outlineVariant: Color(0xFFCED8E2),
          );
    // Windows uses the same AMOLED-black dark palette as Android.
    final scheme = baseScheme;
    final canvas = dark
        ? scheme.surfaceContainerLowest
        : const Color(0xFFF4F7FA);
    final base = ThemeData(
      useMaterial3: true,
      platform: platform,
      visualDensity: VisualDensity.standard,
      brightness: brightness,
      colorScheme: scheme,
      scaffoldBackgroundColor: canvas,
      fontFamily: NozeltTypography.family(platform),
      fontFamilyFallback: const ['Roboto'],
      extensions: [tokens],
    );
    final text = NozeltTypography.build(base.textTheme, platform);
    final shape = RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(tokens.controlRadius),
    );
    // Capsule actions and round icon buttons give every platform the same
    // soft, modern look.
    const OutlinedBorder actionShape = StadiumBorder();
    final tapTarget = desktop
        ? MaterialTapTargetSize.shrinkWrap
        : MaterialTapTargetSize.padded;
    Color foreground(Set<WidgetState> states, Color enabled) =>
        states.contains(WidgetState.disabled)
        ? scheme.onSurface.withValues(alpha: NozeltStates.disabledOpacity)
        : enabled;
    WidgetStateProperty<Color?> overlay(Color color) =>
        WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.disabled)) return Colors.transparent;
          if (states.contains(WidgetState.pressed)) {
            return color.withValues(alpha: NozeltStates.pressedOpacity);
          }
          if (states.contains(WidgetState.focused)) {
            return color.withValues(alpha: NozeltStates.focusOpacity);
          }
          if (states.contains(WidgetState.hovered)) {
            return color.withValues(alpha: NozeltStates.hoverOpacity);
          }
          return Colors.transparent;
        });
    final action = ButtonStyle(
      minimumSize: WidgetStatePropertyAll(Size(0, tokens.buttonMinHeight)),
      padding: const WidgetStatePropertyAll(
        EdgeInsets.symmetric(
          horizontal: NozeltSpacing.lg,
          vertical: NozeltSpacing.sm,
        ),
      ),
      shape: WidgetStatePropertyAll(actionShape),
      animationDuration: NozeltStates.transition,
      tapTargetSize: tapTarget,
      visualDensity: VisualDensity.standard,
    );
    OutlineInputBorder inputBorder(
      Color color, [
      double width = NozeltStates.borderWidth,
    ]) => OutlineInputBorder(
      borderRadius: BorderRadius.circular(tokens.controlRadius),
      borderSide: BorderSide(color: color, width: width),
    );
    return base.copyWith(
      textTheme: text,
      iconTheme: desktop
          ? base.iconTheme.copyWith(size: NozeltLayout.icon)
          : base.iconTheme,
      filledButtonTheme: FilledButtonThemeData(
        style: action.copyWith(
          // A soft accent glow under the main action.
          elevation: WidgetStateProperty.resolveWith(
            (s) => s.contains(WidgetState.disabled)
                ? 0
                : s.contains(WidgetState.hovered)
                ? 6
                : 3,
          ),
          shadowColor: WidgetStatePropertyAll(
            tokens.glow.withValues(alpha: dark ? .35 : .3),
          ),
          // A tinted capsule with a cyan outline, like the selected option
          // of a choice, instead of a solid slab of colour.
          foregroundColor: WidgetStateProperty.resolveWith(
            (s) => foreground(s, scheme.onPrimaryContainer),
          ),
          backgroundColor: WidgetStateProperty.resolveWith(
            (s) => s.contains(WidgetState.disabled)
                ? scheme.onSurface.withValues(
                    alpha: NozeltStates.disabledFillOpacity,
                  )
                : scheme.primaryContainer,
          ),
          overlayColor: overlay(scheme.primary),
          side: WidgetStateProperty.resolveWith(
            (s) => BorderSide(
              color: s.contains(WidgetState.disabled)
                  ? Colors.transparent
                  : s.contains(WidgetState.focused)
                  ? scheme.onSurface
                  : tokens.glow.withValues(alpha: dark ? .45 : .55),
              width: !s.contains(WidgetState.focused)
                  ? NozeltStates.borderWidth
                  : NozeltStates.focusBorderWidth,
            ),
          ),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: action.copyWith(
          foregroundColor: WidgetStateProperty.resolveWith(
            (s) => foreground(s, scheme.onSurface),
          ),
          overlayColor: overlay(scheme.primary),
          side: WidgetStateProperty.resolveWith(
            (s) => BorderSide(
              color: s.contains(WidgetState.focused)
                  ? scheme.primary
                  : scheme.outline,
              width: s.contains(WidgetState.focused)
                  ? NozeltStates.focusBorderWidth
                  : NozeltStates.borderWidth,
            ),
          ),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: action.copyWith(
          foregroundColor: WidgetStateProperty.resolveWith(
            (s) => foreground(s, scheme.primary),
          ),
          overlayColor: overlay(scheme.primary),
          side: WidgetStateProperty.resolveWith(
            (s) => BorderSide(
              color: s.contains(WidgetState.focused)
                  ? scheme.primary
                  : Colors.transparent,
              width: NozeltStates.focusBorderWidth,
            ),
          ),
        ),
      ),
      segmentedButtonTheme: SegmentedButtonThemeData(
        style: action.copyWith(
          minimumSize: WidgetStatePropertyAll(Size(0, tokens.segmentMinHeight)),
          foregroundColor: WidgetStateProperty.resolveWith(
            (s) => foreground(
              s,
              s.contains(WidgetState.selected)
                  ? scheme.onPrimaryContainer
                  : scheme.onSurfaceVariant,
            ),
          ),
          backgroundColor: WidgetStateProperty.resolveWith(
            (s) =>
                s.contains(WidgetState.selected) &&
                    !s.contains(WidgetState.disabled)
                ? scheme.primaryContainer
                : scheme.surfaceContainerHighest,
          ),
          overlayColor: overlay(scheme.primary),
          // A borderless capsule track with a filled selection.
          side: const WidgetStatePropertyAll(BorderSide.none),
        ),
      ),
      switchTheme: SwitchThemeData(
        trackOutlineWidth: const WidgetStatePropertyAll(1),
        thumbColor: WidgetStateProperty.resolveWith(
          (s) => foreground(
            s,
            s.contains(WidgetState.selected)
                ? tokens.glow
                : scheme.onSurfaceVariant,
          ),
        ),
        trackColor: WidgetStateProperty.resolveWith(
          (s) =>
              s.contains(WidgetState.selected) &&
                  !s.contains(WidgetState.disabled)
              ? scheme.primaryContainer
              : scheme.surfaceContainerHighest,
        ),
        trackOutlineColor: WidgetStateProperty.resolveWith(
          (s) => s.contains(WidgetState.selected)
              ? Colors.transparent
              : scheme.outline,
        ),
        overlayColor: overlay(scheme.primary),
      ),
      inputDecorationTheme: InputDecorationTheme(
        isDense: desktop,
        filled: true,
        // Fields are black (white in the light theme) like the page, so they
        // read as wells rather than grey slabs.
        fillColor: scheme.surfaceContainerLowest,
        contentPadding: EdgeInsets.symmetric(
          horizontal: NozeltSpacing.lg,
          vertical: NozeltSpacing.md,
        ),
        hintStyle: text.bodyLarge?.copyWith(color: scheme.onSurfaceVariant),
        helperStyle: text.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
        errorStyle: text.bodySmall?.copyWith(color: scheme.error),
        prefixIconColor: scheme.onSurfaceVariant,
        suffixIconColor: scheme.onSurfaceVariant,
        border: inputBorder(scheme.outlineVariant),
        enabledBorder: inputBorder(scheme.outlineVariant),
        disabledBorder: inputBorder(scheme.outlineVariant),
        focusedBorder: inputBorder(
          scheme.primary,
          NozeltStates.focusBorderWidth,
        ),
        errorBorder: inputBorder(scheme.error),
        focusedErrorBorder: inputBorder(
          scheme.error,
          NozeltStates.focusBorderWidth,
        ),
      ),
      cardTheme: CardThemeData(
        clipBehavior: Clip.antiAlias,
        color: scheme.surface,
        elevation: 0,
        margin: EdgeInsets.zero,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(tokens.cardRadius),
          side: BorderSide(color: scheme.outlineVariant, width: 0.7),
        ),
      ),
      dividerTheme: DividerThemeData(
        color: scheme.outlineVariant,
        thickness: 0.7,
      ),
      listTileTheme: ListTileThemeData(
        shape: const StadiumBorder(),
        minTileHeight: desktop ? 52 : 56,
        iconColor: scheme.onSurfaceVariant,
        horizontalTitleGap: NozeltSpacing.md,
        contentPadding: EdgeInsets.symmetric(
          horizontal: NozeltSpacing.lg,
          vertical: desktop ? 0 : NozeltSpacing.xs,
        ),
        subtitleTextStyle: text.bodySmall?.copyWith(
          color: scheme.onSurfaceVariant,
        ),
      ),
      appBarTheme: AppBarTheme(
        backgroundColor: canvas,
        foregroundColor: scheme.onSurface,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        centerTitle: false,
        titleSpacing: desktop ? NozeltSpacing.xl : null,
        systemOverlayStyle: SystemUiOverlayStyle(
          statusBarColor: Colors.transparent,
          statusBarIconBrightness: dark ? Brightness.light : Brightness.dark,
          systemNavigationBarColor: canvas,
          systemNavigationBarIconBrightness: dark
              ? Brightness.light
              : Brightness.dark,
        ),
      ),
      // Tabs select with the same filled capsule as other choices.
      tabBarTheme: TabBarThemeData(
        labelStyle: text.labelLarge,
        unselectedLabelStyle: text.labelLarge,
        labelColor: scheme.onPrimaryContainer,
        unselectedLabelColor: scheme.onSurfaceVariant,
        dividerColor: Colors.transparent,
        indicatorSize: TabBarIndicatorSize.tab,
        indicator: ShapeDecoration(
          color: scheme.primaryContainer,
          shape: StadiumBorder(
            side: BorderSide(
              color: tokens.glow.withValues(alpha: dark ? .35 : .45),
            ),
          ),
        ),
        overlayColor: overlay(scheme.primary),
        splashBorderRadius: BorderRadius.circular(999),
      ),
      scrollbarTheme: ScrollbarThemeData(
        thumbColor: WidgetStateProperty.resolveWith(
          (s) => s.contains(WidgetState.hovered)
              ? scheme.onSurfaceVariant
              : scheme.outline,
        ),
        thickness: const WidgetStatePropertyAll(5),
        radius: const Radius.circular(6),
        crossAxisMargin: 3,
      ),
      tooltipTheme: TooltipThemeData(
        decoration: BoxDecoration(
          color: scheme.surfaceContainerHighest,
          border: Border.all(color: scheme.outlineVariant),
          borderRadius: BorderRadius.circular(NozeltRadii.tooltip),
        ),
        textStyle: text.bodySmall?.copyWith(color: scheme.onSurface),
        padding: const EdgeInsets.symmetric(
          horizontal: NozeltSpacing.md,
          vertical: NozeltSpacing.sm,
        ),
        waitDuration: const Duration(milliseconds: 500),
      ),
      snackBarTheme: SnackBarThemeData(
        backgroundColor: scheme.surfaceContainerHighest,
        contentTextStyle: text.bodyMedium?.copyWith(color: scheme.onSurface),
        behavior: SnackBarBehavior.floating,
        shape: shape,
      ),
      popupMenuTheme: PopupMenuThemeData(
        // Menu triggers match the other icon buttons.
        iconColor: scheme.onSurfaceVariant,
        menuPadding: EdgeInsets.zero,
        color: scheme.surfaceContainerHighest,
        surfaceTintColor: Colors.transparent,
        elevation: 10,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(tokens.overlayRadius),
          side: BorderSide(color: scheme.outlineVariant),
        ),
      ),
      menuTheme: MenuThemeData(
        style: MenuStyle(
          shape: WidgetStatePropertyAll(
            RoundedRectangleBorder(
              borderRadius: BorderRadius.all(
                Radius.circular(tokens.overlayRadius),
              ),
            ),
          ),
          backgroundColor: WidgetStatePropertyAll(
            scheme.surfaceContainerHighest,
          ),
          surfaceTintColor: const WidgetStatePropertyAll(Colors.transparent),
        ),
      ),
      dropdownMenuTheme: DropdownMenuThemeData(
        menuStyle: MenuStyle(
          backgroundColor: WidgetStatePropertyAll(
            scheme.surfaceContainerHighest,
          ),
          surfaceTintColor: const WidgetStatePropertyAll(Colors.transparent),
          shape: WidgetStatePropertyAll(
            RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(tokens.overlayRadius),
            ),
          ),
        ),
      ),
      iconButtonTheme: IconButtonThemeData(
        style: IconButton.styleFrom(
          foregroundColor: scheme.onSurfaceVariant,
          backgroundColor: Colors.transparent,
          minimumSize: Size.square(tokens.tapTarget),
          shape: const CircleBorder(),
        ),
      ),
      bottomSheetTheme: BottomSheetThemeData(
        clipBehavior: Clip.antiAlias,
        backgroundColor: scheme.surface,
        surfaceTintColor: Colors.transparent,
        constraints: desktop
            ? const BoxConstraints(maxWidth: NozeltLayout.dialogMaxWidth)
            : null,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(
            top: Radius.circular(tokens.overlayRadius),
          ),
        ),
      ),
      dialogTheme: DialogThemeData(
        titleTextStyle: text.titleLarge?.copyWith(
          fontWeight: FontWeight.w600,
          color: scheme.onSurface,
        ),
        clipBehavior: Clip.antiAlias,
        backgroundColor: scheme.surface,
        surfaceTintColor: Colors.transparent,
        constraints: const BoxConstraints(
          maxWidth: NozeltLayout.dialogMaxWidth,
        ),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(tokens.overlayRadius),
        ),
      ),
    );
  }
}
