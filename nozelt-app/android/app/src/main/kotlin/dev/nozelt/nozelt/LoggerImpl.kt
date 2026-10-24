package dev.nozelt.nozelt

import android.os.Handler
import android.os.Looper
import android.util.Log
import binding.Logger as GoLogger
import io.flutter.plugin.common.EventChannel
import org.json.JSONObject

/**
 * Bridge from the Go-side `binding.Logger` interface to a Flutter
 * `EventChannel.EventSink`.
 *
 * The callback is invoked from arbitrary Go goroutines, but `EventSink.success`
 * is only valid on the platform main thread, so every emit is hopped through
 * a main-looper Handler. Logcat is used only in debuggable builds; release
 * builds emit redacted lines solely to an explicitly attached diagnostics UI.
 */
class LoggerImpl(private val logcatEnabled: Boolean) : GoLogger {

    private val mainHandler = Handler(Looper.getMainLooper())

    @Volatile
    private var sink: EventChannel.EventSink? = null

    fun attach(eventSink: EventChannel.EventSink) {
        sink = eventSink
    }

    fun detach() {
        sink = null
    }

    override fun log(level: String, message: String) {
        val safeMessage = redact(message)
        if (logcatEnabled) {
            Log.println(levelToLogcat(level), TAG, safeMessage)
        }

        val target = sink ?: return

        val payload = JSONObject()
            .put("level", level)
            .put("message", safeMessage)
            .put("timestampMs", System.currentTimeMillis())
            .toString()

        mainHandler.post {
            // A cancellation/re-listen can happen while this frame waits in
            // the main queue. Never deliver a line produced for an obsolete
            // diagnostics subscription to its replacement sink.
            if (sink === target) target.success(payload)
        }
    }

    private fun levelToLogcat(level: String): Int = when (level) {
        "debug" -> Log.DEBUG
        "info" -> Log.INFO
        "warning" -> Log.WARN
        "error" -> Log.ERROR
        else -> Log.INFO
    }

    private fun redact(message: String): String = message
        // Bound attacker-controlled upstream log payloads before running the
        // regular-expression redactors. The final diagnostics line is smaller
        // still, but this pre-limit also caps temporary allocations/regex work.
        .take(MAX_RAW_LOG_CHARACTERS)
        .replace(CONTROL_PATTERN, " ")
        .replace(URI_PATTERN, "<redacted-uri>")
        .replace(CREDENTIAL_PATTERN, "$1=<redacted>")
        .replace(IPV4_PATTERN, "<redacted-ip>")
        .replace(IPV6_PATTERN, "<redacted-ip>")
        .replace(HOSTNAME_PATTERN, "<redacted-host>")
        .take(MAX_LOG_CHARACTERS)

    companion object {
        private const val TAG = "nozelt-core"
        private const val MAX_RAW_LOG_CHARACTERS = 8192
        private const val MAX_LOG_CHARACTERS = 2048
        private val CONTROL_PATTERN = Regex("[\\u0000-\\u001F\\u007F]")
        private val URI_PATTERN = Regex("(?i)\\b[a-z][a-z0-9+.-]*://\\S+")
        private val CREDENTIAL_PATTERN = Regex(
            "(?i)\\b(password|passwd|obfs-password|token|authorization|uuid|secret|client-secret|private-key|psk)\\b[\\\"']?\\s*[:=]\\s*[\\\"']?[^\\\"',;\\s}\\]]+",
        )
        private val IPV4_PATTERN = Regex(
            "(?<![A-Za-z0-9_.])(?:[0-9]{1,3}\\.){3}[0-9]{1,3}(?::[0-9]{1,5})?",
        )
        private val IPV6_PATTERN = Regex(
            "(?i)(?:\\[[0-9a-f:]+]|(?<![A-Za-z0-9:])(?:[0-9a-f]{0,4}:){2,}[0-9a-f:]{0,4})(?::[0-9]{1,5})?",
        )
        private val HOSTNAME_PATTERN = Regex(
            "(?i)(?<![A-Za-z0-9_.-])(?:[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\\.)+[a-z]{2,63}(?::[0-9]{1,5})?",
        )
    }
}
