/// A notification sample survives a missed check, but never long enough to be
/// mistaken for current latency after the device has changed networks.
Duration notificationPingMaxAge(int intervalSeconds) {
  if (intervalSeconds <= 0) return Duration.zero;
  final seconds = (intervalSeconds * 2).clamp(120, 900);
  return Duration(seconds: seconds);
}

bool isNotificationPingFresh({
  required DateTime checkedAt,
  required DateTime now,
  required Duration maxAge,
}) {
  final age = now.difference(checkedAt);
  return !age.isNegative && age < maxAge;
}
