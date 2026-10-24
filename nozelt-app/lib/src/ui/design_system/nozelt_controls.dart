import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'dart:math' as math;

import 'nozelt_tokens.dart';

enum NozeltButtonVariant { primary, secondary, tertiary, destructive }

/// Flutter's popup theme supplies the shape, but does not clip item ink to it.
/// Keep native menu behavior and give both the menu and its trigger a contour.
class NozeltPopupMenuButton<T> extends PopupMenuButton<T> {
  const NozeltPopupMenuButton({
    required super.itemBuilder,
    super.key,
    super.initialValue,
    super.onOpened,
    super.onSelected,
    super.onCanceled,
    super.tooltip,
    super.child,
    super.icon,
    super.iconSize,
    super.iconColor,
    super.padding,
    super.menuPadding,
    super.constraints,
    super.offset,
    super.enabled,
    super.position,
    super.useRootNavigator,
    super.requestFocus,
    super.style,
  }) : super(
         clipBehavior: Clip.antiAlias,
         borderRadius: const BorderRadius.all(
           Radius.circular(NozeltRadii.control),
         ),
       );
}

/// One action API; Material retains keyboard, focus, semantics and ink states.
class NozeltButton extends StatelessWidget {
  const NozeltButton({
    required this.label,
    required this.onPressed,
    this.variant = NozeltButtonVariant.primary,
    this.icon,
    this.loading = false,
    this.focusNode,
    this.autofocus = false,
    this.statesController,
    super.key,
  });

  final String label;
  final VoidCallback? onPressed;
  final NozeltButtonVariant variant;
  final Widget? icon;
  final bool loading;
  final FocusNode? focusNode;
  final bool autofocus;
  final WidgetStatesController? statesController;

  @override
  Widget build(BuildContext context) {
    final leading = loading
        ? const ExcludeSemantics(
            child: SizedBox.square(
              dimension: NozeltLayout.progress,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
          )
        : icon;
    final caption = Text(label, textAlign: TextAlign.center);
    final child = leading == null
        ? caption
        : Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              leading,
              const SizedBox(width: NozeltSpacing.sm),
              Flexible(child: caption),
            ],
          );
    final callback = loading ? null : onPressed;
    switch (variant) {
      case NozeltButtonVariant.primary:
      case NozeltButtonVariant.destructive:
        final scheme = Theme.of(context).colorScheme;
        return FilledButton(
          clipBehavior: Clip.antiAlias,
          onPressed: callback,
          focusNode: focusNode,
          autofocus: autofocus,
          statesController: statesController,
          style: variant == NozeltButtonVariant.destructive
              ? FilledButton.styleFrom(
                  backgroundColor: scheme.error,
                  foregroundColor: scheme.onError,
                )
              : null,
          child: child,
        );
      case NozeltButtonVariant.secondary:
        return OutlinedButton(
          clipBehavior: Clip.antiAlias,
          onPressed: callback,
          focusNode: focusNode,
          autofocus: autofocus,
          statesController: statesController,
          child: child,
        );
      case NozeltButtonVariant.tertiary:
        return TextButton(
          clipBehavior: Clip.antiAlias,
          onPressed: callback,
          focusNode: focusNode,
          autofocus: autofocus,
          statesController: statesController,
          child: child,
        );
    }
  }
}

/// Labels, errors, validation and multiline behavior use Flutter's form field.
/// Visual overrides belong in InputDecorationTheme, not in individual screens.
class NozeltTextField extends StatelessWidget {
  const NozeltTextField({
    this.controller,
    this.initialValue,
    this.label,
    this.hintText,
    this.helperText,
    this.errorText,
    this.prefixIcon,
    this.suffixIcon,
    this.suffixText,
    this.enabled = true,
    this.readOnly = false,
    this.obscureText = false,
    this.autocorrect = true,
    this.enableSuggestions = true,
    this.autofocus = false,
    this.minLines,
    this.maxLines = 1,
    this.keyboardType,
    this.textInputAction,
    this.focusNode,
    this.onChanged,
    this.onSubmitted,
    this.validator,
    this.inputFormatters,
    this.size = NozeltControlSize.regular,
    this.statesController,
    super.key,
  }) : assert(controller == null || initialValue == null);

  final TextEditingController? controller;
  final String? initialValue;
  final String? label;
  final String? hintText;
  final String? helperText;
  final String? errorText;
  final Widget? prefixIcon;
  final Widget? suffixIcon;
  final String? suffixText;
  final bool enabled;
  final bool readOnly;
  final bool obscureText;
  final bool autocorrect;
  final bool enableSuggestions;
  final bool autofocus;
  final int? minLines;
  final int? maxLines;
  final TextInputType? keyboardType;
  final TextInputAction? textInputAction;
  final FocusNode? focusNode;
  final ValueChanged<String>? onChanged;
  final ValueChanged<String>? onSubmitted;
  final FormFieldValidator<String>? validator;
  final List<TextInputFormatter>? inputFormatters;
  final NozeltControlSize size;
  final WidgetStatesController? statesController;

  @override
  Widget build(BuildContext context) {
    final compact = size == NozeltControlSize.compact;
    final tokens = context.nozelt;
    final field = TextFormField(
      style: Theme.of(context).platform == TargetPlatform.windows
          ? Theme.of(context).textTheme.bodyMedium
          : Theme.of(context).textTheme.bodyLarge,
      controller: controller,
      initialValue: initialValue,
      enabled: enabled,
      readOnly: readOnly,
      obscureText: obscureText,
      autocorrect: autocorrect,
      enableSuggestions: enableSuggestions,
      autofocus: autofocus,
      minLines: minLines,
      maxLines: maxLines,
      keyboardType: keyboardType,
      textInputAction: textInputAction,
      focusNode: focusNode,
      onChanged: onChanged,
      onFieldSubmitted: onSubmitted,
      validator: validator,
      inputFormatters: inputFormatters,
      statesController: statesController,
      decoration: InputDecoration(
        labelText: label,
        hintText: hintText,
        helperText: helperText,
        errorText: errorText,
        helperMaxLines: 4,
        errorMaxLines: 4,
        alignLabelWithHint: (minLines ?? 1) > 1,
        prefixIcon: prefixIcon,
        suffixIcon: suffixIcon,
        suffixText: suffixText,
        constraints: BoxConstraints(minHeight: tokens.fieldHeight(size)),
        contentPadding: compact
            ? const EdgeInsets.symmetric(
                horizontal: NozeltSpacing.md,
                vertical: NozeltSpacing.sm,
              )
            : null,
        prefixIconConstraints: BoxConstraints(
          minWidth: tokens.tapTarget,
          minHeight: tokens.fieldHeight(size),
        ),
        suffixIconConstraints: BoxConstraints(
          minWidth: tokens.tapTarget,
          minHeight: tokens.fieldHeight(size),
        ),
      ),
    );
    return label == null
        ? field
        : Tooltip(message: label!, excludeFromSemantics: true, child: field);
  }
}

/// Native dropdowns reserve a 24 dp dense line even with smaller text. Derive
/// their padding from the same painted control height as fields and segments.
class NozeltDropdownField<T> extends StatelessWidget {
  const NozeltDropdownField({
    required this.value,
    required this.items,
    required this.onChanged,
    this.label,
    this.decoration,
    this.textStyle,
    super.key,
  });
  final T value;
  final List<DropdownMenuItem<T>> items;
  final ValueChanged<T?>? onChanged;
  final String? label;

  /// Replaces the default field decoration (for example a search-style
  /// filter); the dropdown arrow is always added.
  final InputDecoration? decoration;
  final TextStyle? textStyle;

  /// Opens the same flush popup menu as every other Nozelt menu (no list
  /// padding above and below the options), matching the field's width.
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final enabled = onChanged != null;
    final selected = items.where((item) => item.value == value).firstOrNull;
    final decoration =
        (this.decoration ??
                InputDecoration(
                  labelText: label,
                  contentPadding: EdgeInsets.symmetric(
                    horizontal: NozeltSpacing.lg,
                    vertical: math.max(
                      0,
                      (context.nozelt.fieldMinHeight -
                              NozeltLayout.dropdownContentMin) /
                          2,
                    ),
                  ),
                ))
            .copyWith(enabled: enabled)
            .applyDefaults(theme.inputDecorationTheme);
    return LayoutBuilder(
      builder: (context, constraints) => NozeltPopupMenuButton<T>(
        tooltip: '',
        enabled: enabled,
        initialValue: value,
        onSelected: (next) => onChanged?.call(next),
        constraints: constraints.hasBoundedWidth
            ? BoxConstraints(
                minWidth: constraints.maxWidth,
                maxWidth: constraints.maxWidth,
              )
            : null,
        itemBuilder: (_) => [
          for (final item in items)
            PopupMenuItem<T>(
              value: item.value,
              enabled: item.enabled,
              child: item.child,
            ),
        ],
        child: InputDecorator(
          decoration: decoration,
          isEmpty: selected == null,
          // The arrow sits in the content row (as in the native dropdown),
          // so the field keeps the regular control height.
          child: SizedBox(
            height: NozeltLayout.dropdownContentMin,
            child: Row(
              children: [
                Expanded(
                  child: DefaultTextStyle.merge(
                    style: textStyle ?? theme.textTheme.bodyMedium,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    child: selected?.child ?? const SizedBox.shrink(),
                  ),
                ),
                Icon(
                  Icons.arrow_drop_down_rounded,
                  color: enabled
                      ? theme.colorScheme.onSurfaceVariant
                      : theme.disabledColor,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class NozeltSwitchTile extends StatelessWidget {
  const NozeltSwitchTile({
    required this.title,
    required this.value,
    required this.onChanged,
    this.subtitle,
    this.secondary,
    this.focusNode,
    this.autofocus = false,
    this.contentPadding,
    super.key,
  });

  final Widget title;
  final Widget? subtitle;
  final Widget? secondary;
  final bool value;
  final ValueChanged<bool>? onChanged;
  final FocusNode? focusNode;
  final bool autofocus;
  final EdgeInsetsGeometry? contentPadding;

  @override
  Widget build(BuildContext context) => SwitchListTile(
    contentPadding:
        contentPadding ??
        EdgeInsetsDirectional.fromSTEB(
          NozeltSpacing.lg,
          Theme.of(context).platform == TargetPlatform.windows
              ? 0
              : NozeltSpacing.xs,
          NozeltSpacing.md,
          Theme.of(context).platform == TargetPlatform.windows
              ? 0
              : NozeltSpacing.xs,
        ),
    title: title,
    subtitle: subtitle,
    secondary: secondary,
    value: value,
    onChanged: onChanged,
    focusNode: focusNode,
    autofocus: autofocus,
  );
}

/// Native single selection with measured, finite geometry. Flutter 3.41's
/// segmented render object fixes its expansion flag at creation, so both axes
/// stay expanded inside a finite box. Caption boxes also make vertical fills
/// span the entire width and prevent clipping at large text scales.
class NozeltSegmentedControl<T> extends StatelessWidget {
  const NozeltSegmentedControl({
    required this.segments,
    required this.value,
    required this.onChanged,
    this.size = NozeltControlSize.regular,
    this.allowVertical = true,
    super.key,
  }) : assert(segments.length > 1);

  final List<ButtonSegment<T>> segments;
  final T value;
  final ValueChanged<T>? onChanged;
  final NozeltControlSize size;
  final bool allowVertical;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final scale = MediaQuery.textScalerOf(context);
      final direction = Directionality.of(context);
      final style = Theme.of(context).textTheme.labelLarge!;
      final horizontalPadding = segments.every((s) => s.label == null)
          ? NozeltSpacing.xs
          : NozeltSpacing.md;
      const verticalPadding = NozeltSpacing.sm;

      TextPainter painter(Text label) => TextPainter(
        text: TextSpan(
          style: style.merge(label.style),
          text: label.data,
          children: label.textSpan == null ? null : [label.textSpan!],
        ),
        textDirection: label.textDirection ?? direction,
        textScaler: label.textScaler ?? scale,
        maxLines: label.maxLines,
      );

      double requiredWidth(
        ButtonSegment<T> segment, {
        required bool icon,
        bool full = false,
      }) {
        final label = segment.label;
        var textWidth = 0.0;
        if (label is Text) {
          final p = painter(label)..layout();
          textWidth = full ? p.maxIntrinsicWidth : p.minIntrinsicWidth;
          p.dispose();
        } else if (label != null) {
          textWidth = NozeltLayout.minSegmentWidth;
        }
        return textWidth +
            horizontalPadding * 2 +
            (icon && segment.icon != null
                ? NozeltLayout.icon + (label == null ? 0 : NozeltSpacing.sm)
                : 0);
      }

      final width = constraints.hasBoundedWidth
          ? constraints.maxWidth
          : segments
                    .map((s) => requiredWidth(s, icon: true, full: true))
                    .reduce(math.max) *
                segments.length;
      if (width <= 1) return const SizedBox.shrink();
      final cellWidth = width / segments.length;
      final hideIcons =
          segments.every((s) => s.label != null) &&
          segments.any((s) => requiredWidth(s, icon: true) > cellWidth) &&
          segments.every((s) => requiredWidth(s, icon: false) <= cellWidth);
      final vertical =
          allowVertical &&
          segments.any((s) => s.label != null) &&
          segments.any((s) => requiredWidth(s, icon: !hideIcons) > cellWidth);
      final captionWidth = math.max(
        1.0,
        (vertical ? width : cellWidth) - horizontalPadding * 2,
      );
      var contentHeight = 0.0;
      for (final segment in segments) {
        final iconWidth = !hideIcons && segment.icon != null
            ? NozeltLayout.icon + (segment.label == null ? 0 : NozeltSpacing.sm)
            : 0;
        final label = segment.label;
        if (label is Text) {
          final p = painter(label)
            ..layout(maxWidth: math.max(1, captionWidth - iconWidth));
          contentHeight = math.max(contentHeight, p.height);
          p.dispose();
        } else if (label != null) {
          contentHeight = math.max(
            contentHeight,
            scale.scale(style.fontSize!) * (style.height ?? 1.4),
          );
        }
        if (iconWidth > 0) {
          contentHeight = math.max(contentHeight, NozeltLayout.icon);
        }
      }
      final height = math.max(
        context.nozelt.segmentHeight(size),
        (contentHeight + verticalPadding * 2).ceilToDouble(),
      );
      final effectiveSegments = [
        for (final segment in segments)
          ButtonSegment<T>(
            value: segment.value,
            enabled: segment.enabled,
            tooltip: segment.tooltip,
            // Icons are composed into the label so native TextButton's padding
            // remains identical with/without icons at every text scale.
            label: SizedBox(
              width: captionWidth,
              height: height - verticalPadding * 2,
              child: Center(
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (!hideIcons && segment.icon != null) ...[
                      IconTheme.merge(
                        data: const IconThemeData(size: NozeltLayout.icon),
                        child: segment.icon!,
                      ),
                      if (segment.label != null)
                        const SizedBox(width: NozeltSpacing.sm),
                    ],
                    if (segment.label != null)
                      Flexible(
                        child: DefaultTextStyle.merge(
                          textAlign: TextAlign.center,
                          softWrap: true,
                          child: segment.label!,
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ),
      ];
      return NozeltPillTrack<T>(
        segments: effectiveSegments,
        value: value,
        onChanged: onChanged,
        vertical: vertical,
        segmentHeight: constraints.hasBoundedHeight && !vertical
            ? math.max(height, constraints.maxHeight)
            : height,
        width: width,
      );
    },
  );
}

/// Windows single-select control: a capsule track with the selected option
/// as a filled capsule inside, matching the sidebar's routing mode switch.
/// Each option is a focusable button (Enter/Space) with selected semantics.
class NozeltPillTrack<T> extends StatelessWidget {
  const NozeltPillTrack({
    required this.segments,
    required this.value,
    required this.onChanged,
    required this.segmentHeight,
    required this.width,
    this.vertical = false,
    super.key,
  });

  final List<ButtonSegment<T>> segments;
  final T value;
  final ValueChanged<T>? onChanged;
  final double segmentHeight;
  final double width;
  final bool vertical;

  /// Space between the track border and the selected capsule.
  static const inset = 3.0;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final dark = theme.brightness == Brightness.dark;
    Widget option(ButtonSegment<T> segment) {
      final selected = segment.value == value;
      final enabled = onChanged != null && segment.enabled;
      final foreground = !enabled
          ? scheme.onSurface.withValues(alpha: NozeltStates.disabledOpacity)
          : selected
          ? scheme.onPrimaryContainer
          : scheme.onSurfaceVariant;
      Widget child = Semantics(
        button: true,
        selected: selected,
        enabled: enabled,
        child: AnimatedContainer(
          duration: NozeltStates.transition,
          decoration: ShapeDecoration(
            shape: StadiumBorder(
              side: BorderSide(
                color: selected
                    ? scheme.primary.withValues(alpha: dark ? .35 : .3)
                    : Colors.transparent,
              ),
            ),
            color: selected ? scheme.primaryContainer : Colors.transparent,
            shadows: selected && enabled
                ? [
                    BoxShadow(
                      color: scheme.primary.withValues(alpha: dark ? .16 : .12),
                      blurRadius: 12,
                      offset: const Offset(0, 3),
                    ),
                  ]
                : null,
          ),
          child: Material(
            type: MaterialType.transparency,
            shape: const StadiumBorder(),
            clipBehavior: Clip.antiAlias,
            child: InkWell(
              customBorder: const StadiumBorder(),
              onTap: enabled && !selected
                  ? () => onChanged!(segment.value)
                  : (enabled ? () {} : null),
              child: SizedBox(
                height: segmentHeight - (inset + 1) * 2,
                child: Center(
                  child: IconTheme.merge(
                    data: IconThemeData(color: foreground),
                    child: DefaultTextStyle.merge(
                      style: theme.textTheme.labelLarge?.copyWith(
                        color: foreground,
                        fontWeight: selected
                            ? FontWeight.w600
                            : FontWeight.w500,
                      ),
                      child: OverflowBox(
                        maxWidth: double.infinity,
                        child:
                            segment.label ?? segment.icon ?? const SizedBox(),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      if (segment.tooltip != null) {
        child = Tooltip(message: segment.tooltip!, child: child);
      }
      return child;
    }

    final children = <Widget>[
      for (var index = 0; index < segments.length; index++) ...[
        if (index > 0) const SizedBox(width: inset, height: inset),
        vertical
            ? option(segments[index])
            : Expanded(child: option(segments[index])),
      ],
    ];
    return SizedBox(
      width: width,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: dark ? scheme.surfaceContainerLowest : scheme.surfaceContainer,
          // A capsule in both orientations.
          borderRadius: BorderRadius.circular(
            vertical ? segmentHeight / 2 : 999,
          ),
          border: Border.all(color: scheme.outlineVariant),
        ),
        child: Padding(
          padding: const EdgeInsets.all(inset),
          child: vertical
              ? Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: children,
                )
              : Row(children: children),
        ),
      ),
    );
  }
}
