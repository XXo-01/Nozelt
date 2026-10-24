package dev.nozelt.nozelt

import android.content.Context
import org.json.JSONObject
import java.util.UUID

internal data class StoredVpnConfig(
    val requestId: String,
    val core: VpnCore = VpnCore.MIHOMO,
    val configYaml: String,
    val tunOptionsJson: String?,
    val selectedGroupName: String? = null,
    val selectedProxyName: String? = null,
    /**
     * Last known-good live generation retained only while a replacement is
     * pending. This lets the foreground service recover without Flutter if
     * the UI process dies between persisting a new setting and observing a
     * failed native restart.
     */
    val fallbackConfigYaml: String? = null,
    val fallbackCore: VpnCore? = null,
    val fallbackTunOptionsJson: String? = null,
    val fallbackSelectedGroupName: String? = null,
    val fallbackSelectedProxyName: String? = null,
    val rollbackJournalId: String? = null,
    val fallbackRestored: Boolean = false,
)

/** Pure transition rules kept separate so rollback semantics are unit-testable. */
internal object RuntimeConfigTransitions {
    /** Compatibility overload that keeps the currently selected core. */
    fun stage(
        previous: StoredVpnConfig,
        configYaml: String,
        tunOptionsJson: String?,
        newRollbackJournalId: String? = null,
    ): StoredVpnConfig = stage(
        previous,
        previous.core,
        configYaml,
        tunOptionsJson,
        newRollbackJournalId,
    )

    fun stage(
        previous: StoredVpnConfig,
        core: VpnCore,
        configYaml: String,
        tunOptionsJson: String?,
        newRollbackJournalId: String? = null,
    ): StoredVpnConfig {
        val journalId = newRollbackJournalId ?: previous.rollbackJournalId
        return when {
            previous.core == core &&
                previous.configYaml == configYaml &&
                previous.tunOptionsJson == tunOptionsJson -> previous.copy(
                rollbackJournalId = journalId,
                fallbackRestored = false,
            )
            previous.fallbackCore == core &&
                previous.fallbackConfigYaml == configYaml &&
                previous.fallbackTunOptionsJson == tunOptionsJson -> StoredVpnConfig(
                requestId = previous.requestId,
                core = core,
                configYaml = configYaml,
                tunOptionsJson = tunOptionsJson,
                selectedGroupName = previous.fallbackSelectedGroupName,
                selectedProxyName = previous.fallbackSelectedProxyName,
                rollbackJournalId = journalId,
                fallbackRestored = journalId != null,
            )
            else -> StoredVpnConfig(
                requestId = previous.requestId,
                core = core,
                configYaml = configYaml,
                tunOptionsJson = tunOptionsJson,
                fallbackCore = previous.core,
                fallbackConfigYaml = previous.configYaml,
                fallbackTunOptionsJson = previous.tunOptionsJson,
                fallbackSelectedGroupName = previous.selectedGroupName,
                fallbackSelectedProxyName = previous.selectedProxyName,
                rollbackJournalId = journalId,
            )
        }
    }

    fun fallback(
        current: StoredVpnConfig,
        failed: StoredVpnConfig,
    ): StoredVpnConfig? {
        if (!sameCandidate(current, failed)) return null
        val fallbackConfig = current.fallbackConfigYaml ?: return null
        return StoredVpnConfig(
            requestId = current.requestId,
            core = current.fallbackCore ?: VpnCore.MIHOMO,
            configYaml = fallbackConfig,
            tunOptionsJson = current.fallbackTunOptionsJson,
            selectedGroupName = current.fallbackSelectedGroupName,
            selectedProxyName = current.fallbackSelectedProxyName,
            rollbackJournalId = current.rollbackJournalId,
            fallbackRestored = true,
        )
    }

    /**
     * Persists selector state without parsing and re-serializing the complete
     * proxy config. Android's JSONObject normalizes some third-party numeric
     * values; that can turn an otherwise valid mihomo config into a different
     * (and occasionally invalid) document after a process restart.
     */
    fun selectProxy(
        previous: StoredVpnConfig,
        groupName: String,
        proxyName: String,
    ): StoredVpnConfig {
        val config = JSONObject(previous.configYaml)
        val groups = config.optJSONArray("proxy-groups")
            ?: error("active VPN config has no proxy groups")
        var foundGroup = false
        var foundProxy = false
        for (index in 0 until groups.length()) {
            val group = groups.optJSONObject(index) ?: continue
            if (group.optString("name") != groupName) continue
            foundGroup = true
            val proxies = group.optJSONArray("proxies")
                ?: error("active selector has no proxies")
            for (proxyIndex in 0 until proxies.length()) {
                if (proxies.optString(proxyIndex) == proxyName) {
                    foundProxy = true
                    break
                }
            }
            break
        }
        require(foundGroup) { "active selector is absent from config" }
        require(foundProxy) { "selected proxy is absent from active config" }
        return recordSelectedProxy(previous, groupName, proxyName)
    }

    internal fun recordSelectedProxy(
        previous: StoredVpnConfig,
        groupName: String,
        proxyName: String,
    ): StoredVpnConfig = previous.copy(
        selectedGroupName = groupName,
        selectedProxyName = proxyName,
    )

    fun sameCandidate(left: StoredVpnConfig, right: StoredVpnConfig): Boolean =
        left.requestId == right.requestId &&
            left.core == right.core &&
            left.configYaml == right.configYaml &&
            left.tunOptionsJson == right.tunOptionsJson &&
            left.selectedGroupName == right.selectedGroupName &&
            left.selectedProxyName == right.selectedProxyName &&
            left.rollbackJournalId == right.rollbackJournalId &&
            left.fallbackRestored == right.fallbackRestored
}

/**
 * Encrypted, device-bound copy of the active rendered config. It exists only
 * while VPN operation is requested and lets Android restart the service after
 * an OEM/low-memory kill without placing proxy credentials in Intent extras.
 */
internal class SecureRuntimeConfigStore(context: Context) {
    companion object {
        private const val MAX_PLAINTEXT_BYTES = 32 * 1024 * 1024
        private val MAGIC = byteArrayOf('N'.code.toByte(), 'Z'.code.toByte(), 'R'.code.toByte(), 1)
        private val AAD = "dev.nozelt.nozelt:vpn-runtime:v1".toByteArray(Charsets.UTF_8)
    }

    private val store = EncryptedFileStore(
        context = context,
        keyAlias = "nozelt_vpn_runtime_aes_v1",
        fileName = "vpn-runtime.enc",
        magic = MAGIC,
        aad = AAD,
        maxPlaintextBytes = MAX_PLAINTEXT_BYTES,
    )

    fun write(
        core: VpnCore,
        configYaml: String,
        tunOptionsJson: String?,
    ): StoredVpnConfig {
        val stored = StoredVpnConfig(
            requestId = UUID.randomUUID().toString(),
            core = core,
            configYaml = configYaml,
            tunOptionsJson = tunOptionsJson,
        )
        write(stored)
        return stored
    }

    /**
     * Stages a live replacement without changing its shutdown generation id.
     * The exact previous live config is kept encrypted until [markApplied]
     * confirms that the replacement reached a running core.
     *
     * Writing the currently stored fallback is an explicit rollback, so it
     * clears the pending fallback instead of making the failed candidate the
     * next recovery target.
     */
    fun writeActiveReplacement(
        previous: StoredVpnConfig,
        core: VpnCore,
        configYaml: String,
        tunOptionsJson: String?,
        newRollbackJournalId: String? = null,
    ): StoredVpnConfig {
        val replacement = RuntimeConfigTransitions.stage(
            previous,
            core,
            configYaml,
            tunOptionsJson,
            newRollbackJournalId,
        )
        write(replacement)
        return replacement
    }

    /** Clears a pending fallback only when [expected] is still current. */
    fun markApplied(expected: StoredVpnConfig): Boolean {
        val current = read() ?: return false
        if (!RuntimeConfigTransitions.sameCandidate(current, expected)) return false
        if (current.fallbackConfigYaml == null) return true
        write(
            current.copy(
                fallbackConfigYaml = null,
                fallbackCore = null,
                fallbackTunOptionsJson = null,
                fallbackSelectedGroupName = null,
                fallbackSelectedProxyName = null,
            ),
        )
        return true
    }

    /** Clears journal metadata after the separate encrypted record is handled. */
    fun clearRollbackMetadataIfCurrent(expected: StoredVpnConfig): Boolean {
        val current = read() ?: return false
        if (!RuntimeConfigTransitions.sameCandidate(current, expected)) return false
        if (current.rollbackJournalId == null && !current.fallbackRestored) return true
        write(current.copy(rollbackJournalId = null, fallbackRestored = false))
        return true
    }

    /**
     * Restores the encrypted last-known-good config only if the failed
     * candidate is still current. A newer replacement or successful start
     * therefore cannot be overwritten by a stale delayed recovery job.
     */
    fun restoreFallbackIfCurrent(failed: StoredVpnConfig): StoredVpnConfig? {
        val current = read() ?: return null
        val restored = RuntimeConfigTransitions.fallback(current, failed) ?: return null
        write(restored)
        return restored
    }

    /** Restores an exact snapshot after a synchronous dispatch/apply error. */
    fun restoreIfCurrent(
        expected: StoredVpnConfig,
        replacement: StoredVpnConfig,
    ): Boolean {
        val current = read() ?: return false
        if (!RuntimeConfigTransitions.sameCandidate(current, expected)) return false
        write(replacement)
        return true
    }

    /** Restores the exact encrypted generation after a failed live reload. */
    fun write(stored: StoredVpnConfig) {
        val configYaml = stored.configYaml
        require(stored.requestId.isNotBlank()) { "active VPN request id is empty" }
        require(configYaml.isNotBlank()) { "active VPN config is empty" }
        store.write(
            JSONObject()
                .put("requestId", stored.requestId)
                .put("core", stored.core.wireName)
                .put("configYaml", configYaml)
                .put("tunOptionsJson", stored.tunOptionsJson ?: JSONObject.NULL)
                .put("selectedGroupName", stored.selectedGroupName ?: JSONObject.NULL)
                .put("selectedProxyName", stored.selectedProxyName ?: JSONObject.NULL)
                .put(
                    "fallbackCore",
                    stored.fallbackCore?.wireName ?: JSONObject.NULL,
                )
                .put(
                    "fallbackConfigYaml",
                    stored.fallbackConfigYaml ?: JSONObject.NULL,
                )
                .put(
                    "fallbackTunOptionsJson",
                    stored.fallbackTunOptionsJson ?: JSONObject.NULL,
                )
                .put(
                    "fallbackSelectedGroupName",
                    stored.fallbackSelectedGroupName ?: JSONObject.NULL,
                )
                .put(
                    "fallbackSelectedProxyName",
                    stored.fallbackSelectedProxyName ?: JSONObject.NULL,
                )
                .put("rollbackJournalId", stored.rollbackJournalId ?: JSONObject.NULL)
                .put("fallbackRestored", stored.fallbackRestored)
                .toString(),
        )
    }

    /**
     * Returns the same encrypted generation with [proxyName] first in the
     * requested selector. Nozelt's generated selector is deterministic and
     * mihomo chooses its first entry after a cold process/service restart.
     */
    fun withSelectedProxy(
        previous: StoredVpnConfig,
        groupName: String,
        proxyName: String,
    ): StoredVpnConfig = RuntimeConfigTransitions.selectProxy(
        previous,
        groupName,
        proxyName,
    )

    fun read(): StoredVpnConfig? {
        val raw = store.read() ?: return null
        val value = JSONObject(raw)
        val configYaml = value.optString("configYaml")
        require(configYaml.isNotBlank()) { "stored active VPN config is empty" }
        return StoredVpnConfig(
            requestId = value.optString("requestId").ifBlank { "legacy" },
            core = VpnCore.fromWireName(value.optString("core")),
            configYaml = configYaml,
            tunOptionsJson = if (value.isNull("tunOptionsJson")) {
                null
            } else {
                value.optString("tunOptionsJson")
            },
            selectedGroupName = value.nullableString("selectedGroupName"),
            selectedProxyName = value.nullableString("selectedProxyName"),
            fallbackCore = if (value.isNull("fallbackCore")) {
                null
            } else {
                VpnCore.fromWireName(value.optString("fallbackCore"))
            },
            fallbackConfigYaml = if (value.isNull("fallbackConfigYaml")) {
                null
            } else {
                value.optString("fallbackConfigYaml").ifBlank { null }
            },
            fallbackTunOptionsJson = if (value.isNull("fallbackTunOptionsJson")) {
                null
            } else {
                value.optString("fallbackTunOptionsJson")
            },
            fallbackSelectedGroupName = value.nullableString("fallbackSelectedGroupName"),
            fallbackSelectedProxyName = value.nullableString("fallbackSelectedProxyName"),
            rollbackJournalId = if (value.isNull("rollbackJournalId")) {
                null
            } else {
                value.optString("rollbackJournalId").ifBlank { null }
            },
            fallbackRestored = value.optBoolean("fallbackRestored", false),
        )
    }

    fun delete() = store.delete()

    fun deleteIfRequestId(requestId: String): Boolean = store.deleteIf { raw ->
        JSONObject(raw).optString("requestId").ifBlank { "legacy" } == requestId
    }

}

private fun JSONObject.nullableString(name: String): String? =
    if (isNull(name)) null else optString(name).ifBlank { null }
