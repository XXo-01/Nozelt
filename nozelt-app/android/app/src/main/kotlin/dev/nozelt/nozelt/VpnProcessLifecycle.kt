package dev.nozelt.nozelt

import kotlinx.coroutines.sync.Mutex
import java.util.concurrent.atomic.AtomicLong

/**
 * Process-wide barrier for operations that mutate mihomo's singleton
 * lifecycle or its encrypted active configuration.
 *
 * MainActivity and VpnService are separate Android components, but they share
 * one Go runtime. Keeping this mutex outside either component prevents a live
 * config reload from racing a service stop/restart.
 */
internal object VpnProcessLifecycle {
    val mutex = Mutex()
    val generation = AtomicLong(0)
}
