package dev.nozelt.nozelt

import android.net.TrafficStats
import android.os.Process
import android.os.SystemClock

internal data class NativeTrafficSnapshot(
    val uploadBytes: Long = 0L,
    val downloadBytes: Long = 0L,
    val uploadSpeedBps: Long = 0L,
    val downloadSpeedBps: Long = 0L,
)

/**
 * Session traffic for the standalone Xray/sing-box child.
 *
 * Android accounts all sockets opened by those forked executables to
 * Nozelt's UID. Reading the platform's monotonic UID counters keeps counting
 * outside the TUN hot path and works identically for both native cores.
 */
internal class NativeCoreTrafficTracker(
    private val readCounters: () -> Pair<Long, Long> = {
        TrafficStats.getUidRxBytes(Process.myUid()) to
            TrafficStats.getUidTxBytes(Process.myUid())
    },
    private val elapsedRealtime: () -> Long = SystemClock::elapsedRealtime,
) {
    private var active = false
    private var baselineRx = 0L
    private var baselineTx = 0L
    private var lastRx = 0L
    private var lastTx = 0L
    private var lastSampleMillis = 0L

    @Synchronized
    fun start() {
        val (rx, tx) = normalizedCounters()
        baselineRx = rx
        baselineTx = tx
        lastRx = rx
        lastTx = tx
        lastSampleMillis = elapsedRealtime()
        active = true
    }

    @Synchronized
    fun stop() {
        active = false
        baselineRx = 0L
        baselineTx = 0L
        lastRx = 0L
        lastTx = 0L
        lastSampleMillis = 0L
    }

    @Synchronized
    fun sample(): NativeTrafficSnapshot {
        if (!active) return NativeTrafficSnapshot()
        val now = elapsedRealtime()
        val (rx, tx) = normalizedCounters()

        // OEM network accounting can restart independently of the app.
        if (rx < baselineRx || tx < baselineTx) {
            baselineRx = rx
            baselineTx = tx
            lastRx = rx
            lastTx = tx
            lastSampleMillis = now
            return NativeTrafficSnapshot()
        }

        val elapsed = (now - lastSampleMillis).coerceAtLeast(0L)
        val snapshot = NativeTrafficSnapshot(
            uploadBytes = (tx - baselineTx).coerceAtLeast(0L),
            downloadBytes = (rx - baselineRx).coerceAtLeast(0L),
            uploadSpeedBps = bytesPerSecond((tx - lastTx).coerceAtLeast(0L), elapsed),
            downloadSpeedBps = bytesPerSecond((rx - lastRx).coerceAtLeast(0L), elapsed),
        )
        lastRx = rx
        lastTx = tx
        lastSampleMillis = now
        return snapshot
    }

    private fun normalizedCounters(): Pair<Long, Long> {
        val (rx, tx) = readCounters()
        return rx.coerceAtLeast(0L) to tx.coerceAtLeast(0L)
    }

    private fun bytesPerSecond(bytes: Long, elapsedMillis: Long): Long {
        if (bytes <= 0L || elapsedMillis <= 0L) return 0L
        return bytes * 1000L / elapsedMillis
    }
}
