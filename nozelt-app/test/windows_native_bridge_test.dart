import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nozelt/src/core/windows_native_bridge.dart';

void main() {
  test('Windows DPAPI bridge round-trips profile data', () {
    if (!Platform.isWindows) return;
    final bridge = WindowsNativeBridge.open();
    const plaintext = '{"test":"profile-secret"}';

    final protected = bridge.protectData(plaintext);

    expect(protected, isNot(contains('profile-secret')));
    expect(bridge.unprotectData(protected), plaintext);
  });

  test('Windows DPAPI bridge rejects malformed ciphertext', () {
    if (!Platform.isWindows) return;
    final bridge = WindowsNativeBridge.open();

    expect(() => bridge.unprotectData('not-dpapi'), throwsStateError);
  });
}
