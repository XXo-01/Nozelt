package dev.nozelt.nozelt

import android.content.Context

/** Keystore-backed storage for routing, DNS, and per-app VPN settings. */
class SecureSettingsStore(context: Context) {

    companion object {
        private const val KEY_ALIAS = "nozelt_sensitive_settings_aes_v1"
        private const val FILE_NAME = "sensitive-settings.enc"
        private const val MAX_PLAINTEXT_BYTES = 2 * 1024 * 1024
        private val MAGIC = byteArrayOf('N'.code.toByte(), 'Z'.code.toByte(), 'S'.code.toByte(), 1)
        private val AAD = "dev.nozelt.nozelt:sensitive-settings:v1".toByteArray(Charsets.UTF_8)
    }

    private val store = EncryptedFileStore(
        context = context,
        keyAlias = KEY_ALIAS,
        fileName = FILE_NAME,
        magic = MAGIC,
        aad = AAD,
        maxPlaintextBytes = MAX_PLAINTEXT_BYTES,
    )

    fun read(): String? = store.read()

    fun write(value: String) = store.write(value)
}
