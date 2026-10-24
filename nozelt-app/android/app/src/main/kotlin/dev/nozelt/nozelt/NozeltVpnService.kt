package dev.nozelt.nozelt

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.ComponentName
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.ApplicationInfo
import android.content.pm.PackageManager
import android.content.pm.ServiceInfo
import android.content.res.Configuration
import android.net.ConnectivityManager
import android.net.LinkProperties
import android.net.Network
import android.net.NetworkCapabilities
import android.net.NetworkRequest
import android.net.VpnService
import android.os.Build
import android.os.ParcelFileDescriptor
import android.os.PowerManager
import android.os.SystemClock
import android.os.UserManager
import dev.nozelt.nozelt.NozeltLog as Log
import androidx.core.content.ContextCompat
import androidx.core.app.NotificationCompat
import binding.SocketProtector
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import org.json.JSONArray
import org.json.JSONObject
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.atomic.AtomicReference
import java.util.Locale

/**
 * Foreground VpnService that owns both the TUN interface and the Go engine
 * lifecycle.
 *
 * ## fd ownership (one owner per duplicated descriptor)
 *
 * We call [VpnService.Builder.establish] to get a [ParcelFileDescriptor] and
 * retain that original as a fail-closed keeper. A duplicated descriptor is
 * detached and handed to Go; mihomo exclusively owns and closes that duplicate.
 * Retaining the original keeps Android's VPN route installed as a black hole
 * while the Go engine is restarting, instead of briefly exposing the physical
 * network. On a successful replacement the new keeper is installed before the
 * old one is closed. The descriptors are distinct, so every fd still has one
 * owner and there is no double-close. See nozelt-core/core/core.go state.tunFd
 * for the Go-owned half of the contract.
 *
 * ## anti-loop and same-UID privacy
 *
 * Every mihomo egress socket is individually excluded from the TUN through
 * [VpnService.protect]. The Nozelt package itself can therefore remain inside
 * the VPN like every other selected app: Flutter HTTP/DNS traffic does not get
 * a blanket clear-network exception, while the engine cannot recurse.
 */
class NozeltVpnService : VpnService() {

    companion object {
        const val ACTION_START = "dev.nozelt.nozelt.action.START"
        const val ACTION_STOP = "dev.nozelt.nozelt.action.STOP"
        const val ACTION_RESTART = "dev.nozelt.nozelt.action.RESTART"

        private const val TAG = "NozeltVpnService"
        private const val NOTIFICATION_ID = 1
        private const val CHANNEL_ID = "vpn"
        private const val RUNTIME_PREFS = "nozelt_vpn_runtime"
        private const val PREF_REQUESTED = "requested"
        private const val PREF_LANGUAGE = "language"
        private const val PREF_NOTIFICATION_FLAG = "notification_flag"
        private const val PREF_NOTIFICATION_SERVER = "notification_server"
        private const val PREF_NOTIFICATION_PING_MS = "notification_ping_ms"
        private const val PREF_NOTIFICATION_PING_MEASURED_AT_MS =
            "notification_ping_measured_at_ms"
        private const val PREF_NOTIFICATION_PING_MAX_AGE_MS =
            "notification_ping_max_age_ms"
        private const val MAX_START_RETRIES = 3
        private const val NETWORK_CHANGE_DEBOUNCE_MS = 350L
        private const val IDLE_RECOVERY_MIN_SLEEP_MS = 2 * 60_000L
        private const val IDLE_RECOVERY_DEBOUNCE_MS = 30_000L
        // Radios can take a moment to wake, so the probe gets a few seconds
        // before a silent server is treated as a stale session.
        private const val IDLE_PROBE_TIMEOUT_MS = 6_000L
        private const val PROCESS_WATCHDOG_INTERVAL_MS = 60_000L
        // A crashed Xray/sing-box child leaves the TUN black-holing traffic,
        // so its exit is checked more often; the check is a cheap pid probe.
        private const val NATIVE_WATCHDOG_INTERVAL_MS = 15_000L
        private const val FAILED_START_REARM_MIN_MS = 60_000L
        private const val FAILED_START_REARM_MAX_MS = 30 * 60_000L
        private const val REPLACEMENT_FALLBACK_DELAY_MS = 20_000L
        private const val MAX_TUN_OPTION_APPS = 4096
        private const val MAX_TUN_OPTION_DNS_SERVERS = 8

        @Volatile
        private var alwaysOnPolicyActive = false
        @Volatile
        private var lockdownPolicyActive = false
        @Volatile
        private var activeInstance: NozeltVpnService? = null

        // Defensive MTU bounds. The IPv6 minimum link MTU is 1280; gvisor on
        // Android is commonly run at 9000. Anything outside this is almost
        // certainly a misconfiguration and would produce a broken tunnel.
        private const val MTU_MIN = 1280
        private const val MTU_MAX = 9000

        /** Lightweight state query that does not initialize the large Go AAR. */
        fun isRequested(context: Context): Boolean =
            context.getSharedPreferences(RUNTIME_PREFS, Context.MODE_PRIVATE)
                .getBoolean(PREF_REQUESTED, false)

        fun isServiceActive(): Boolean = activeInstance != null

        fun setPreferredLanguage(context: Context, code: String?): Boolean {
            val normalized = if (code == "en") "en" else "ru"
            val preferences =
                context.getSharedPreferences(RUNTIME_PREFS, Context.MODE_PRIVATE)
            if (preferences.getString(PREF_LANGUAGE, "ru") == normalized) {
                return true
            }
            val saved = preferences
                .edit()
                .putString(PREF_LANGUAGE, normalized)
                .commit()
            if (saved) activeInstance?.refreshNotification()
            return saved
        }

        /** Stores non-sensitive display metadata used by the foreground notification. */
        fun updateNotificationMetadata(
            context: Context,
            flag: String?,
            serverName: String?,
            pingMs: Int?,
            updatePing: Boolean,
            pingMeasuredAtMs: Long?,
            pingMaxAgeMs: Long?,
        ): Boolean {
            val preferences =
                context.getSharedPreferences(RUNTIME_PREFS, Context.MODE_PRIVATE)
            val editor = preferences.edit()
                .putString(PREF_NOTIFICATION_FLAG, flag?.trim()?.take(8).orEmpty())
                .putString(PREF_NOTIFICATION_SERVER, serverName?.trim()?.take(256).orEmpty())
            if (updatePing) {
                val measuredPing = pingMs?.takeIf { it > 0 }
                val measuredAt = pingMeasuredAtMs?.takeIf { it > 0L }
                if (measuredPing != null && measuredAt != null) {
                    editor
                        .putInt(PREF_NOTIFICATION_PING_MS, measuredPing)
                        .putLong(PREF_NOTIFICATION_PING_MEASURED_AT_MS, measuredAt)
                        .putLong(
                            PREF_NOTIFICATION_PING_MAX_AGE_MS,
                            NotificationPingFreshness.normalizedMaxAge(pingMaxAgeMs),
                        )
                } else {
                    editor
                        .putInt(PREF_NOTIFICATION_PING_MS, -1)
                        .remove(PREF_NOTIFICATION_PING_MEASURED_AT_MS)
                        .remove(PREF_NOTIFICATION_PING_MAX_AGE_MS)
                }
            }
            val saved = editor.commit()
            if (saved) activeInstance?.refreshNotification()
            return saved
        }

        fun requestTileRefresh(context: Context) {
            runCatching {
                android.service.quicksettings.TileService.requestListeningState(
                    context,
                    ComponentName(context, NozeltTileService::class.java),
                )
            }
        }

        /** Cheap Activity-side policy query; does not initialize the Go AAR. */
        fun isAlwaysOnPolicyActive(): Boolean =
            activeInstance?.computeAlwaysOnPolicy() ?: alwaysOnPolicyActive

        fun isLockdownPolicyActive(): Boolean =
            activeInstance?.computeLockdownPolicy() ?: lockdownPolicyActive

        fun isLockdownDetectionSupported(): Boolean =
            Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q
    }

    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    private val lifecycleMutex = VpnProcessLifecycle.mutex
    private val networkRecoveryMutex = Mutex()
    private lateinit var connectivityManager: ConnectivityManager
    private val runtimeConfigStore by lazy { SecureRuntimeConfigStore(applicationContext) }

    @Volatile
    private var desiredRunning = false

    @Volatile
    private var engineRunning = false

    @Volatile
    private var activeRuntimeRequestId: String? = null

    @Volatile
    private var currentUnderlying: Network? = null

    @Volatile
    private var networkRecoveryNeeded = false

    private var networkChangeJob: Job? = null
    private var processWatchdogJob: Job? = null
    private var startRetryJob: Job? = null
    private var replacementFallbackJob: Job? = null
    private var notificationPingExpiryJob: Job? = null
    private var unlockReceiverRegistered = false
    private var idleRecoveryReceiverRegistered = false
    private var screenOffAtElapsed = 0L
    private var underlyingAtScreenOff: Network? = null
    private var linkSignatureAtScreenOff: String? = null
    private var lastIdleRecoveryAtElapsed = 0L

    // Last time the transports were rebuilt (network recovery or a fresh
    // start). A rebuild during sleep makes another one on wake pointless.
    @Volatile
    private var lastTransportRebuildAtElapsed = 0L
    private var lastFailedStartRearmAtElapsed = 0L
    private var failedStartRearmIntervalMs = FAILED_START_REARM_MIN_MS
    private var debugLogger: LoggerImpl? = null
    private var consecutiveStartFailures = 0
    private var systemStartedAlwaysOn = false
    private val physicalNetworks = ConcurrentHashMap.newKeySet<Network>()
    private val networkValidation = ConcurrentHashMap<Network, Boolean>()
    private val networkBlocked = ConcurrentHashMap<Network, Boolean>()
    private val linkSignatures = ConcurrentHashMap<Network, String>()
    private val activeTunKeeper = AtomicReference<ParcelFileDescriptor?>(null)

    private val socketProtector = object : SocketProtector {
        override fun protect(fd: Long): Boolean {
            if (fd < 0L || fd > Int.MAX_VALUE.toLong()) return false
            val socketFd = fd.toInt()
            if (!this@NozeltVpnService.protect(socketFd)) return false

            // protect() removes the socket from the VPN, while Network.bindSocket
            // pins it to the exact Wi-Fi/cellular underlay selected by the
            // callback. Use a duplicate descriptor so Kotlin never takes
            // ownership of Go's socket; SO_MARK/network binding applies to the
            // shared socket itself. If a handover races this call, the socket
            // remains protected and may safely use Android's new default
            // physical route; only a protect() failure is an anti-loop error.
            val underlying = currentUnderlying ?: return true
            return try {
                ParcelFileDescriptor.fromFd(socketFd).use { duplicate ->
                    underlying.bindSocket(duplicate.fileDescriptor)
                }
                true
            } catch (_: Throwable) {
                Log.w(TAG, "could not bind protected socket to physical network")
                true
            }
        }
    }

    private val userUnlockedReceiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context?, intent: Intent?) {
            if (intent?.action != Intent.ACTION_USER_UNLOCKED) return
            val userManager = getSystemService(UserManager::class.java)
            if (!userManager.isUserUnlocked || !desiredRunning || engineRunning) return

            // Android Keystore can be unavailable during an Always-on start
            // before credential storage is unlocked. That is an external
            // state transition, so re-arm the otherwise bounded start retry
            // sequence while the existing system/TUN policy remains closed.
            Log.i(TAG, "user storage unlocked; retrying requested VPN start")
            consecutiveStartFailures = 0
            startRetryJob?.cancel()
            startRetryJob = null
            handleStart()
        }
    }

    private val idleRecoveryReceiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context?, intent: Intent?) {
            when (intent?.action) {
                Intent.ACTION_SCREEN_OFF -> {
                    screenOffAtElapsed = SystemClock.elapsedRealtime()
                    underlyingAtScreenOff = currentUnderlying
                    linkSignatureAtScreenOff = currentUnderlying?.let { linkSignatures[it] }
                }
                Intent.ACTION_SCREEN_ON,
                Intent.ACTION_USER_PRESENT -> scheduleIdleRecovery(intent.action.orEmpty())
                PowerManager.ACTION_DEVICE_IDLE_MODE_CHANGED -> {
                    val power = getSystemService(PowerManager::class.java)
                    // Doze maintenance windows happen with the screen off;
                    // only a real wake should spend the post-sleep check.
                    if (!power.isDeviceIdleMode && power.isInteractive) {
                        scheduleIdleRecovery(intent.action.orEmpty())
                    }
                }
            }
        }
    }

    private val networkCallback = object : ConnectivityManager.NetworkCallback() {
        override fun onAvailable(network: Network) {
            physicalNetworks.add(network)
            networkBlocked.putIfAbsent(network, false)
            scheduleUnderlyingNetwork()
        }

        override fun onBlockedStatusChanged(network: Network, blocked: Boolean) {
            val wasBlocked = networkBlocked.put(network, blocked) == true
            if (currentUnderlying == network) {
                if (blocked) {
                    // A protected proxy socket cannot make progress through a
                    // per-UID blocked underlay. Withdraw it immediately so the
                    // core cannot keep opening HY2/QUIC sessions on a dead path.
                    currentUnderlying = null
                    networkRecoveryNeeded = engineRunning
                    if (engineRunning) {
                        runCatching { setUnderlyingNetworks(emptyArray()) }
                    }
                } else if (wasBlocked && engineRunning) {
                    networkRecoveryNeeded = true
                }
            }
            scheduleUnderlyingNetwork()
        }

        override fun onCapabilitiesChanged(
            network: Network,
            capabilities: NetworkCapabilities,
        ) {
            val validated = capabilities.hasCapability(
                NetworkCapabilities.NET_CAPABILITY_VALIDATED,
            )
            val wasValidated = networkValidation.put(network, validated)
            if (capabilities.hasCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET) &&
                capabilities.hasCapability(NetworkCapabilities.NET_CAPABILITY_NOT_VPN)
            ) {
                physicalNetworks.add(network)
            } else {
                physicalNetworks.remove(network)
                if (currentUnderlying == network) {
                    currentUnderlying = null
                    networkRecoveryNeeded = engineRunning
                    if (engineRunning) {
                        // A capability loss is equivalent to onLost for VPN
                        // routing, but some OEMs report only this callback.
                        runCatching { setUnderlyingNetworks(emptyArray()) }
                    }
                }
            }
            if (engineRunning && currentUnderlying == network &&
                wasValidated != true && validated
            ) {
                // Internet can disappear and return on the same Android
                // Network handle. This also covers the first validated
                // callback after the engine started while Wi-Fi was still
                // captive/unvalidated: existing QUIC/HY2 sockets may already
                // belong to the unusable path and need a transport rebuild.
                networkRecoveryNeeded = true
            }
            scheduleUnderlyingNetwork()
        }

        override fun onLinkPropertiesChanged(
            network: Network,
            linkProperties: LinkProperties,
        ) {
            // Only the interface and its addresses matter. LinkAddress text
            // also carries IPv6 flags and lifetimes that change with every
            // router advertisement, and Nozelt never uses the network's DNS.
            val signature = buildString {
                append(linkProperties.interfaceName.orEmpty())
                append('|')
                append(
                    linkProperties.linkAddresses
                        .map { "${it.address.hostAddress}/${it.prefixLength}" }
                        .sorted()
                        .joinToString(),
                )
            }
            val previous = linkSignatures.put(network, signature)
            if (engineRunning && currentUnderlying == network &&
                previous != null && previous != signature
            ) {
                networkRecoveryNeeded = true
            }
            scheduleUnderlyingNetwork()
        }

        override fun onLost(network: Network) {
            physicalNetworks.remove(network)
            networkValidation.remove(network)
            networkBlocked.remove(network)
            linkSignatures.remove(network)
            if (currentUnderlying != network) return
            currentUnderlying = null
            networkRecoveryNeeded = engineRunning
            if (engineRunning) {
                // Empty means no usable upstream: fail closed until Android
                // announces the replacement Wi-Fi/mobile network.
                runCatching { setUnderlyingNetworks(emptyArray()) }
            }
            Log.i(TAG, "underlying network lost: $network")
            scheduleUnderlyingNetwork()
        }
    }

    override fun onCreate() {
        super.onCreate()
        activeInstance = this
        ensureNotificationChannel()
        if (applicationInfo.flags and ApplicationInfo.FLAG_DEBUGGABLE != 0) {
            debugLogger = LoggerImpl(logcatEnabled = true).also {
                // Debug APKs need core/mihomo logcat before Flutter or a
                // diagnostics EventChannel exists. Release builds install no
                // fallback logger and pay no connection-log overhead.
                EngineBridge.installFallbackLogger(it)
            }
        }
        connectivityManager = getSystemService(ConnectivityManager::class.java)
        desiredRunning = isRequested(this)
        runCatching {
            val idleFilter = IntentFilter().apply {
                addAction(Intent.ACTION_SCREEN_OFF)
                addAction(Intent.ACTION_SCREEN_ON)
                addAction(Intent.ACTION_USER_PRESENT)
                addAction(PowerManager.ACTION_DEVICE_IDLE_MODE_CHANGED)
            }
            ContextCompat.registerReceiver(
                this,
                idleRecoveryReceiver,
                idleFilter,
                ContextCompat.RECEIVER_NOT_EXPORTED,
            )
            idleRecoveryReceiverRegistered = true
        }.onFailure {
            Log.w(TAG, "could not register idle recovery receiver")
        }
        processWatchdogJob = scope.launch {
            while (true) {
                delay(
                    if (EngineBridge.currentCore == VpnCore.MIHOMO) {
                        PROCESS_WATCHDOG_INTERVAL_MS
                    } else {
                        NATIVE_WATCHDOG_INTERVAL_MS
                    },
                )
                val shouldRestart = lifecycleMutex.withLock {
                    desiredRunning && engineRunning && !EngineBridge.isEngineProcessRunning()
                }
                if (shouldRestart) {
                    Log.e(TAG, "VPN core process exited unexpectedly")
                    forceRestart("core process watchdog")
                }
            }
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N &&
            !getSystemService(UserManager::class.java).isUserUnlocked
        ) {
            runCatching {
                ContextCompat.registerReceiver(
                    this,
                    userUnlockedReceiver,
                    IntentFilter(Intent.ACTION_USER_UNLOCKED),
                    ContextCompat.RECEIVER_NOT_EXPORTED,
                )
                unlockReceiverRegistered = true
            }.onFailure {
                Log.w(TAG, "could not register user-unlocked recovery")
            }
        }
        try {
            connectivityManager.activeNetwork?.takeIf(::isUsablePhysical)?.let { network ->
                physicalNetworks.add(network)
                currentUnderlying = network
            }
            val request = NetworkRequest.Builder()
                .addCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET)
                .addCapability(NetworkCapabilities.NET_CAPABILITY_NOT_VPN)
                .build()
            // A default-network callback may switch to observing the VPN
            // itself once it is established. An explicit NOT_VPN request keeps
            // reporting the real Wi-Fi/mobile underlays instead.
            connectivityManager.registerNetworkCallback(request, networkCallback)
        } catch (_: Throwable) {
            Log.w(TAG, "could not register default-network callback")
        }
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            ACTION_START -> {
                desiredRunning = true
                setRequested(true)
                consecutiveStartFailures = 0
                handleStart()
            }
            ACTION_STOP -> {
                refreshAlwaysOnPolicy()
                if (alwaysOnPolicyActive) {
                    // Android owns the lifecycle in Always-on mode. Removing
                    // our runtime record here would make the system's
                    // immediate restart impossible and break lockdown.
                    Log.i(TAG, "disconnect ignored while Always-on VPN is active")
                    desiredRunning = true
                    setRequested(true)
                    if (engineRunning) enterForeground() else handleStart()
                } else {
                    desiredRunning = false
                    setRequested(false)
                    shutdown()
                }
            }
            ACTION_RESTART -> {
                desiredRunning = true
                setRequested(true)
                forceRestart("host requested recovery")
            }
            SERVICE_INTERFACE -> {
                // Always-on/managed VPN starts are unflagged system service
                // launches. The encrypted runtime generation is the latest
                // durable configuration and contains no Intent secrets.
                systemStartedAlwaysOn = true
                refreshAlwaysOnPolicy()
                desiredRunning = true
                setRequested(true)
                consecutiveStartFailures = 0
                handleStart()
            }
            null -> {
                // START_STICKY restart after an OEM/low-memory kill. The
                // credential-bearing config is recovered from Keystore-backed
                // storage instead of an Intent extra.
                if (desiredRunning) {
                    handleStart()
                } else {
                    stopSelf(startId)
                }
            }
            else -> Log.w(TAG, "unknown action: ${intent?.action}")
        }
        return if (desiredRunning) START_STICKY else START_NOT_STICKY
    }

    private fun handleStart() {
        // Enter foreground synchronously so we satisfy the startForegroundService
        // deadline before doing any slower work.
        enterForeground()

        scope.launch {
            lifecycleMutex.withLock {
                if (!desiredRunning) return@withLock

                // Read the encrypted generation only after acquiring the
                // lifecycle lock. A handler can wait here while an older
                // session drains; using a config captured before that wait
                // could start stale credentials and then coalesce the newer
                // START intent behind the wrong running engine.
                val storedConfig = try {
                    runtimeConfigStore.read()
                } catch (_: Throwable) {
                    // A transient Keystore failure must not tear down a live,
                    // working VPN merely because Android redelivered START.
                    if (engineRunning) {
                        Log.w(TAG, "could not verify duplicate VPN start; keeping live engine")
                        return@withLock
                    }
                    Log.e(TAG, "could not decrypt active VPN config")
                    failStart()
                    return@withLock
                }
                if (storedConfig == null) {
                    if (engineRunning) {
                        Log.w(TAG, "duplicate VPN start has no stored generation; keeping live engine")
                        return@withLock
                    }
                    Log.e(TAG, "active VPN config is missing; refusing to start")
                    failStart()
                    return@withLock
                }

                if (engineRunning) {
                    if (activeRuntimeRequestId == storedConfig.requestId) {
                        // Android may redeliver the same START during Activity
                        // recreation. Only the exact active generation is a
                        // duplicate; comparing engineRunning alone is unsafe
                        // because EngineBridge.start writes a fresh encrypted
                        // generation before dispatching its Intent.
                        Log.i(TAG, "active VPN generation already running; START coalesced")
                        return@withLock
                    }

                    // A genuinely newer generation arrived while Flutter's
                    // cached state still looked disconnected. Drain the old
                    // process-global mihomo session under the lifecycle lock,
                    // retain the Android-owned TUN keeper as a fail-closed
                    // route, then continue below with a fresh interface and
                    // the new encrypted credentials.
                    Log.i(TAG, "new VPN generation received; replacing live engine")
                    try {
                        EngineBridge.stopEngineForRestartSync()
                    } catch (_: Throwable) {
                        // Binding.Stop only reports an error when the core is
                        // already stopped. Continuing is therefore the safe
                        // recovery path and avoids stranding the new request.
                        Log.w(TAG, "old engine was already stopped during generation replacement")
                    } finally {
                        engineRunning = false
                        activeRuntimeRequestId = null
                        networkRecoveryNeeded = false
                        runCatching { EngineBridge.detachSocketProtector() }
                    }
                }

                val options = TunOptions.fromJson(storedConfig.tunOptionsJson)

                // 1. Establish the TUN interface.
                val pfd = try {
                    establishTun(options, storedConfig.core)
                } catch (_: Throwable) {
                    Log.e(TAG, "VpnService.Builder.establish threw")
                    failStart(storedConfig)
                    return@withLock
                }
                if (pfd == null) {
                    // Null means permission was revoked or another VPN is active.
                    Log.e(TAG, "establish() returned null — VPN revoked or another VPN active")
                    failStart(storedConfig)
                    return@withLock
                }

                // 2. Give Go a duplicate while the service retains the
                // original descriptor. If Go stops unexpectedly, Android's
                // route remains installed and fails closed until recovery.
                val fd = try {
                    ParcelFileDescriptor.dup(pfd.fileDescriptor).detachFd()
                } catch (_: Throwable) {
                    Log.e(TAG, "could not duplicate TUN fd")
                    if (shouldPreserveFailedTun(hasEstablishedTun = true)) {
                        replaceTunKeeper(pfd)
                        preserveFailedStart(storedConfig)
                    } else {
                        runCatching { pfd.close() }
                        failStart(storedConfig)
                    }
                    return@withLock
                }
                Log.i(TAG, "TUN established fd=$fd mtu=${options.mtu} split=${options.splitMode}")

                // 3. Install protection before the embedded core or its
                // compatibility prober can dial. Xray/sing-box receive the fd
                // later through their process boundary; only Mihomo receives
                // it through setTunFd here.
                run {
                    try {
                        EngineBridge.installSocketProtector(socketProtector)
                        if (storedConfig.core == VpnCore.MIHOMO) {
                            EngineBridge.setTunFd(fd)
                        }
                    } catch (_: Throwable) {
                    // Go never took the fd — close it ourselves to avoid a leak.
                        Log.e(TAG, "socket protection/TUN handoff failed; closing orphan fd=$fd")
                        runCatching { EngineBridge.detachSocketProtector() }
                        closeRawFd(fd)
                        if (shouldPreserveFailedTun(hasEstablishedTun = true)) {
                            replaceTunKeeper(pfd)
                            preserveFailedStart(storedConfig)
                        } else {
                            runCatching { pfd.close() }
                            failStart(storedConfig)
                        }
                        return@withLock
                    }
                }

                // 4. Start the engine. On failure Go has already released the fd
                //    (see nozelt-core Start error paths) — we must not touch it.
                try {
                    EngineBridge.startEngineSync(
                        this@NozeltVpnService,
                        storedConfig.core,
                        storedConfig.configYaml,
                        storedConfig.selectedGroupName,
                        storedConfig.selectedProxyName,
                        fd,
                    )
                    engineRunning = true
                    lastTransportRebuildAtElapsed = SystemClock.elapsedRealtime()
                    activeRuntimeRequestId = storedConfig.requestId
                    replaceTunKeeper(pfd)
                    consecutiveStartFailures = 0
                    failedStartRearmIntervalMs = FAILED_START_REARM_MIN_MS
                    startRetryJob?.cancel()
                    startRetryJob = null
                    replacementFallbackJob?.cancel()
                    replacementFallbackJob = null
                    val appliedConfirmed = runCatching {
                        EngineBridge.confirmRuntimeConfigApplied(
                            this@NozeltVpnService,
                            storedConfig,
                        )
                    }.getOrDefault(false)
                    if (!appliedConfirmed) {
                        // The running core remains authoritative. Keeping the
                        // encrypted fallback is safe and the next sticky start
                        // gets another chance to confirm it.
                        Log.w(TAG, "could not confirm applied runtime config")
                    }
                    VpnProcessLifecycle.generation.incrementAndGet()
                    currentUnderlying?.let { setUnderlyingNetworks(arrayOf(it)) }
                    refreshNotification()
                    Log.i(TAG, "engine start ok (TUN active)")
                } catch (failure: Throwable) {
                    Log.e(
                        TAG,
                        "engine start failed (Go released the fd; " +
                            "reason=${classifyEngineStartFailure(failure)})",
                    )
                    if (shouldPreserveFailedTun(hasEstablishedTun = true)) {
                        // Establishing this interface may already have
                        // superseded the previous Android VPN. Keep the new
                        // original descriptor open as a black hole; closing
                        // both descriptors here could expose the underlay.
                        replaceTunKeeper(pfd)
                        preserveFailedStart(storedConfig)
                    } else {
                        runCatching { pfd.close() }
                        failStart(storedConfig)
                    }
                }
            }
        }
    }

    /**
     * Builds and establishes the TUN interface from [options]. Returns null
     * if [VpnService.Builder.establish] returns null (revoked / superseded).
     */
    private fun establishTun(options: TunOptions, core: VpnCore): ParcelFileDescriptor? {
        val mtu = options.mtu.coerceIn(MTU_MIN, MTU_MAX)
        if (mtu != options.mtu) {
            Log.w(TAG, "MTU ${options.mtu} out of [$MTU_MIN,$MTU_MAX]; clamped to $mtu")
        }

        val builder = Builder()
            .setSession(options.session)
            .setMtu(mtu)
            .addAddress(options.ipv4Address, options.ipv4Prefix)
            // Route all IPv4 into the TUN; per-app filtering is done below.
            .addRoute("0.0.0.0", 0)

        if (options.ipv6Enabled) {
            builder.addAddress(options.ipv6Address, options.ipv6Prefix)
            builder.addRoute("::", 0)
        }
        // When IPv6 is disabled we intentionally do not call allowFamily().
        // Android then blocks that address family instead of leaking it through
        // the physical network. When enabled, the default route above tunnels it.

        currentUnderlying?.let { builder.setUnderlyingNetworks(arrayOf(it)) }

        // DNS servers must route into the TUN so mihomo's dns-hijack can grab
        // them (see default_config.dart for the fake-ip contract).
        for (dns in options.dnsServers) {
            builder.addDnsServer(dns)
        }

        applySplitTunneling(builder, options, core)

        // Tapping the system VPN indicator opens the app.
        builder.setConfigureIntent(openAppPendingIntent())

        // Android 10+ treats a VPN as metered unless told otherwise, so apps
        // would postpone Wi-Fi-only downloads and backups. With false, the
        // meteredness follows the underlying Wi-Fi or mobile network.
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            builder.setMetered(false)
        }

        return builder.establish()
    }

    /** Applies per-app split tunneling. Egress anti-loop is per-socket. */
    private fun applySplitTunneling(builder: Builder, options: TunOptions, core: VpnCore) {
        val self = applicationContext.packageName
        val nativeCore = core != VpnCore.MIHOMO
        when (options.splitMode) {
            "allowed" -> {
                val allowed = options.apps.filter { it != self }
                if (allowed.isEmpty()) {
                    // A connected-looking VPN that protects zero apps is both
                    // misleading and unsafe. Treat an empty allow-list as the
                    // normal all-apps mode until the user selects at least one
                    // package.
                    Log.w(TAG, "allowed mode has no apps; tunneling all apps instead")
                    if (nativeCore) builder.addDisallowedApplication(self)
                } else {
                    // Add selected apps first. If every stored package was
                    // uninstalled, every call fails without changing Builder
                    // and its default remains "all apps". Adding Nozelt first
                    // would instead create a dangerous self-only VPN and let
                    // every other app use the clear underlay.
                    val accepted = allowed.count { addAllowedAppSafe(builder, it) }
                    if (accepted == 0) {
                        Log.w(TAG, "allowed mode contains only stale apps; tunneling all apps")
                        if (nativeCore) builder.addDisallowedApplication(self)
                    } else {
                        // The app UI/subscription client shares a UID with the
                        // Go core. Include it; only core transport fds are
                        // protected. This package must exist; an unexpected
                        // failure aborts establish instead of weakening policy.
                        if (!nativeCore) builder.addAllowedApplication(self)
                    }
                }
            }
            "disallowed" -> {
                val exclude = LinkedHashSet(options.apps).apply {
                    remove(self)
                    if (nativeCore) add(self)
                }
                for (pkg in exclude) addDisallowedAppSafe(builder, pkg)
            }
            else -> {
                // "off": the Builder default tunnels every application.
                if (nativeCore) addDisallowedAppSafe(builder, self)
            }
        }
    }

    private fun addAllowedAppSafe(builder: Builder, pkg: String): Boolean {
        return try {
            builder.addAllowedApplication(pkg)
            true
        } catch (_: PackageManager.NameNotFoundException) {
            Log.w(TAG, "allowed app not found; skipping stale selection")
            false
        }
    }

    private fun addDisallowedAppSafe(builder: Builder, pkg: String) {
        try {
            builder.addDisallowedApplication(pkg)
        } catch (_: PackageManager.NameNotFoundException) {
            Log.w(TAG, "disallowed app not found; skipping stale selection")
        }
    }

    private fun shutdown() {
        startRetryJob?.cancel()
        startRetryJob = null
        replacementFallbackJob?.cancel()
        replacementFallbackJob = null
        scope.launch {
            lifecycleMutex.withLock {
                try {
                    // Call even after a failed technical restart: Go may be
                    // idle while still retaining the short-lived FakeDNS
                    // mapper, and a final STOP must erase it.
                    EngineBridge.stopEngineSync()
                    Log.i(TAG, "engine stop ok")
                } catch (_: Throwable) {
                    Log.w(TAG, "engine stop failed")
                } finally {
                    engineRunning = false
                    activeRuntimeRequestId = null
                    networkRecoveryNeeded = false
                    runCatching { EngineBridge.detachSocketProtector() }
                    if (!desiredRunning) {
                        closeTunKeeper()
                        // Checked under the lock: a START that arrived and was
                        // cancelled while this stop waited may have written a
                        // newer generation, and no VPN wants it any more.
                        runCatching { runtimeConfigStore.delete() }
                    }
                }
            }
            if (desiredRunning) {
                // A new START arrived while the old engine was draining. Its
                // encrypted generation was not deleted; coalescing another
                // start is safe if the first handler is already waiting.
                handleStart()
            } else {
                stopForeground(STOP_FOREGROUND_REMOVE)
                stopSelf()
            }
        }
    }

    private fun scheduleUnderlyingNetwork() {
        networkChangeJob?.cancel()
        networkChangeJob = scope.launch {
            // Network callbacks are noisy while Wi-Fi validates. Debouncing
            // avoids repeatedly rebuilding QUIC transports for one handover.
            delay(NETWORK_CHANGE_DEBOUNCE_MS)
            val network = selectPreferredPhysicalNetwork() ?: return@launch

            var shouldRecover = false
            var shouldRestartFailedCore = false
            lifecycleMutex.withLock {
                val previous = currentUnderlying
                // null -> physical is a real transition too (for example the
                // user started offline and mobile data appeared later). HY2/
                // QUIC pools created while offline must be rebuilt in exactly
                // the same way as Wi-Fi -> cellular handover.
                val changed = networkRecoveryNeeded || previous != network
                currentUnderlying = network
                networkRecoveryNeeded = false

                if (!engineRunning) {
                    // Fast start retries are deliberately bounded. If they
                    // were exhausted while the device was offline/captive,
                    // the next *validated* underlay is a meaningful external
                    // state change and may safely re-arm one retry sequence.
                    // The retained TUN keeper remains fail closed throughout.
                    // Only a real change re-arms it: periodic capability
                    // updates of the same network must not loop a start that
                    // keeps failing for another reason.
                    val now = SystemClock.elapsedRealtime()
                    shouldRestartFailedCore = desiredRunning &&
                        consecutiveStartFailures > MAX_START_RETRIES &&
                        isValidated(network) &&
                        changed &&
                        now - lastFailedStartRearmAtElapsed >= failedStartRearmIntervalMs
                    if (shouldRestartFailedCore) {
                        lastFailedStartRearmAtElapsed = now
                        failedStartRearmIntervalMs = (failedStartRearmIntervalMs * 2)
                            .coerceAtMost(FAILED_START_REARM_MAX_MS)
                    }
                    if (shouldRestartFailedCore) {
                        consecutiveStartFailures = 0
                        startRetryJob?.cancel()
                        startRetryJob = null
                    }
                    return@withLock
                }
                val advertised = runCatching {
                    setUnderlyingNetworks(arrayOf(network))
                }.getOrDefault(false)
                Log.i(
                    TAG,
                    "underlying network=${network} changed=$changed advertised=$advertised",
                )
                shouldRecover = changed
            }
            if (shouldRestartFailedCore) {
                Log.i(TAG, "validated network available; retrying failed VPN start")
                handleStart()
            } else if (shouldRecover) {
                // networkChangeJob is only the debounce owner and is cancelled
                // by every later ConnectivityManager callback. Run recovery as
                // a sibling service job so a harmless duplicate callback
                // cannot cancel its retry loop after one failed native apply.
                // networkRecoveryMutex still serializes real overlapping
                // handovers/link revisions.
                scope.launch { recoverAfterNetworkChange() }
            }
        }
    }

    private fun scheduleIdleRecovery(reason: String) {
        val now = SystemClock.elapsedRealtime()
        val sleptFor = if (screenOffAtElapsed > 0L) now - screenOffAtElapsed else 0L
        if (sleptFor < IDLE_RECOVERY_MIN_SLEEP_MS ||
            now - lastIdleRecoveryAtElapsed < IDLE_RECOVERY_DEBOUNCE_MS
        ) {
            return
        }
        if (!desiredRunning || !engineRunning) return
        val network = selectPreferredPhysicalNetwork() ?: return
        val sleepStartedAt = screenOffAtElapsed
        val networkBefore = underlyingAtScreenOff
        val signatureBefore = linkSignatureAtScreenOff
        screenOffAtElapsed = 0L
        underlyingAtScreenOff = null
        linkSignatureAtScreenOff = null
        lastIdleRecoveryAtElapsed = now
        scope.launch {
            checkSessionAfterIdle(
                reason = reason,
                sleptFor = sleptFor,
                sleepStartedAt = sleepStartedAt,
                network = network,
                networkBefore = networkBefore,
                signatureBefore = signatureBefore,
            )
        }
    }

    /**
     * Rebuilds the session after sleep only when it is actually stale: the
     * physical network changed, or the server does not answer a quick request
     * through the existing transports. Otherwise music, downloads and calls
     * that ran with the screen off keep their connections.
     */
    private suspend fun checkSessionAfterIdle(
        reason: String,
        sleptFor: Long,
        sleepStartedAt: Long,
        network: Network,
        networkBefore: Network?,
        signatureBefore: String?,
    ) {
        if (lastTransportRebuildAtElapsed >= sleepStartedAt) {
            Log.i(TAG, "session already rebuilt during sleep; keeping it ($reason)")
            return
        }
        val networkChanged = networkBefore == null ||
            networkBefore != network ||
            signatureBefore != linkSignatures[network]
        if (networkChanged) {
            Log.i(TAG, "network changed during sleep; rebuilding ($reason, slept=${sleptFor}ms)")
            recoverAfterNetworkChange()
            return
        }

        val generation = lifecycleMutex.withLock {
            if (!desiredRunning || !engineRunning) return
            if (!EngineBridge.supportsInPlaceNetworkRecovery()) {
                // Xray/sing-box open a new outbound for every flow, and the
                // watchdog already restarts a dead process.
                Log.i(TAG, "native core alive after sleep; keeping session ($reason)")
                return
            }
            VpnProcessLifecycle.generation.get()
        }
        // The probe runs outside the lifecycle lock; Stop/Recover cancel it.
        val healthy = runCatching {
            EngineBridge.probeLiveConnectionSync(IDLE_PROBE_TIMEOUT_MS)
        }.isSuccess
        if (healthy) {
            Log.i(TAG, "server answered after sleep; keeping session (slept=${sleptFor}ms)")
            return
        }
        if (VpnProcessLifecycle.generation.get() != generation ||
            lastTransportRebuildAtElapsed >= sleepStartedAt
        ) {
            return
        }
        Log.i(TAG, "server silent after sleep; rebuilding ($reason, slept=${sleptFor}ms)")
        recoverAfterNetworkChange()
    }

    private fun selectPreferredPhysicalNetwork(): Network? {
        connectivityManager.activeNetwork
            ?.takeIf(::isUsablePhysical)
            ?.takeIf(::isValidated)
            ?.let { return it }

        val candidates = physicalNetworks.filter(::isUsablePhysical)
        return candidates.maxByOrNull { network ->
            val capabilities = connectivityManager.getNetworkCapabilities(network)
            var score = 0
            if (capabilities?.hasCapability(NetworkCapabilities.NET_CAPABILITY_VALIDATED) == true) {
                score += 100
            }
            if (capabilities?.hasTransport(NetworkCapabilities.TRANSPORT_WIFI) == true) {
                score += 20
            } else if (capabilities?.hasTransport(NetworkCapabilities.TRANSPORT_CELLULAR) == true) {
                score += 10
            }
            score
        }
    }

    private fun isValidated(network: Network): Boolean =
        connectivityManager.getNetworkCapabilities(network)
            ?.hasCapability(NetworkCapabilities.NET_CAPABILITY_VALIDATED) == true

    private fun isUsablePhysical(network: Network): Boolean {
        if (networkBlocked[network] == true) return false
        val capabilities = connectivityManager.getNetworkCapabilities(network) ?: return false
        return capabilities.hasCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET) &&
            capabilities.hasCapability(NetworkCapabilities.NET_CAPABILITY_NOT_VPN)
    }

    private suspend fun recoverAfterNetworkChange() {
        networkRecoveryMutex.withLock {
            val supportsInPlaceRecovery = lifecycleMutex.withLock {
                if (!desiredRunning || !engineRunning) return
                EngineBridge.supportsInPlaceNetworkRecovery()
            }
            if (!supportsInPlaceRecovery) {
                Log.i(TAG, "native core network handover; restarting immediately")
                forceRestart("native core network handover")
                return
            }

            repeat(3) { attempt ->
                val recovered = lifecycleMutex.withLock {
                    if (!desiredRunning || !engineRunning) return
                    runCatching { EngineBridge.recoverNetworkSync() }.isSuccess
                }
                if (recovered) {
                    lastTransportRebuildAtElapsed = SystemClock.elapsedRealtime()
                    Log.i(TAG, "network handover recovery complete (attempt=${attempt + 1})")
                    return
                }
                Log.w(TAG, "network handover recovery failed (attempt=${attempt + 1})")
                delay(700L * (attempt + 1))
            }
            if (desiredRunning && engineRunning) {
                Log.e(TAG, "network handover recovery exhausted retries")
                forceRestart("network handover recovery exhausted")
            }
        }
    }

    /** Stops the old TUN/core and starts a fresh session from encrypted state. */
    private fun forceRestart(reason: String) {
        // ACTION_RESTART can create a stopped service, so satisfy the Android
        // foreground deadline before any Go shutdown work.
        enterForeground()
        startRetryJob?.cancel()
        startRetryJob = null
        consecutiveStartFailures = 0
        scope.launch {
            var shouldStart = false
            lifecycleMutex.withLock {
                if (!desiredRunning) return@withLock
                Log.w(TAG, "full VPN restart: $reason")
                try {
                    if (engineRunning) EngineBridge.stopEngineForRestartSync()
                } catch (_: Throwable) {
                    Log.w(TAG, "engine stop during full restart failed")
                } finally {
                    engineRunning = false
                    activeRuntimeRequestId = null
                    networkRecoveryNeeded = false
                    runCatching { EngineBridge.detachSocketProtector() }
                }
                shouldStart = desiredRunning
            }
            if (shouldStart) handleStart()
        }
    }

    private fun failStart(storedConfig: StoredVpnConfig? = null) {
        val requestId = storedConfig?.requestId
        if (requestId != null) {
            val isLatest = runCatching {
                runtimeConfigStore.read()?.requestId == requestId
            }.getOrDefault(true)
            if (!isLatest) {
                Log.i(TAG, "stale VPN start failed; keeping newer runtime config")
                return
            }
        }
        if (shouldPreserveFailedTun()) {
            preserveFailedStart(storedConfig)
            return
        }
        desiredRunning = false
        consecutiveStartFailures = 0
        startRetryJob?.cancel()
        startRetryJob = null
        engineRunning = false
        activeRuntimeRequestId = null
        runCatching { EngineBridge.detachSocketProtector() }
        closeTunKeeper()
        runCatching {
            if (requestId == null) {
                runtimeConfigStore.delete()
            } else {
                runtimeConfigStore.deleteIfRequestId(requestId)
            }
        }
        setRequested(false)
        stopForeground(STOP_FOREGROUND_REMOVE)
        stopSelf()
    }

    /**
     * Keeps Android's VPN route installed after a replacement failure. The
     * encrypted generation remains durable and a few bounded retries cover
     * transient native/underlay failures without creating a permanent loop.
     * After retries are exhausted the tunnel remains a deliberate black hole;
     * the UI reports the stopped core and the user can retry or disable VPN.
     */
    private fun preserveFailedStart(storedConfig: StoredVpnConfig?) {
        val requestId = storedConfig?.requestId
        engineRunning = false
        if (requestId != null) activeRuntimeRequestId = requestId
        desiredRunning = true
        setRequested(true)
        runCatching { EngineBridge.detachSocketProtector() }
        enterForeground()

        consecutiveStartFailures++
        if (consecutiveStartFailures > MAX_START_RETRIES) {
            scheduleReplacementFallback(storedConfig)
            return
        }
        val retryDelay = 1_000L * consecutiveStartFailures
        startRetryJob?.cancel()
        startRetryJob = scope.launch {
            delay(retryDelay)
            if (desiredRunning && !engineRunning) handleStart()
        }
    }

    /**
     * Last-resort rollback for a failed live replacement when Flutter is no
     * longer alive to run its owning settings/profile transaction. The delay
     * is intentionally longer than EngineBridge.restartWithConfig's wait, so
     * a live Dart caller gets the first opportunity to perform its exact
     * durable-state rollback. The candidate comparison prevents stale jobs
     * from overwriting a newer generation.
     */
    private fun scheduleReplacementFallback(failed: StoredVpnConfig?) {
        if (failed?.fallbackConfigYaml == null) return
        replacementFallbackJob?.cancel()
        replacementFallbackJob = scope.launch {
            delay(REPLACEMENT_FALLBACK_DELAY_MS)
            var shouldRetry = false
            lifecycleMutex.withLock {
                if (!desiredRunning || engineRunning) return@withLock
                val restored = runCatching {
                    runtimeConfigStore.restoreFallbackIfCurrent(failed)
                }.getOrNull() ?: return@withLock
                activeRuntimeRequestId = restored.requestId
                consecutiveStartFailures = 0
                startRetryJob?.cancel()
                startRetryJob = null
                shouldRetry = true
                Log.w(TAG, "failed replacement rolled back to last working config")
            }
            if (shouldRetry) handleStart()
        }
    }

    private fun shouldPreserveFailedTun(hasEstablishedTun: Boolean = false): Boolean =
        desiredRunning &&
            (hasEstablishedTun ||
                activeTunKeeper.get() != null ||
                computeAlwaysOnPolicy() ||
                computeLockdownPolicy())

    private fun setRequested(value: Boolean) {
        // This tiny flag is the START_STICKY/Activity restoration authority.
        // commit() is intentional: with apply(), an OEM kill immediately
        // after onStartCommand could lose the requested state and strand an
        // encrypted active config until the user opens Nozelt again.
        val saved = getSharedPreferences(RUNTIME_PREFS, Context.MODE_PRIVATE)
            .edit()
            .putBoolean(PREF_REQUESTED, value)
            .commit()
        if (!saved) {
            Log.e(TAG, "could not persist requested VPN state")
        }
        requestTileRefresh(this)
    }

    override fun onDestroy() {
        Log.i(TAG, "onDestroy")
        networkChangeJob?.cancel()
        processWatchdogJob?.cancel()
        startRetryJob?.cancel()
        replacementFallbackJob?.cancel()
        notificationPingExpiryJob?.cancel()
        runCatching { connectivityManager.unregisterNetworkCallback(networkCallback) }
        if (unlockReceiverRegistered) {
            runCatching { unregisterReceiver(userUnlockedReceiver) }
            unlockReceiverRegistered = false
        }
        if (idleRecoveryReceiverRegistered) {
            runCatching { unregisterReceiver(idleRecoveryReceiver) }
            idleRecoveryReceiverRegistered = false
        }
        scope.cancel()

        // An explicit STOP already drained the engine. If Android destroys the
        // service unexpectedly, use a bounded daemon cleanup so onDestroy does
        // not block the main thread long enough to cause an ANR.
        if (engineRunning) {
            val cleanupGeneration = VpnProcessLifecycle.generation.get()
            val cleanup = Thread({
                runBlocking {
                    lifecycleMutex.withLock {
                        // A replacement service instance may have completed a
                        // newer session while this daemon was waiting. Never
                        // let stale onDestroy cleanup stop that process-global
                        // mihomo instance or detach its socket protector.
                        if (VpnProcessLifecycle.generation.get() != cleanupGeneration) {
                            Log.i(TAG, "skipping stale service cleanup after newer VPN start")
                            return@withLock
                        }
                        try {
                            runCatching { EngineBridge.stopEngineSync() }
                            engineRunning = false
                        } finally {
                            runCatching { EngineBridge.detachSocketProtector() }
                        }
                    }
                }
            }, "nozelt-vpn-cleanup").apply { isDaemon = true }
            cleanup.start()
            runCatching { cleanup.join(2_000) }
        }
        closeTunKeeper()
        alwaysOnPolicyActive = false
        lockdownPolicyActive = false
        if (activeInstance === this) activeInstance = null
        debugLogger?.let { EngineBridge.detachFallbackLogger(it) }
        debugLogger = null
        super.onDestroy()
    }

    override fun onRevoke() {
        // System revoked our VPN (user toggled it off, or another VPN took
        // over). Tear the engine down cleanly; Go closes the fd.
        Log.i(TAG, "VPN permission revoked by system")
        systemStartedAlwaysOn = false
        alwaysOnPolicyActive = false
        lockdownPolicyActive = false
        desiredRunning = false
        setRequested(false)
        shutdown()
        super.onRevoke()
    }

    /** Closes a raw fd we still own (only on the setTunFd-threw path). */
    private fun closeRawFd(fd: Int) {
        try {
            ParcelFileDescriptor.adoptFd(fd).close()
        } catch (_: Throwable) {
            Log.w(TAG, "closeRawFd($fd) failed")
        }
    }

    /** Installs a new fail-closed TUN keeper, then releases the previous one. */
    private fun replaceTunKeeper(replacement: ParcelFileDescriptor) {
        val previous = activeTunKeeper.getAndSet(replacement)
        if (previous !== replacement) runCatching { previous?.close() }
    }

    /** Releases the Android-owned descriptor; Go owns a separate duplicate. */
    private fun closeTunKeeper() {
        runCatching { activeTunKeeper.getAndSet(null)?.close() }
    }

    private fun openAppPendingIntent(): PendingIntent {
        val openAppIntent = Intent(this, MainActivity::class.java).apply {
            flags = Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP
        }
        return PendingIntent.getActivity(
            this,
            0,
            openAppIntent,
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
        )
    }

    private fun disconnectPendingIntent(): PendingIntent {
        val stopIntent = Intent(this, NozeltVpnService::class.java).apply {
            action = ACTION_STOP
        }
        return PendingIntent.getService(
            this,
            1,
            stopIntent,
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
        )
    }

    private fun enterForeground() {
        refreshAlwaysOnPolicy()
        val notification = buildNotification()
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
            startForeground(
                NOTIFICATION_ID,
                notification,
                ServiceInfo.FOREGROUND_SERVICE_TYPE_SPECIAL_USE,
            )
        } else {
            startForeground(NOTIFICATION_ID, notification)
        }
        scheduleNotificationPingExpiry()
    }

    private fun ensureNotificationChannel() {
        // NotificationChannel was introduced in API 26 (Oreo). On API 24-25
        // the system has no channel concept, but NotificationCompat.Builder
        // still works with CHANNEL_ID as a no-op string — so we only need
        // to skip the creation call itself.
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return

        val manager = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        val channel = NotificationChannel(
            CHANNEL_ID,
            localizedString(R.string.vpn_channel_name),
            NotificationManager.IMPORTANCE_LOW,
        ).apply {
            description = localizedString(R.string.vpn_channel_description)
            setShowBadge(false)
        }
        manager.createNotificationChannel(channel)
    }

    private fun buildNotification(): Notification {
        // NotificationCompat.Builder works across the entire minSdk = 24
        // range. On API < 26 the channel id is silently ignored.
        val builder = NotificationCompat.Builder(this, CHANNEL_ID)
            // Use the official transparent logo asset directly. Android may
            // tint its alpha mask in compact system layouts, while launchers
            // that preserve notification colors show the original gradient.
            .setSmallIcon(R.drawable.ic_nozelt_notification_logo)
            .setColor(0xFF08C7F4.toInt())
            .setColorized(false)
            .setContentTitle(
                localizedString(
                    if (engineRunning) {
                        R.string.vpn_notification_active
                    } else {
                        R.string.vpn_notification_recovering
                    },
                ),
            )
            .setContentText(notificationServerDetails())
            .setOngoing(true)
            .setOnlyAlertOnce(true)
            .setContentIntent(openAppPendingIntent())
            .setCategory(NotificationCompat.CATEGORY_SERVICE)
            .setVisibility(NotificationCompat.VISIBILITY_PUBLIC)
            .setPriority(NotificationCompat.PRIORITY_LOW)
        if (!alwaysOnPolicyActive) {
            builder.addAction(
                android.R.drawable.ic_menu_close_clear_cancel,
                localizedString(R.string.vpn_notification_disconnect),
                disconnectPendingIntent(),
            )
        }
        return builder.build()
    }

    private fun notificationServerDetails(): String {
        val preferences = getSharedPreferences(RUNTIME_PREFS, Context.MODE_PRIVATE)
        val flag = preferences.getString(PREF_NOTIFICATION_FLAG, null)
            ?.takeIf { it.isNotBlank() } ?: "🌐"
        val server = preferences.getString(PREF_NOTIFICATION_SERVER, null)
            ?.takeIf { it.isNotBlank() }
            ?: localizedString(R.string.vpn_notification_server_unknown)
        val pingMs = NotificationPingFreshness.currentPing(
            pingMs = preferences.getInt(PREF_NOTIFICATION_PING_MS, -1),
            measuredAtMs = preferences.getLong(PREF_NOTIFICATION_PING_MEASURED_AT_MS, -1L),
            maxAgeMs = preferences.getLong(PREF_NOTIFICATION_PING_MAX_AGE_MS, -1L),
            nowMs = System.currentTimeMillis(),
        )
        val ping = if (pingMs != null) {
            localizedString(R.string.vpn_notification_ping, pingMs)
        } else {
            localizedString(R.string.vpn_notification_ping_unknown)
        }
        return localizedString(R.string.vpn_notification_details, flag, server, ping)
    }

    private fun refreshNotification() {
        if (!desiredRunning) return
        runCatching {
            ensureNotificationChannel()
            val manager = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
            manager.notify(NOTIFICATION_ID, buildNotification())
            scheduleNotificationPingExpiry()
        }.onFailure {
            Log.w(TAG, "could not refresh localized VPN notification")
        }
    }

    /**
     * A latency sample is telemetry, not durable connection state. Refresh the
     * row exactly when it expires so an OEM notification cannot keep showing a
     * measurement from an old network for hours after Flutter was destroyed.
     */
    private fun scheduleNotificationPingExpiry() {
        notificationPingExpiryJob?.cancel()
        notificationPingExpiryJob = null
        if (!desiredRunning) return
        val preferences = getSharedPreferences(RUNTIME_PREFS, Context.MODE_PRIVATE)
        val remainingMs = NotificationPingFreshness.remainingFreshMs(
            pingMs = preferences.getInt(PREF_NOTIFICATION_PING_MS, -1),
            measuredAtMs = preferences.getLong(PREF_NOTIFICATION_PING_MEASURED_AT_MS, -1L),
            maxAgeMs = preferences.getLong(PREF_NOTIFICATION_PING_MAX_AGE_MS, -1L),
            nowMs = System.currentTimeMillis(),
        ) ?: return
        notificationPingExpiryJob = scope.launch {
            delay(remainingMs + 50L)
            refreshNotification()
        }
    }

    private fun refreshAlwaysOnPolicy() {
        alwaysOnPolicyActive = computeAlwaysOnPolicy()
        lockdownPolicyActive = computeLockdownPolicy()
    }

    private fun computeAlwaysOnPolicy(): Boolean = systemStartedAlwaysOn ||
        (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q && isAlwaysOn)

    private fun computeLockdownPolicy(): Boolean =
        Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q && isLockdownEnabled

    private fun localizedString(resourceId: Int, vararg formatArgs: Any): String {
        val language = getSharedPreferences(RUNTIME_PREFS, Context.MODE_PRIVATE)
            .getString(PREF_LANGUAGE, "ru") ?: "ru"
        val configuration = Configuration(resources.configuration).apply {
            setLocale(Locale.forLanguageTag(language))
        }
        return createConfigurationContext(configuration).getString(resourceId, *formatArgs)
    }

    /**
     * Parsed VpnService.Builder parameters. Mirrors the Dart
     * `kDefaultTunOptions` map. Every field has a safe default so a missing
     * or malformed bundle still yields a working tunnel.
     */
    private data class TunOptions(
        val mtu: Int,
        val ipv4Address: String,
        val ipv4Prefix: Int,
        val dnsServers: List<String>,
        val ipv6Enabled: Boolean,
        val ipv6Address: String,
        val ipv6Prefix: Int,
        val session: String,
        val splitMode: String,
        val apps: List<String>,
    ) {
        companion object {
            fun fromJson(json: String?): TunOptions {
                val o = if (json.isNullOrBlank()) {
                    JSONObject()
                } else {
                    try {
                        JSONObject(json)
                    } catch (_: Throwable) {
                        Log.w(TAG, "bad tunOptions JSON, using defaults")
                        JSONObject()
                    }
                }
                return TunOptions(
                    mtu = o.optInt("mtu", 9000),
                    ipv4Address = o.optString("ipv4Address", "172.19.0.1"),
                    ipv4Prefix = o.optInt("ipv4Prefix", 30),
                    dnsServers = o.optJSONArray("dnsServers").toBoundedStringList(
                        fallback = listOf("172.19.0.2"),
                        limit = MAX_TUN_OPTION_DNS_SERVERS,
                        maxCharacters = 128,
                    ),
                    ipv6Enabled = o.optBoolean("ipv6Enabled", false),
                    ipv6Address = o.optString("ipv6Address", "fdfe:dcba:9876::1"),
                    ipv6Prefix = o.optInt("ipv6Prefix", 126),
                    session = o.optString("session", "Nozelt")
                        .sanitizeOptionString(96)
                        .ifBlank { "Nozelt" },
                    splitMode = o.optString("splitMode", "off")
                        .takeIf { it == "allowed" || it == "disallowed" }
                        ?: "off",
                    apps = o.optJSONArray("apps").toBoundedStringList(
                        fallback = emptyList(),
                        limit = MAX_TUN_OPTION_APPS,
                        maxCharacters = 255,
                    ),
                )
            }
        }
    }
}

/**
 * Converts native/Go failures to a fixed, non-sensitive diagnostic token.
 * Never return the exception message: a future dependency could include a
 * proxy address or credential in it.
 */
internal fun classifyEngineStartFailure(failure: Throwable): String {
    val messages = generateSequence(failure) { it.cause }
        .take(8)
        .mapNotNull { it.message }
        .joinToString(" ")
        .lowercase(Locale.ROOT)
    return when {
        "already running" in messages -> "already-running"
        "failed to start tun listener" in messages -> "tun-listener"
        "netlink socket" in messages -> "android-network-monitor"
        "packages.xml" in messages -> "android-package-rules"
        "parse config" in messages || "mihomo parse failed" in messages -> "config-parse"
        "tun fd" in messages || "file descriptor" in messages -> "tun-fd"
        "privacy validation" in messages -> "privacy-validation"
        else -> "native-start"
    }
}

/** Converts an untrusted nullable JSON array into a bounded string list. */
private fun JSONArray?.toBoundedStringList(
    fallback: List<String>,
    limit: Int,
    maxCharacters: Int,
): List<String> {
    if (this == null) return fallback
    val values = buildList {
        for (i in 0 until minOf(length(), limit)) {
            optString(i, null)
                ?.sanitizeOptionString(maxCharacters)
                ?.takeIf { it.isNotBlank() }
                ?.let(::add)
        }
    }
    return values.ifEmpty { fallback }
}

private fun String.sanitizeOptionString(maxCharacters: Int): String =
    trim()
        .replace(Regex("[\\u0000-\\u001F\\u007F]"), "")
        .take(maxCharacters)
