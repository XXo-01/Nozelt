package dev.nozelt.nozelt

import android.content.Context
import org.json.JSONObject
import java.util.UUID

internal data class StoredRuntimeRollback(
    val id: String,
    val kind: String,
    val payload: String,
    val rolledBack: Boolean,
)

/**
 * Encrypted cross-process journal for the high-level state that produced one
 * live VPN replacement. The journal is normally deleted when the candidate
 * core starts. It becomes visible to Flutter only after Kotlin has restored
 * the last known-good runtime config, allowing bootstrap to restore the
 * matching profile/TUN/per-app snapshot before providers are created.
 */
internal class SecureRuntimeRollbackStore(context: Context) {
    companion object {
        private const val MAX_PLAINTEXT_BYTES = 32 * 1024 * 1024
        private val ALLOWED_KINDS = setOf("profiles", "tun", "split", "routingProfiles")
        private val MAGIC = byteArrayOf(
            'N'.code.toByte(),
            'Z'.code.toByte(),
            'J'.code.toByte(),
            1,
        )
        private val AAD =
            "dev.nozelt.nozelt:vpn-rollback:v1".toByteArray(Charsets.UTF_8)
    }

    private val store = EncryptedFileStore(
        context = context,
        keyAlias = "nozelt_vpn_rollback_aes_v1",
        fileName = "vpn-rollback.enc",
        magic = MAGIC,
        aad = AAD,
        maxPlaintextBytes = MAX_PLAINTEXT_BYTES,
    )

    fun stage(kind: String, payload: String): StoredRuntimeRollback {
        require(kind in ALLOWED_KINDS) { "unsupported runtime rollback kind" }
        require(payload.isNotBlank()) { "runtime rollback payload is empty" }
        val value = StoredRuntimeRollback(
            id = UUID.randomUUID().toString(),
            kind = kind,
            payload = payload,
            rolledBack = false,
        )
        write(value)
        return value
    }

    /**
     * Returns both pending and completed rollback records. Flutter bootstrap
     * must not pass a pending record: the service can still either confirm
     * the candidate (and delete it) or restore the previous runtime (and mark
     * it rolled back). Waiting for that decision prevents a late rollback
     * from overwriting already-loaded durable state on the next Activity.
     */
    fun readCurrent(): StoredRuntimeRollback? = read()

    fun markRolledBackIfId(id: String): Boolean {
        val current = read() ?: return false
        if (current.id != id) return false
        if (!current.rolledBack) write(current.copy(rolledBack = true))
        return true
    }

    /** Missing is already resolved; a different id must never be deleted. */
    fun resolveSuccessfulIfId(id: String): Boolean {
        val current = read() ?: return true
        if (current.id != id) return false
        return store.deleteIf { raw -> JSONObject(raw).optString("id") == id }
    }

    fun deleteIfId(id: String): Boolean = store.deleteIf { raw ->
        JSONObject(raw).optString("id") == id
    }

    private fun read(): StoredRuntimeRollback? {
        val raw = store.read() ?: return null
        val root = JSONObject(raw)
        val id = root.optString("id")
        val kind = root.optString("kind")
        val payload = root.optString("payload")
        require(id.isNotBlank()) { "runtime rollback id is empty" }
        require(kind in ALLOWED_KINDS) { "unsupported runtime rollback kind" }
        require(payload.isNotBlank()) { "runtime rollback payload is empty" }
        return StoredRuntimeRollback(
            id = id,
            kind = kind,
            payload = payload,
            rolledBack = root.optBoolean("rolledBack", false),
        )
    }

    private fun write(value: StoredRuntimeRollback) {
        store.write(
            JSONObject()
                .put("id", value.id)
                .put("kind", value.kind)
                .put("payload", value.payload)
                .put("rolledBack", value.rolledBack)
                .toString(),
        )
    }
}
