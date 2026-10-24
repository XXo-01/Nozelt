import 'package:alchemist/alchemist.dart';
import 'package:flutter/material.dart';

/// Alchemist replaces TextTheme fonts, but not component theme text styles.
/// Keep those explicit styles portable too, without changing production themes.
AlchemistConfig nozeltGoldenConfig(ThemeData theme) {
  TextStyle? obscure(TextStyle? style) => style?.copyWith(fontFamily: 'Ahem');
  final ciTheme = theme.copyWith(
    inputDecorationTheme: theme.inputDecorationTheme.copyWith(
      hintStyle: obscure(theme.inputDecorationTheme.hintStyle),
      helperStyle: obscure(theme.inputDecorationTheme.helperStyle),
      errorStyle: obscure(theme.inputDecorationTheme.errorStyle),
    ),
    listTileTheme: theme.listTileTheme.copyWith(
      subtitleTextStyle: obscure(theme.listTileTheme.subtitleTextStyle),
    ),
    tooltipTheme: theme.tooltipTheme.copyWith(
      textStyle: obscure(theme.tooltipTheme.textStyle),
    ),
    snackBarTheme: theme.snackBarTheme.copyWith(
      contentTextStyle: obscure(theme.snackBarTheme.contentTextStyle),
    ),
  );
  final config = AlchemistConfig.current();
  return config.copyWith(
    theme: theme,
    ciGoldensConfig: config.ciGoldensConfig.copyWith(theme: ciTheme),
  );
}
