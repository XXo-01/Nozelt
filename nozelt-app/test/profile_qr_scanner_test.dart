import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:nozelt/nozelt_design_system.dart';
import 'package:nozelt/src/ui/profile_qr_scanner_screen.dart';

class _Camera extends MobileScannerPlatform {
  final events = StreamController<BarcodeCapture?>.broadcast();
  bool denied = false;
  int starts = 0, stops = 0, disposals = 0;
  @override
  Stream<BarcodeCapture?> get barcodesStream => events.stream;
  @override
  Stream<TorchState> get torchStateStream => const Stream.empty();
  @override
  Stream<double> get zoomScaleStateStream => const Stream.empty();
  @override
  Widget buildCameraView() => const ColoredBox(color: Colors.black);
  @override
  Future<MobileScannerViewAttributes> start(StartOptions options) async {
    starts++;
    expect(options.formats, [BarcodeFormat.qrCode]);
    if (denied) {
      throw const MobileScannerException(
        errorCode: MobileScannerErrorCode.permissionDenied,
      );
    }
    return const MobileScannerViewAttributes(
      cameraDirection: CameraFacing.back,
      currentTorchMode: TorchState.off,
      size: Size(640, 480),
      numberOfCameras: 1,
    );
  }

  @override
  Future<void> stop() async {
    stops++;
  }

  @override
  Future<void> dispose() async {
    disposals++;
  }
}

void main() {
  late _Camera camera;
  late MobileScannerPlatform previous;
  setUp(() {
    previous = MobileScannerPlatform.instance;
    camera = _Camera();
    MobileScannerPlatform.instance = camera;
  });
  tearDown(() async {
    MobileScannerPlatform.instance = previous;
    await camera.events.close();
  });
  testWidgets(
    'Invalid QR stays on scanner; valid QR completes once and releases camera',
    (tester) async {
      final results = <String?>[];
      await _boot(tester, results);
      camera.events.add(
        BarcodeCapture(
          barcodes: const [
            Barcode(
              rawValue: 'unrelated private text',
              format: BarcodeFormat.qrCode,
            ),
          ],
        ),
      );
      await tester.pumpAndSettle();
      expect(
        find.text('Нужна HTTPS-ссылка подписки или ссылка прокси.'),
        findsOneWidget,
      );
      expect(results, isEmpty);
      final valid = BarcodeCapture(
        barcodes: const [
          Barcode(rawValue: 'vless://server', format: BarcodeFormat.qrCode),
        ],
      );
      camera.events.add(valid);
      camera.events.add(valid);
      await tester.pumpAndSettle();
      expect(results, ['vless://server']);
      expect(camera.disposals, 1);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets('Camera pauses in background and resumes only with permission', (
    tester,
  ) async {
    final results = <String?>[];
    await _boot(tester, results);
    final starts = camera.starts;
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    await tester.pump();
    expect(camera.stops, greaterThan(0));
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpAndSettle();
    expect(camera.starts, greaterThan(starts));
    await tester.tap(find.text('Отмена'));
    await tester.pumpAndSettle();
    expect(results, [null]);
    expect(camera.disposals, 1);
  });
  testWidgets('Denied permission offers retry and safe cancellation', (
    tester,
  ) async {
    camera.denied = true;
    final results = <String?>[];
    await _boot(tester, results);
    expect(
      find.text('Разрешите доступ к камере в настройках Android.'),
      findsOneWidget,
    );
    final starts = camera.starts;
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
    expect(camera.starts, starts);
    await tester.tap(find.text('Повторить'));
    await tester.pumpAndSettle();
    expect(camera.starts, starts + 1);
    await tester.tap(find.text('Отмена'));
    await tester.pumpAndSettle();
    expect(results, [null]);
    expect(camera.disposals, 1);
    expect(tester.takeException(), isNull);
  });
}

Future<void> _boot(WidgetTester tester, List<String?> results) async {
  final navigator = GlobalKey<NavigatorState>();
  await tester.pumpWidget(
    MaterialApp(
      navigatorKey: navigator,
      theme: NozeltTheme.forPlatform(TargetPlatform.android),
      locale: const Locale('ru'),
      supportedLocales: const [Locale('ru'), Locale('en')],
      localizationsDelegates: GlobalMaterialLocalizations.delegates,
      home: const Scaffold(body: Text('Import')),
    ),
  );
  navigator.currentState!
      .push<String>(
        MaterialPageRoute(builder: (_) => const ProfileQrScannerScreen()),
      )
      .then(results.add);
  await tester.pumpAndSettle();
}
