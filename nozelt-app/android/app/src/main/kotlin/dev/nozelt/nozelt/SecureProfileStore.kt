package dev.nozelt.nozelt

import android.content.Context

/**
 * Keystore-backed storage for credential-bearing VPN profiles.
 *
 * File format: `NZP1` magic, 12-byte GCM IV, then ciphertext+128-bit tag.
 * The key is non-exportable and generated inside Android Keystore. The file is
 * kept in noBackupFilesDir so it is not copied to cloud/device backups where
 * the device-bound key would be unavailable anyway.
 */
class SecureProfileStore(private val context: Context) {

    companion object {
        private const val KEY_ALIAS = "nozelt_profiles_aes_v1"
        private const val FILE_NAME = "profiles.enc"
        private const val MAX_PLAINTEXT_BYTES = 32 * 1024 * 1024
        private val MAGIC = byteArrayOf('N'.code.toByte(), 'Z'.code.toByte(), 'P'.code.toByte(), 1)
        private val AAD = "dev.nozelt.nozelt:profiles:v1".toByteArray(Charsets.UTF_8)
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
