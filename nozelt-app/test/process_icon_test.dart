import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nozelt/src/ui/desktop/process_icon.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  tearDown(
    () => messenger.setMockMethodCallHandler(ProcessIconCache.channel, null),
  );

  test(
    'Icon requests share a pending result and normalize executable names',
    () async {
      var calls = 0;
      messenger.setMockMethodCallHandler(ProcessIconCache.channel, (
        call,
      ) async {
        expect(call.method, 'getProcessIcon');
        expect(call.arguments, 'steam.exe');
        calls++;
        return Uint8List.fromList([1, 2, 3]);
      });
      final cache = ProcessIconCache();
      final first = cache.load(' Steam.EXE ');
      expect(identical(first, cache.load('steam.exe')), isTrue);
      expect(await first, [1, 2, 3]);
      expect(await cache.load('Steam.exe'), [1, 2, 3]);
      expect(calls, 1);
    },
  );

  test(
    'Unknown processes and unavailable native host use the fallback',
    () async {
      final cache = ProcessIconCache();
      expect(await cache.load(''), isNull);
      expect(await cache.load('—'), isNull);
      expect(await cache.load('missing.exe'), isNull);
      messenger.setMockMethodCallHandler(ProcessIconCache.channel, (_) async {
        throw PlatformException(code: 'unavailable');
      });
      expect(await cache.load('system.exe'), isNull);
    },
  );

  test('Cache remains bounded and retains recently accessed entries', () async {
    final names = <String>[];
    messenger.setMockMethodCallHandler(ProcessIconCache.channel, (call) async {
      names.add(call.arguments as String);
      return Uint8List.fromList([1]);
    });
    final cache = ProcessIconCache();
    for (var index = 0; index < 128; index++) {
      await cache.load('$index.exe');
    }
    await cache.load('0.exe');
    await cache.load('128.exe');
    await cache.load('0.exe');
    expect(names.where((name) => name == '0.exe').length, 1);
    await cache.load('1.exe');
    expect(names.where((name) => name == '1.exe').length, 2);
  });
}
