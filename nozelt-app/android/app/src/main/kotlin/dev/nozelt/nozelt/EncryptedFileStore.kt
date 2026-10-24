package dev.nozelt.nozelt

import android.content.Context
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.AtomicFile
import java.io.File
import java.security.KeyStore
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

/** Small AES-256-GCM store backed by a non-exportable Android Keystore key. */
internal class EncryptedFileStore(
    context: Context,
    private val keyAlias: String,
    fileName: String,
    private val magic: ByteArray,
    private val aad: ByteArray,
    private val maxPlaintextBytes: Int,
) {
    companion object {
        private const val TRANSFORMATION = "AES/GCM/NoPadding"
        private const val GCM_TAG_BITS = 128
        private const val GCM_TAG_BYTES = GCM_TAG_BITS / 8
        private const val IV_SIZE = 12
        // Activity and VpnService create separate store wrappers in the same
        // process. One monitor prevents an old service cleanup from racing a
        // new Activity write through AtomicFile.
        private val PROCESS_LOCK = Any()
    }

    private val atomicFile = AtomicFile(File(context.noBackupFilesDir, fileName))
    init {
        require(magic.size == 4) { "encrypted store magic must be four bytes" }
        require(maxPlaintextBytes > 0) { "encrypted store size limit must be positive" }
    }

    fun read(): String? = synchronized(PROCESS_LOCK) {
        if (!atomicFile.baseFile.exists()) return@synchronized null
        val maximumFileBytes = magic.size + IV_SIZE + maxPlaintextBytes + GCM_TAG_BYTES
        require(atomicFile.baseFile.length() in (magic.size + IV_SIZE + GCM_TAG_BYTES).toLong()..maximumFileBytes.toLong()) {
            "encrypted store has an invalid size"
        }

        val bytes = atomicFile.readFully()
        require(bytes.copyOfRange(0, magic.size).contentEquals(magic)) {
            "unsupported encrypted store version"
        }

        val iv = bytes.copyOfRange(magic.size, magic.size + IV_SIZE)
        val ciphertext = bytes.copyOfRange(magic.size + IV_SIZE, bytes.size)
        try {
            val cipher = Cipher.getInstance(TRANSFORMATION)
            cipher.init(Cipher.DECRYPT_MODE, getOrCreateKey(), GCMParameterSpec(GCM_TAG_BITS, iv))
            cipher.updateAAD(aad)
            val plaintext = cipher.doFinal(ciphertext)
            require(plaintext.size <= maxPlaintextBytes) { "decrypted store exceeds its size limit" }
            plaintext.toString(Charsets.UTF_8).also { plaintext.fill(0) }
        } finally {
            iv.fill(0)
            ciphertext.fill(0)
            bytes.fill(0)
        }
    }

    fun write(value: String) = synchronized(PROCESS_LOCK) {
        val plaintext = value.toByteArray(Charsets.UTF_8)
        require(plaintext.size <= maxPlaintextBytes) { "encrypted store exceeds its size limit" }
        val cipher = Cipher.getInstance(TRANSFORMATION)
        cipher.init(Cipher.ENCRYPT_MODE, getOrCreateKey())
        cipher.updateAAD(aad)
        val ciphertext = try {
            cipher.doFinal(plaintext)
        } finally {
            plaintext.fill(0)
        }
        val iv = cipher.iv
        require(iv.size == IV_SIZE) { "unexpected GCM IV size" }

        val output = atomicFile.startWrite()
        try {
            output.write(magic)
            output.write(iv)
            output.write(ciphertext)
            atomicFile.finishWrite(output)
        } catch (t: Throwable) {
            atomicFile.failWrite(output)
            throw t
        } finally {
            iv.fill(0)
            ciphertext.fill(0)
        }
    }

    fun delete() = synchronized(PROCESS_LOCK) {
        atomicFile.delete()
    }

    fun deleteIf(predicate: (String) -> Boolean): Boolean = synchronized(PROCESS_LOCK) {
        val value = read() ?: return@synchronized false
        if (!predicate(value)) return@synchronized false
        atomicFile.delete()
        true
    }

    private fun getOrCreateKey(): SecretKey {
        val keyStore = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
        (keyStore.getKey(keyAlias, null) as? SecretKey)?.let { return it }

        val generator = KeyGenerator.getInstance(
            KeyProperties.KEY_ALGORITHM_AES,
            "AndroidKeyStore",
        )
        generator.init(
            KeyGenParameterSpec.Builder(
                keyAlias,
                KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT,
            )
                .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
                .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
                .setKeySize(256)
                .setRandomizedEncryptionRequired(true)
                .build(),
        )
        return generator.generateKey()
    }
}
