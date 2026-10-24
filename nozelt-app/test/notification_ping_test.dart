import 'package:flutter_test/flutter_test.dart';
import 'package:nozelt/src/core/notification_ping.dart';

void main() {
  test('notification ping age follows the configured interval', () {
    expect(notificationPingMaxAge(10), const Duration(minutes: 2));
    expect(notificationPingMaxAge(60), const Duration(minutes: 2));
    expect(notificationPingMaxAge(300), const Duration(minutes: 10));
    expect(notificationPingMaxAge(3600), const Duration(minutes: 15));
    expect(notificationPingMaxAge(0), Duration.zero);
  });

  test('future and expired measurements are not fresh', () {
    final now = DateTime.utc(2026, 8, 25, 12);
    expect(
      isNotificationPingFresh(
        checkedAt: now.subtract(const Duration(seconds: 119)),
        now: now,
        maxAge: const Duration(minutes: 2),
      ),
      isTrue,
    );
    expect(
      isNotificationPingFresh(
        checkedAt: now.subtract(const Duration(minutes: 2)),
        now: now,
        maxAge: const Duration(minutes: 2),
      ),
      isFalse,
    );
    expect(
      isNotificationPingFresh(
        checkedAt: now.add(const Duration(seconds: 1)),
        now: now,
        maxAge: const Duration(minutes: 2),
      ),
      isFalse,
    );
  });
}
