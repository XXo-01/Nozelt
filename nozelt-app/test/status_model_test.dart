import 'package:flutter_test/flutter_test.dart';
import 'package:nozelt/src/core/models.dart';

void main() {
  const base = <String, dynamic>{
    'running': true,
    'startedAtUnix': 1,
    'uptimeSeconds': 2,
    'mihomoVersion': '1.2.3',
    'nozeltCoreVersion': '0.1.0',
  };

  test('decodes aggregate socket protection diagnostics', () {
    final status = Status.fromJson({
      ...base,
      'socketProtection': true,
      'protectedSockets': 42,
      'protectionFailures': 1,
    });

    expect(status.socketProtection, isTrue);
    expect(status.protectedSockets, 42);
    expect(status.protectionFailures, 1);
  });

  test('new diagnostics remain compatible with an older core', () {
    final status = Status.fromJson(base);

    expect(status.socketProtection, isFalse);
    expect(status.protectedSockets, 0);
    expect(status.protectionFailures, 0);
  });
}
