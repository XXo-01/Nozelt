import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../l10n/nozelt_l10n.dart';
import '../design_system/nozelt_controls.dart';

/// Shared per-profile subscription refresh selector used by both import and
/// profile editing. Values are stored in minutes so the 30-minute preset is
/// represented exactly.
class AutoUpdateIntervalField extends StatefulWidget {
  const AutoUpdateIntervalField({
    required this.valueMinutes,
    required this.onChanged,
    super.key,
  });

  static const presetMinutes = <int>{
    30,
    60,
    3 * 60,
    6 * 60,
    24 * 60,
    7 * 24 * 60,
  };

  final int valueMinutes;
  final ValueChanged<int> onChanged;

  @override
  State<AutoUpdateIntervalField> createState() =>
      _AutoUpdateIntervalFieldState();
}

class _AutoUpdateIntervalFieldState extends State<AutoUpdateIntervalField> {
  static const _customValue = -1;
  late int _selection;
  late final TextEditingController _customHoursController;

  @override
  void initState() {
    super.initState();
    _selection =
        AutoUpdateIntervalField.presetMinutes.contains(widget.valueMinutes)
        ? widget.valueMinutes
        : _customValue;
    _customHoursController = TextEditingController(
      text: _hoursFor(widget.valueMinutes).toString(),
    );
  }

  @override
  void didUpdateWidget(covariant AutoUpdateIntervalField oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.valueMinutes == widget.valueMinutes) return;
    final nextSelection =
        AutoUpdateIntervalField.presetMinutes.contains(widget.valueMinutes)
        ? widget.valueMinutes
        : _customValue;
    _selection = nextSelection;
    if (nextSelection == _customValue) {
      _customHoursController.text = _hoursFor(widget.valueMinutes).toString();
    }
  }

  @override
  void dispose() {
    _customHoursController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Column(
    mainAxisSize: MainAxisSize.min,
    children: [
      NozeltDropdownField<int>(
        value: _selection,
        label: context.tr('autoUpdate'),
        items: [
          DropdownMenuItem(
            value: 30,
            child: Text(context.tr('every30Minutes')),
          ),
          DropdownMenuItem(value: 60, child: Text(context.tr('everyHour'))),
          DropdownMenuItem(
            value: 3 * 60,
            child: Text(context.tr('every3Hours')),
          ),
          DropdownMenuItem(
            value: 6 * 60,
            child: Text(context.tr('every6Hours')),
          ),
          DropdownMenuItem(value: 24 * 60, child: Text(context.tr('daily'))),
          DropdownMenuItem(
            value: 7 * 24 * 60,
            child: Text(context.tr('weekly')),
          ),
          DropdownMenuItem(
            value: _customValue,
            child: Text(context.tr('customHours')),
          ),
        ],
        onChanged: (value) {
          if (value == null) return;
          setState(() => _selection = value);
          if (value == _customValue) {
            _emitCustomHours();
          } else {
            widget.onChanged(value);
          }
        },
      ),
      if (_selection == _customValue) ...[
        const SizedBox(height: 12),
        NozeltTextField(
          controller: _customHoursController,
          keyboardType: TextInputType.number,
          inputFormatters: [
            FilteringTextInputFormatter.digitsOnly,
            LengthLimitingTextInputFormatter(3),
          ],
          label: context.tr('customHourCount'),
          suffixText: context.tr('hoursUnit'),
          onChanged: (_) => _emitCustomHours(),
        ),
      ],
    ],
  );

  void _emitCustomHours() {
    final hours = int.tryParse(_customHoursController.text);
    if (hours == null || hours < 1) return;
    widget.onChanged(hours.clamp(1, 24 * 30).toInt() * 60);
  }

  static int _hoursFor(int minutes) =>
      (minutes <= 0 ? 12 : (minutes / 60).round()).clamp(1, 24 * 30).toInt();
}
