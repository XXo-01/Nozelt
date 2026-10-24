import 'package:flutter/material.dart';
import '../design_system/nozelt_controls.dart';
import '../design_system/nozelt_tokens.dart';

/// Shared quick import composition for the real form and visual catalogue.
class NozeltProfileImportActions extends StatelessWidget {
  const NozeltProfileImportActions({
    required this.pasteLabel,
    required this.onPaste,
    required this.scanLabel,
    this.onScan,
    this.showQr = false,
    super.key,
  });
  final String pasteLabel;
  final String scanLabel;
  final VoidCallback? onPaste;
  final VoidCallback? onScan;
  final bool showQr;

  @override
  Widget build(BuildContext context) {
    final paste = NozeltButton(
      label: pasteLabel,
      onPressed: onPaste,
      icon: const Icon(Icons.content_paste_rounded),
      variant: NozeltButtonVariant.secondary,
    );
    if (!showQr) return Align(alignment: Alignment.centerLeft, child: paste);
    return IntrinsicHeight(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(child: paste),
          const SizedBox(width: NozeltSpacing.sm),
          Expanded(
            child: NozeltButton(
              label: scanLabel,
              onPressed: onScan,
              icon: const Icon(Icons.qr_code_scanner_rounded),
              variant: NozeltButtonVariant.secondary,
            ),
          ),
        ],
      ),
    );
  }
}
