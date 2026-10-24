package dev.nozelt.nozelt

/** Pure freshness rules shared by the notification renderer and JVM tests. */
internal object NotificationPingFreshness {
    private const val DEFAULT_MAX_AGE_MS = 2 * 60_000L
    private const val MIN_MAX_AGE_MS = 30_000L
    private const val MAX_MAX_AGE_MS = 30 * 60_000L

    fun normalizedMaxAge(value: Long?): Long =
        (value ?: DEFAULT_MAX_AGE_MS).coerceIn(MIN_MAX_AGE_MS, MAX_MAX_AGE_MS)

    fun currentPing(
        pingMs: Int,
        measuredAtMs: Long,
        maxAgeMs: Long,
        nowMs: Long,
    ): Int? = if (
        pingMs > 0 &&
        measuredAtMs > 0L &&
        nowMs >= measuredAtMs &&
        nowMs - measuredAtMs < normalizedMaxAge(maxAgeMs)
    ) {
        pingMs
    } else {
        null
    }

    fun remainingFreshMs(
        pingMs: Int,
        measuredAtMs: Long,
        maxAgeMs: Long,
        nowMs: Long,
    ): Long? {
        if (currentPing(pingMs, measuredAtMs, maxAgeMs, nowMs) == null) return null
        return normalizedMaxAge(maxAgeMs) - (nowMs - measuredAtMs)
    }
}
