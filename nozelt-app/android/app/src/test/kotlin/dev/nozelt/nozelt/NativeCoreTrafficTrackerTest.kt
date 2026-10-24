package dev.nozelt.nozelt

import org.junit.Assert.assertEquals
import org.junit.Test

class NativeCoreTrafficTrackerTest {
    private var rx = 1_000L
    private var tx = 2_000L
    private var elapsed = 10_000L
    private val tracker = NativeCoreTrafficTracker(
        readCounters = { rx to tx },
        elapsedRealtime = { elapsed },
    )

    @Test
    fun reportsSessionTotalsAndSpeeds() {
        tracker.start()
        rx += 4_000L
        tx += 1_500L
        elapsed += 2_000L

        assertEquals(
            NativeTrafficSnapshot(
                uploadBytes = 1_500L,
                downloadBytes = 4_000L,
                uploadSpeedBps = 750L,
                downloadSpeedBps = 2_000L,
            ),
            tracker.sample(),
        )
    }

    @Test
    fun restartCreatesANewSessionBaseline() {
        tracker.start()
        rx += 3_000L
        tx += 2_000L
        elapsed += 1_000L
        tracker.sample()
        tracker.stop()
        assertEquals(NativeTrafficSnapshot(), tracker.sample())

        tracker.start()
        rx += 700L
        tx += 300L
        elapsed += 1_000L
        val restarted = tracker.sample()
        assertEquals(700L, restarted.downloadBytes)
        assertEquals(300L, restarted.uploadBytes)
    }

    @Test
    fun platformCounterResetDoesNotProduceANegativeFrame() {
        tracker.start()
        rx = 20L
        tx = 30L
        elapsed += 1_000L
        assertEquals(NativeTrafficSnapshot(), tracker.sample())

        rx += 80L
        tx += 40L
        elapsed += 1_000L
        val recovered = tracker.sample()
        assertEquals(80L, recovered.downloadBytes)
        assertEquals(40L, recovered.uploadBytes)
        assertEquals(80L, recovered.downloadSpeedBps)
        assertEquals(40L, recovered.uploadSpeedBps)
    }
}
