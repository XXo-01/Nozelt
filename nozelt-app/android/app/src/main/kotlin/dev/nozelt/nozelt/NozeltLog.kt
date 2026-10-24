package dev.nozelt.nozelt

/**
 * Release-silent Android logging facade.
 *
 * VPN lifecycle markers are useful while developing, but publishing them to
 * logcat in production exposes unnecessary network and recovery state to USB
 * diagnostics, OEM support collectors and privileged applications. Keep the
 * existing call sites readable while compiling their output down to a cheap
 * branch in release builds. Secret-bearing values must still never be passed
 * here: debug devices can be shared and logcat can be exported by the user.
 */
internal object NozeltLog {
    fun i(tag: String, message: String) {
        if (BuildConfig.DEBUG) android.util.Log.i(tag, message)
    }

    fun w(tag: String, message: String) {
        if (BuildConfig.DEBUG) android.util.Log.w(tag, message)
    }

    fun e(tag: String, message: String) {
        if (BuildConfig.DEBUG) android.util.Log.e(tag, message)
    }
}
