package dev.nozelt.nozelt

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class RuntimeConfigTransitionsTest {
    private val live = StoredVpnConfig(
        requestId = "request-1",
        configYaml = "old-config",
        tunOptionsJson = "old-tun",
    )

    @Test
    fun stagedReplacementRetainsLastWorkingConfig() {
        val pending = RuntimeConfigTransitions.stage(
            live,
            "new-config",
            "new-tun",
            "journal-1",
        )

        assertEquals("new-config", pending.configYaml)
        assertEquals("new-tun", pending.tunOptionsJson)
        assertEquals("old-config", pending.fallbackConfigYaml)
        assertEquals("old-tun", pending.fallbackTunOptionsJson)
        assertEquals("journal-1", pending.rollbackJournalId)
    }

    @Test
    fun explicitRollbackDoesNotMakeFailedCandidateTheFallback() {
        val pending = RuntimeConfigTransitions.stage(live, "bad-config", "bad-tun")

        val rollback = RuntimeConfigTransitions.stage(
            pending,
            pending.fallbackConfigYaml!!,
            pending.fallbackTunOptionsJson,
        )

        assertEquals(live, rollback)
        assertNull(rollback.fallbackConfigYaml)
        assertNull(rollback.fallbackTunOptionsJson)
    }

    @Test
    fun delayedFallbackCannotOverwriteNewerCandidate() {
        val failed = RuntimeConfigTransitions.stage(live, "bad-config", "bad-tun")
        val newer = RuntimeConfigTransitions.stage(failed, "newer-config", "newer-tun")

        assertNull(RuntimeConfigTransitions.fallback(newer, failed))
    }

    @Test
    fun delayedFallbackRestoresWorkingConfigAndClearsPendingState() {
        val failed = RuntimeConfigTransitions.stage(
            live,
            "bad-config",
            "bad-tun",
            "journal-2",
        )

        val restored = RuntimeConfigTransitions.fallback(failed, failed)!!

        assertEquals("old-config", restored.configYaml)
        assertEquals("old-tun", restored.tunOptionsJson)
        assertEquals("journal-2", restored.rollbackJournalId)
        assertEquals(true, restored.fallbackRestored)
        assertNull(restored.fallbackConfigYaml)
    }

    @Test
    fun coreSwitchFallbackRestoresThePreviousEngine() {
        val failed = RuntimeConfigTransitions.stage(
            live,
            VpnCore.XRAY,
            "xray-config",
            "xray-tun",
        )

        assertEquals(VpnCore.XRAY, failed.core)
        assertEquals(VpnCore.MIHOMO, failed.fallbackCore)

        val restored = RuntimeConfigTransitions.fallback(failed, failed)!!
        assertEquals(VpnCore.MIHOMO, restored.core)
        assertEquals("old-config", restored.configYaml)
    }

    @Test
    fun explicitRollbackPreservesJournalAsRestoredState() {
        val pending = RuntimeConfigTransitions.stage(
            live,
            "bad-config",
            "bad-tun",
            "journal-3",
        )

        val rollback = RuntimeConfigTransitions.stage(
            pending,
            "old-config",
            "old-tun",
        )

        assertEquals("journal-3", rollback.rollbackJournalId)
        assertEquals(true, rollback.fallbackRestored)
        assertNull(rollback.fallbackConfigYaml)
    }

    @Test
    fun selectorPersistenceLeavesRenderedConfigByteForByteUnchanged() {
        val rendered = """{"proxy-groups":[{"name":"PROXY","proxies":["one","two"]}]}"""
        val previous = live.copy(configYaml = rendered)

        val selected = RuntimeConfigTransitions.recordSelectedProxy(
            previous,
            "PROXY",
            "two",
        )

        assertEquals(rendered, selected.configYaml)
        assertEquals("PROXY", selected.selectedGroupName)
        assertEquals("two", selected.selectedProxyName)
    }

    @Test
    fun failedReplacementRestoresSelectorMetadataWithFallback() {
        val selected = live.copy(
            selectedGroupName = "PROXY",
            selectedProxyName = "helsinki",
        )
        val failed = RuntimeConfigTransitions.stage(
            selected,
            "bad-config",
            "bad-tun",
        )

        assertEquals("PROXY", failed.fallbackSelectedGroupName)
        assertEquals("helsinki", failed.fallbackSelectedProxyName)

        val restored = RuntimeConfigTransitions.fallback(failed, failed)!!
        assertEquals("PROXY", restored.selectedGroupName)
        assertEquals("helsinki", restored.selectedProxyName)
    }
}
