package dev.nozelt.nozelt

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class NotificationPingFreshnessTest {
    @Test
    fun freshPingIsVisibleUntilItsDeadline() {
        assertEquals(
            87,
            NotificationPingFreshness.currentPing(
                pingMs = 87,
                measuredAtMs = 1_000L,
                maxAgeMs = 120_000L,
                nowMs = 120_999L,
            ),
        )
        assertNull(
            NotificationPingFreshness.currentPing(
                pingMs = 87,
                measuredAtMs = 1_000L,
                maxAgeMs = 120_000L,
                nowMs = 121_000L,
            ),
        )
    }

    @Test
    fun missingFutureOrFailedMeasurementsAreNeverShown() {
        assertNull(NotificationPingFreshness.currentPing(-1, 1_000L, 120_000L, 2_000L))
        assertNull(NotificationPingFreshness.currentPing(87, -1L, 120_000L, 2_000L))
        assertNull(NotificationPingFreshness.currentPing(87, 3_000L, 120_000L, 2_000L))
    }

    @Test
    fun expiryDelayMatchesRemainingFreshness() {
        assertEquals(
            90_000L,
            NotificationPingFreshness.remainingFreshMs(
                pingMs = 42,
                measuredAtMs = 10_000L,
                maxAgeMs = 120_000L,
                nowMs = 40_000L,
            ),
        )
    }
}
