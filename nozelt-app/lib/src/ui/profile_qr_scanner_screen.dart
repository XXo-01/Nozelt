import 'dart:async';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:nozelt/nozelt_design_system.dart';
import '../l10n/nozelt_l10n.dart';
import 'profile_import_payload.dart';

class ProfileQrScannerScreen extends StatefulWidget {
  const ProfileQrScannerScreen({super.key});
  @override
  State<ProfileQrScannerScreen> createState() => _ProfileQrScannerScreenState();
}

class _ProfileQrScannerScreenState extends State<ProfileQrScannerScreen>
    with WidgetsBindingObserver {
  final _controller = MobileScannerController(
    formats: const [BarcodeFormat.qrCode],
    detectionSpeed: DetectionSpeed.noDuplicates,
  );
  bool _completed = false;
  String? _errorKey;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // A permission prompt itself changes lifecycle. Wait for its result.
    if (!_controller.value.hasCameraPermission || _completed) return;
    unawaited(_camera(state == AppLifecycleState.resumed));
  }

  Future<void> _camera(bool start) async {
    try {
      if (start) {
        await _controller.start();
      } else {
        await _controller.stop();
      }
    } on MobileScannerException {
      // The controller publishes camera errors to MobileScanner.errorBuilder.
    }
  }

  void _onDetect(BarcodeCapture capture) {
    if (_completed || !mounted) return;
    for (final barcode in capture.barcodes) {
      final value = barcode.rawValue;
      if (barcode.format != BarcodeFormat.qrCode || value == null) continue;
      try {
        final payload = ProfileImportPayload.parse(value);
        _completed = true;
        unawaited(_camera(false));
        Navigator.of(context).pop(payload.text);
        return;
      } on ProfileImportException catch (error) {
        setState(() => _errorKey = error.messageKey);
      }
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    unawaited(_controller.dispose());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: Text(context.tr('importScanQr'))),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(NozeltSpacing.lg),
          child: Column(
            children: [
              Expanded(
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(NozeltRadii.card),
                  child: MobileScanner(
                    controller: _controller,
                    onDetect: _onDetect,
                    tapToFocus: true,
                    errorBuilder: (context, error) => ColoredBox(
                      color: scheme.surface,
                      child: Center(
                        child: SingleChildScrollView(
                          child: Padding(
                            padding: const EdgeInsets.all(NozeltSpacing.xxl),
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(
                                  Icons.no_photography_outlined,
                                  color: scheme.onSurfaceVariant,
                                  size: 48,
                                ),
                                const SizedBox(height: NozeltSpacing.lg),
                                Text(
                                  context.tr(
                                    error.errorCode ==
                                            MobileScannerErrorCode
                                                .permissionDenied
                                        ? 'importCameraPermission'
                                        : 'importCameraUnavailable',
                                  ),
                                  textAlign: TextAlign.center,
                                ),
                                const SizedBox(height: NozeltSpacing.lg),
                                NozeltButton(
                                  label: context.tr('importRetryCamera'),
                                  variant: NozeltButtonVariant.secondary,
                                  onPressed: () => unawaited(_camera(true)),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ),
                    overlayBuilder: (context, constraints) {
                      final side =
                          math.min(
                            constraints.maxWidth,
                            constraints.maxHeight,
                          ) *
                          .75;
                      return IgnorePointer(
                        child: Center(
                          child: Container(
                            width: side,
                            height: side,
                            decoration: BoxDecoration(
                              border: Border.all(
                                color: scheme.primary,
                                width: NozeltStates.focusBorderWidth,
                              ),
                              borderRadius: BorderRadius.circular(
                                NozeltRadii.control,
                              ),
                            ),
                          ),
                        ),
                      );
                    },
                  ),
                ),
              ),
              const SizedBox(height: NozeltSpacing.lg),
              Text(
                context.tr(_errorKey ?? 'importQrAim'),
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: _errorKey == null
                      ? scheme.onSurfaceVariant
                      : scheme.error,
                ),
              ),
              const SizedBox(height: NozeltSpacing.lg),
              SizedBox(
                width: double.infinity,
                child: NozeltButton(
                  label: context.tr('cancel'),
                  onPressed: () => Navigator.of(context).pop(),
                  variant: NozeltButtonVariant.secondary,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
