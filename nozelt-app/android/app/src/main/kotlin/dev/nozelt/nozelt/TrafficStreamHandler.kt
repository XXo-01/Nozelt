package dev.nozelt.nozelt

import android.os.Handler
import android.os.Looper
import dev.nozelt.nozelt.NozeltLog as Log
import io.flutter.plugin.common.EventChannel
import java.util.concurrent.Executors
import java.util.concurrent.ScheduledExecutorService
import java.util.concurrent.ScheduledFuture
import java.util.concurrent.TimeUnit

/**
 * Pushes one JSON frame per second to the `dev.nozelt.nozelt/traffic` event
 * stream while a Dart listener is attached.
 *
 * Iteration 2: the Go side wires `tunnel/statistic.DefaultManager` into
 * `Binding.getTraffic()`, so this handler is now a pure forwarder — it
 * polls Go once per second and emits the JSON verbatim. The legacy
 * synthetic generator from iteration 1 is gone; if the Go side ever stops
 * reporting real numbers (older .aar swapped in, ABI regression) we want
 * the UI to show zeros rather than fabricated traffic.
 *
 * The `synthetic` field in the JSON is left to the Dart layer to interpret.
 * After iteration 2 it is always `false` from Go.
 */
class TrafficStreamHandler : EventChannel.StreamHandler {

    companion object {
        private const val TAG = "TrafficStreamHandler"
    }

    // A disconnected cold start and background/other-tab UI need no polling
    // thread at all. Create the scheduler only for an attached Dart consumer
    // and release it again on cancellation.
    private var executor: ScheduledExecutorService? = null
    private val mainHandler = Handler(Looper.getMainLooper())

    private var task: ScheduledFuture<*>? = null

    @Volatile
    private var sink: EventChannel.EventSink? = null

    // While the Activity is stopped nothing is drawn, so Dart cannot drop
    // its subscription. Polling pauses here instead of waking every second.
    private var paused = false

    fun pause() {
        paused = true
        stopPolling()
    }

    fun resume() {
        paused = false
        if (sink != null) startPolling()
    }

    override fun onListen(arguments: Any?, events: EventChannel.EventSink) {
        sink = events
        if (!paused) startPolling()
    }

    private fun startPolling() {
        if (task?.isCancelled == false) return
        val scheduler = Executors.newSingleThreadScheduledExecutor { r ->
            Thread(r, "nozelt-traffic").apply { isDaemon = true }
        }
        executor = scheduler
        // Fixed delay cannot accumulate a burst of missed frames while an OEM
        // freezes/caches the process in the background.
        task = scheduler.scheduleWithFixedDelay(::emitFrame, 0L, 1L, TimeUnit.SECONDS)
    }

    override fun onCancel(arguments: Any?) {
        sink = null
        stopPolling()
    }

    private fun stopPolling() {
        task?.cancel(false)
        task = null
        executor?.shutdownNow()
        executor = null
    }

    fun shutdown() {
        onCancel(null)
    }

    private fun emitFrame() {
        val frame = pollGoTraffic() ?: return
        val current = sink ?: return
        mainHandler.post {
            // Cancellation/backgrounding can race the main-thread delivery.
            // Never emit a captured frame into an EventSink that Flutter has
            // already detached and potentially replaced with a new listener.
            if (sink === current) current.success(frame)
        }
    }

    /**
     * Polls `Binding.getTraffic()` and returns the JSON string as-is.
     *
     * Returns `null` if the native call fails. Dart already handles malformed
     * stream frames and parses every valid frame, so validating the same JSON
     * here would duplicate work once per second.
     */
    private fun pollGoTraffic(): String? {
        return try {
            EngineBridge.getTrafficJsonSync()
        } catch (_: Throwable) {
            Log.w(TAG, "Active core traffic query failed")
            null
        }
    }
}
