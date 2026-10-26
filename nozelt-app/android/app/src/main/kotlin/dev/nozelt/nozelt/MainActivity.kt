package dev.nozelt.nozelt

import android.Manifest
import android.app.Activity
import android.content.Intent
import android.content.pm.ApplicationInfo
import android.content.pm.PackageManager
import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.drawable.Drawable
import android.net.Uri
import android.net.VpnService
import android.os.Build
import android.os.Bundle
import android.provider.OpenableColumns
import android.provider.Settings
import dev.nozelt.nozelt.NozeltLog as Log
import androidx.core.app.ActivityCompat
import androidx.core.content.FileProvider
import androidx.core.graphics.createBitmap
import androidx.lifecycle.lifecycleScope
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import kotlinx.coroutines.sync.Semaphore
import kotlinx.coroutines.sync.withPermit
import org.json.JSONObject
import java.io.ByteArrayOutputStream
import java.io.File
import java.util.UUID

/**
 * Hosts every platform channel exposed to the Flutter layer:
 *
 *  - method channel  `dev.nozelt.nozelt/engine`  — RPC-style start/stop/etc.
 *  - event  channel  `dev.nozelt.nozelt/traffic` — 1 Hz traffic frames
 *  - event  channel  `dev.nozelt.nozelt/logs`    — Go-side log lines
 *
 * Owns three pieces of mutable state, all guarded by being touched only on
 * the main thread:
 *
 *  - [loggerImpl] — the optional Go-side logger sink, created only while a
 *    diagnostics EventChannel consumer is attached;
 *  - [trafficStream] — owns a background scheduler, must be shut down in
 *    [onDestroy] to avoid leaking a thread;
 *  - [pendingPrepareResult] — the deferred MethodChannel.Result that we hold
 *    open while the system VPN consent dialog is on screen.
 */
class MainActivity : FlutterActivity() {

    companion object {
        const val EXTRA_CONNECT_FROM_TILE = "dev.nozelt.nozelt.extra.CONNECT_FROM_TILE"
        private const val TAG = "MainActivity"
        private const val CH_METHODS = "dev.nozelt.nozelt/engine"
        private const val CH_TRAFFIC = "dev.nozelt.nozelt/traffic"
        private const val CH_LOGS = "dev.nozelt.nozelt/logs"
        private const val REQ_VPN_PREPARE = 1001
        private const val REQ_CONFIG_FILE = 1002
        private const val REQ_NOTIFICATION_PERMISSION = 1003
        private const val UI_PREFS = "nozelt_ui_runtime"
        private const val PREF_NOTIFICATION_PERMISSION_REQUESTED =
            "notification_permission_requested"
        private const val SUBSCRIPTION_ID_PREFS = "nozelt_subscription_identity"
        private const val PREF_FALLBACK_HWID = "fallback_hwid"
        private const val MAX_CONFIG_FILE_BYTES = 16 * 1024 * 1024
        private const val MAX_APP_LABEL_CHARACTERS = 256
    }

    private var loggerImpl: LoggerImpl? = null
    private var trafficStream: TrafficStreamHandler? = null
    private lateinit var methodChannel: MethodChannel
    private var pendingPrepareResult: MethodChannel.Result? = null
    private var pendingConfigFileResult: MethodChannel.Result? = null
    private var pendingRoutingProfileLink: String? = null
    private var pendingQuickSettingsConnect = false
    private var pendingBootstrapRecoveryId: String? = null
    private val secureProfileStore by lazy { SecureProfileStore(applicationContext) }
    private val secureSettingsStore by lazy { SecureSettingsStore(applicationContext) }
    private val secureRuntimeRollbackStore by lazy {
        SecureRuntimeRollbackStore(applicationContext)
    }
    private val iconSemaphore = Semaphore(4)

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        methodChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CH_METHODS)
        methodChannel.setMethodCallHandler(::onMethodCall)
        pendingRoutingProfileLink = routingProfileLink(intent)
        pendingQuickSettingsConnect = pendingQuickSettingsConnect ||
            intent.getBooleanExtra(EXTRA_CONNECT_FROM_TILE, false)
        intent.removeExtra(EXTRA_CONNECT_FROM_TILE)

        EventChannel(flutterEngine.dartExecutor.binaryMessenger, CH_LOGS)
            .setStreamHandler(object : EventChannel.StreamHandler {
                override fun onListen(arguments: Any?, events: EventChannel.EventSink) {
                    // Loading the gomobile AAR is expensive. Do it only when a
                    // debug-log consumer is actually attached, not before the
                    // application's first Flutter frame.
                    val logger = loggerImpl ?: LoggerImpl(
                        logcatEnabled =
                            applicationInfo.flags and ApplicationInfo.FLAG_DEBUGGABLE != 0,
                    ).also { loggerImpl = it }
                    EngineBridge.installLogger(logger)
                    logger.attach(events)
                }
                override fun onCancel(arguments: Any?) {
                    loggerImpl?.let { logger ->
                        logger.detach()
                        EngineBridge.detachLogger(logger)
                    }
                }
            })

        trafficStream = TrafficStreamHandler().also { handler ->
            EventChannel(flutterEngine.dartExecutor.binaryMessenger, CH_TRAFFIC)
                .setStreamHandler(handler)
        }
    }

    private fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "start" -> handleStart(call, result)
            "stop" -> handleStop(result)
            "restart" -> handleRestart(result)
            "restartWithConfig" -> handleRestartWithConfig(call, result)
            "getStatus" -> handleGetStatus(result)
            "matchesRuntimeConfig" -> handleMatchesRuntimeConfig(call, result)
            "isVpnRequested" -> result.success(NozeltVpnService.isRequested(this))
            "isAlwaysOnVpn" -> result.success(NozeltVpnService.isAlwaysOnPolicyActive())
            "getVpnPolicyState" -> result.success(
                mapOf(
                    "alwaysOn" to NozeltVpnService.isAlwaysOnPolicyActive(),
                    "lockdown" to NozeltVpnService.isLockdownPolicyActive(),
                    "lockdownKnown" to NozeltVpnService.isLockdownDetectionSupported(),
                ),
            )
            "setPreferredLanguage" -> {
                result.success(
                    NozeltVpnService.setPreferredLanguage(
                        this,
                        call.argument<String>("code"),
                    ),
                )
            }
            "updateVpnNotification" -> {
                result.success(
                    NozeltVpnService.updateNotificationMetadata(
                        this,
                        call.argument<String>("flag"),
                        call.argument<String>("serverName"),
                        call.argument<Number>("pingMs")?.toInt(),
                        call.hasArgument("pingMs"),
                        call.argument<Number>("pingMeasuredAtMs")?.toLong(),
                        call.argument<Number>("pingMaxAgeMs")?.toLong(),
                    ),
                )
            }
            "consumeQuickSettingsConnectRequest" -> {
                val pending = pendingQuickSettingsConnect
                pendingQuickSettingsConnect = false
                result.success(pending)
            }
            "getVersion" -> handleGetVersion(result)
            "getSubscriptionHwid" -> handleGetSubscriptionHwid(result)
            "updateGeoData" -> handleUpdateGeoData(result)
            "getInitialRoutingProfileLink" -> {
                result.success(pendingRoutingProfileLink)
                pendingRoutingProfileLink = null
            }
            "openVpnSettings" -> handleOpenVpnSettings(result)
            "openExternalUrl" -> handleOpenExternalUrl(call, result)
            "getUpdateEnvironment" -> result.success(
                mapOf(
                    "abis" to Build.SUPPORTED_ABIS.toList(),
                    "directory" to updateDirectory().absolutePath,
                ),
            )
            "installUpdate" -> handleInstallUpdate(call, result)
            "prepareVpn" -> handlePrepareVpn(result)
            "pickConfigFile" -> handlePickConfigFile(result)
            "getInstalledApps" -> handleGetInstalledApps(result)
            "getAppIcon" -> handleGetAppIcon(call, result)
            "parseProxyLink" -> handleParseProxyLink(call, result)
            "parseSubscription" -> handleParseSubscription(call, result)
            "testProxyDelays" -> handleTestProxyDelays(call, result)
            "cancelDelayTests" -> handleCancelDelayTests(result)
            "selectProxy" -> handleSelectProxy(call, result)
            "reloadConfig" -> handleReloadConfig(call, result)
            "readSecureProfiles" -> handleReadSecureProfiles(result)
            "writeSecureProfiles" -> handleWriteSecureProfiles(call, result)
            "readLegacyProfiles" -> handleReadLegacyProfiles(result)
            "deleteLegacyProfiles" -> handleDeleteLegacyProfiles(result)
            "readAppPreferences" -> handleReadAppPreferences(result)
            "writeAppPreferences" -> handleWriteAppPreferences(call, result)
            "readSecureSettings" -> handleReadSecureSettings(result)
            "writeSecureSettings" -> handleWriteSecureSettings(call, result)
            "readRuntimeRollback" -> handleReadRuntimeRollback(result)
            "ackRuntimeRollback" -> handleAckRuntimeRollback(call, result)
            else -> result.notImplemented()
        }
    }

    override fun onStart() {
        super.onStart()
        trafficStream?.resume()
    }

    override fun onStop() {
        trafficStream?.pause()
        super.onStop()
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        val connectFromTile = intent.getBooleanExtra(EXTRA_CONNECT_FROM_TILE, false)
        intent.removeExtra(EXTRA_CONNECT_FROM_TILE)
        setIntent(intent)
        if (connectFromTile) {
            pendingQuickSettingsConnect = true
            if (::methodChannel.isInitialized) {
                methodChannel.invokeMethod("quickSettingsConnectRequested", null)
            }
        }
        val link = routingProfileLink(intent) ?: return
        if (::methodChannel.isInitialized) {
            methodChannel.invokeMethod("routingProfileLink", link)
        } else {
            pendingRoutingProfileLink = link
        }
    }

    private fun routingProfileLink(intent: Intent?): String? {
        val uri = intent?.data ?: return null
        // "/import/v2" is the compact link the app itself shares.
        if (uri.scheme != "nozelt" || uri.host != "routing-profile" ||
            (uri.path != "/import" && uri.path != "/import/v2")
        ) {
            return null
        }
        val value = uri.toString()
        return value.takeIf { it.length <= 2 * 1024 * 1024 }
    }

    private fun handleUpdateGeoData(result: MethodChannel.Result) {
        lifecycleScope.launch {
            try {
                withContext(Dispatchers.IO) {
                    NativeCoreProcess.updateXrayAssets(this@MainActivity)
                }
                result.success(true)
            } catch (_: Throwable) {
                Log.e(TAG, "geodata update failed")
                result.error("geodata_update_failed", "Could not update geodata", null)
            }
        }
    }

    private fun handlePickConfigFile(result: MethodChannel.Result) {
        if (pendingConfigFileResult != null) {
            result.error("busy", "another document picker is already open", null)
            return
        }
        pendingConfigFileResult = result
        try {
            @Suppress("DEPRECATION")
            startActivityForResult(
                Intent(Intent.ACTION_OPEN_DOCUMENT).apply {
                    addCategory(Intent.CATEGORY_OPENABLE)
                    type = "*/*"
                    putExtra(
                        Intent.EXTRA_MIME_TYPES,
                        arrayOf(
                    "application/yaml",
                    "text/yaml",
                    "application/json",
                    "text/plain",
                    "application/octet-stream",
                        ),
                    )
                },
                REQ_CONFIG_FILE,
            )
        } catch (_: Throwable) {
            pendingConfigFileResult = null
            result.error("file_pick_failed", "Could not open document picker", null)
        }
    }

    private fun finishConfigFilePick(uri: Uri?) {
        val result = pendingConfigFileResult ?: return
        pendingConfigFileResult = null
        if (uri == null) {
            result.success(null)
            return
        }
        lifecycleScope.launch {
            try {
                result.success(withContext(Dispatchers.IO) { readConfigDocument(uri) })
            } catch (_: ConfigFileTooLargeException) {
                result.error("file_too_large", "Selected document exceeds 16 MB", null)
            } catch (_: Throwable) {
                result.error("file_read_failed", "Could not read selected document", null)
            }
        }
    }

    private fun readConfigDocument(uri: Uri): Map<String, Any> {
        var displayName = "config.yaml"
        contentResolver.query(
            uri,
            arrayOf(OpenableColumns.DISPLAY_NAME, OpenableColumns.SIZE),
            null,
            null,
            null,
        )?.use { cursor ->
            if (cursor.moveToFirst()) {
                val nameIndex = cursor.getColumnIndex(OpenableColumns.DISPLAY_NAME)
                val sizeIndex = cursor.getColumnIndex(OpenableColumns.SIZE)
                if (nameIndex >= 0) {
                    displayName = cursor.getString(nameIndex)
                        ?.replace(Regex("[\\u0000-\\u001F\\u007F]"), " ")
                        ?.take(256)
                        ?.ifBlank { "config.yaml" }
                        ?: "config.yaml"
                }
                if (sizeIndex >= 0 && !cursor.isNull(sizeIndex) &&
                    cursor.getLong(sizeIndex) > MAX_CONFIG_FILE_BYTES
                ) {
                    throw ConfigFileTooLargeException()
                }
            }
        }

        val output = ByteArrayOutputStream()
        val buffer = ByteArray(DEFAULT_BUFFER_SIZE)
        var total = 0
        contentResolver.openInputStream(uri)?.use { input ->
            while (true) {
                val read = input.read(buffer)
                if (read < 0) break
                total += read
                if (total > MAX_CONFIG_FILE_BYTES) throw ConfigFileTooLargeException()
                output.write(buffer, 0, read)
            }
        } ?: error("content resolver returned no stream")
        return mapOf("name" to displayName, "bytes" to output.toByteArray())
    }

    private fun handleReadSecureSettings(result: MethodChannel.Result) {
        lifecycleScope.launch {
            try {
                result.success(withContext(Dispatchers.IO) { secureSettingsStore.read() })
            } catch (_: Throwable) {
                Log.e(TAG, "encrypted settings read failed")
                result.error("secure_settings_read_failed", "Could not decrypt settings", null)
            }
        }
    }

    private fun handleWriteSecureSettings(call: MethodCall, result: MethodChannel.Result) {
        val value = call.argument<String>("value")
        if (value == null) {
            result.error("bad_args", "value required", null)
            return
        }
        lifecycleScope.launch {
            try {
                withContext(Dispatchers.IO) { secureSettingsStore.write(value) }
                result.success(true)
            } catch (_: Throwable) {
                Log.e(TAG, "encrypted settings write failed")
                result.error("secure_settings_write_failed", "Could not encrypt settings", null)
            }
        }
    }

    private fun handleSelectProxy(call: MethodCall, result: MethodChannel.Result) {
        val groupName = call.argument<String>("groupName")?.trim().orEmpty()
        val proxyName = call.argument<String>("proxyName")?.trim().orEmpty()
        if (groupName.isEmpty() || proxyName.isEmpty()) {
            result.error("bad_args", "groupName and proxyName required", null)
            return
        }
        lifecycleScope.launch {
            try {
                EngineBridge.selectProxy(this@MainActivity, groupName, proxyName)
                result.success(true)
            } catch (_: Throwable) {
                Log.e(TAG, "live proxy selection failed")
                result.error("select_proxy_failed", "Could not select proxy", null)
            }
        }
    }

    private fun handleReloadConfig(call: MethodCall, result: MethodChannel.Result) {
        val configYaml = call.argument<String>("configYaml")
        if (configYaml.isNullOrBlank()) {
            result.error("bad_args", "configYaml required", null)
            return
        }
        val tunOptionsJson = call.argument<String>("tunOptionsJson")
        val core = call.argument<String>("core") ?: VpnCore.MIHOMO.wireName
        val rollbackKind = call.argument<String>("rollbackKind")
        val rollbackPayload = call.argument<String>("rollbackPayload")
        lifecycleScope.launch {
            try {
                EngineBridge.reloadConfig(
                    this@MainActivity,
                    core,
                    configYaml,
                    tunOptionsJson,
                    rollbackKind,
                    rollbackPayload,
                )
                result.success(true)
            } catch (_: Throwable) {
                Log.e(TAG, "live config reload failed")
                result.error("reload_failed", "Could not apply live config", null)
            }
        }
    }

    private fun handleReadSecureProfiles(result: MethodChannel.Result) {
        lifecycleScope.launch {
            try {
                result.success(withContext(Dispatchers.IO) { secureProfileStore.read() })
            } catch (_: Throwable) {
                Log.e(TAG, "encrypted profile read failed")
                result.error("secure_store_read_failed", "Could not decrypt profiles", null)
            }
        }
    }

    private fun legacyProfilesFile(): File = File(dataDir, "app_flutter/profiles.json")

    private fun handleReadLegacyProfiles(result: MethodChannel.Result) {
        lifecycleScope.launch {
            try {
                val value = withContext(Dispatchers.IO) {
                    legacyProfilesFile().takeIf { it.isFile }?.readText()
                }
                result.success(value)
            } catch (_: Throwable) {
                Log.e(TAG, "legacy profile read failed")
                result.error("legacy_profile_read_failed", "Could not migrate profiles", null)
            }
        }
    }

    private fun handleDeleteLegacyProfiles(result: MethodChannel.Result) {
        lifecycleScope.launch {
            try {
                val deleted = withContext(Dispatchers.IO) {
                    val file = legacyProfilesFile()
                    !file.exists() || file.delete()
                }
                result.success(deleted)
            } catch (_: Throwable) {
                Log.e(TAG, "legacy profile delete failed")
                result.error("legacy_profile_delete_failed", "Could not finish migration", null)
            }
        }
    }

    private fun handleReadAppPreferences(result: MethodChannel.Result) {
        lifecycleScope.launch {
            try {
                val values = withContext(Dispatchers.IO) {
                    val own = getSharedPreferences("nozelt_app_preferences", MODE_PRIVATE)
                        .getString("snapshot", null)
                    if (own != null) {
                        val json = JSONObject(own)
                        buildMap<String, String> {
                            for (key in json.keys()) {
                                json.optString(key, null)?.let { put(key, it) }
                            }
                        }
                    } else {
                        // Migrate values written by the former Flutter plugin.
                        val legacy = getSharedPreferences(
                            "FlutterSharedPreferences",
                            MODE_PRIVATE,
                        )
                        buildMap<String, String> {
                            listOf(
                                "app_settings_v1",
                                "tun_settings_v1",
                                "split_tunnel_v1",
                            ).forEach { key ->
                                legacy.getString("flutter.$key", null)?.let {
                                    put(key, it)
                                }
                            }
                        }
                    }
                }
                result.success(values)
            } catch (_: Throwable) {
                Log.e(TAG, "application preferences read failed")
                result.error("preferences_read_failed", "Could not read preferences", null)
            }
        }
    }

    private fun handleWriteAppPreferences(call: MethodCall, result: MethodChannel.Result) {
        val value = call.argument<String>("value")
        if (value == null) {
            result.error("bad_args", "value required", null)
            return
        }
        lifecycleScope.launch {
            try {
                JSONObject(value)
                val saved = withContext(Dispatchers.IO) {
                    getSharedPreferences("nozelt_app_preferences", MODE_PRIVATE)
                        .edit()
                        .putString("snapshot", value)
                        .commit()
                }
                result.success(saved)
            } catch (_: Throwable) {
                Log.e(TAG, "application preferences write failed")
                result.error("preferences_write_failed", "Could not save preferences", null)
            }
        }
    }

    private fun handleWriteSecureProfiles(call: MethodCall, result: MethodChannel.Result) {
        val value = call.argument<String>("value")
        if (value == null) {
            result.error("bad_args", "value required", null)
            return
        }
        lifecycleScope.launch {
            try {
                withContext(Dispatchers.IO) { secureProfileStore.write(value) }
                result.success(true)
            } catch (_: Throwable) {
                Log.e(TAG, "encrypted profile write failed")
                result.error("secure_store_write_failed", "Could not encrypt profiles", null)
            }
        }
    }

    private fun handleReadRuntimeRollback(result: MethodChannel.Result) {
        lifecycleScope.launch {
            try {
                val rollback = withContext(Dispatchers.IO) {
                    EngineBridge.readRuntimeRollback(this@MainActivity)
                }
                // If Android evicted the service between a staged replacement
                // and its outcome, bootstrap must wake it. ProviderScope (and
                // its normal foreground restore) is deliberately created only
                // after this journal has settled.
                if (rollback != null && !rollback.rolledBack &&
                    pendingBootstrapRecoveryId != rollback.id &&
                    NozeltVpnService.isRequested(this@MainActivity) &&
                    !NozeltVpnService.isServiceActive()
                ) {
                    EngineBridge.restart(this@MainActivity)
                    pendingBootstrapRecoveryId = rollback.id
                }
                result.success(
                    rollback?.let {
                        if (it.rolledBack) {
                            mapOf(
                                "id" to it.id,
                                "kind" to it.kind,
                                "payload" to it.payload,
                                "rolledBack" to true,
                            )
                        } else {
                            // Pending means "wait", never "restore". Keep the
                            // credential-bearing payload on the native side
                            // until the service has made that outcome durable.
                            mapOf("id" to it.id, "rolledBack" to false)
                        }
                    },
                )
            } catch (_: Throwable) {
                Log.e(TAG, "encrypted runtime rollback read failed")
                result.error(
                    "runtime_rollback_read_failed",
                    "Could not read VPN rollback state",
                    null,
                )
            }
        }
    }

    private fun handleAckRuntimeRollback(call: MethodCall, result: MethodChannel.Result) {
        val id = call.argument<String>("id")?.trim().orEmpty()
        if (id.isEmpty()) {
            result.error("bad_args", "rollback id required", null)
            return
        }
        lifecycleScope.launch {
            try {
                val acknowledged = withContext(Dispatchers.IO) {
                    secureRuntimeRollbackStore.deleteIfId(id)
                }
                result.success(acknowledged)
            } catch (_: Throwable) {
                Log.e(TAG, "encrypted runtime rollback acknowledgement failed")
                result.error(
                    "runtime_rollback_ack_failed",
                    "Could not acknowledge VPN rollback state",
                    null,
                )
            }
        }
    }

    private fun handleTestProxyDelays(call: MethodCall, result: MethodChannel.Result) {
        val core = VpnCore.fromWireName(call.argument<String>("core"))
        val nativeTargetsJson = call.argument<String>("nativeTargetsJson")
        val configYaml = call.argument<String>("configYaml")
        val namesJson = call.argument<String>("namesJson")
        val testUrl = call.argument<String>("testUrl") ?: ""
        val requestId = call.argument<String>("requestId")
        val timeoutMs = call.argument<Number>("timeoutMs")?.toLong() ?: 7_000L
        if (core == VpnCore.MIHOMO && (configYaml.isNullOrBlank() || namesJson == null)) {
            result.error("bad_args", "Mihomo configYaml and namesJson required", null)
            return
        }
        if (core != VpnCore.MIHOMO && nativeTargetsJson == null) {
            result.error("bad_args", "nativeTargetsJson required", null)
            return
        }
        lifecycleScope.launch {
            try {
                result.success(withContext(Dispatchers.IO) {
                    val response: String
                    val mode: String
                    if (core != VpnCore.MIHOMO) {
                        response = NativeCoreDelayTester.test(
                            applicationContext,
                            core,
                            nativeTargetsJson!!,
                            timeoutMs.toInt(),
                        ) { name, delay -> emitProxyDelayResult(requestId, name, delay) }
                        mode = core.wireName
                    } else {
                        runCatching { EngineBridge.prepareMihomoDataDir(applicationContext) }
                        val offline = !NozeltVpnService.isRequested(applicationContext)
                        response = if (!offline) {
                            EngineBridge.testProxyDelays(
                                configYaml!!,
                                namesJson!!,
                                testUrl,
                                timeoutMs,
                            ) { name, delay ->
                                emitProxyDelayResult(requestId, name, delay)
                            }
                        } else {
                            EngineBridge.testProxyDelaysOffline(
                                configYaml!!,
                                namesJson!!,
                                testUrl,
                                timeoutMs,
                            ) { name, delay ->
                                emitProxyDelayResult(requestId, name, delay)
                            }
                        }
                        mode = if (offline) "mihomo-offline" else "mihomo-protected"
                    }
                    logProxyDelayOutcome(response, mode)
                    response
                })
            } catch (_: Throwable) {
                Log.e(TAG, "testProxyDelays failed")
                result.error("delay_test_failed", "Could not test proxy delay", null)
            }
        }
    }

    private fun emitProxyDelayResult(requestId: String?, name: String, delay: Int?) {
        if (requestId.isNullOrBlank()) return
        runOnUiThread {
            if (!::methodChannel.isInitialized || isDestroyed) return@runOnUiThread
            methodChannel.invokeMethod(
                "proxyDelayResult",
                mapOf(
                    "requestId" to requestId,
                    "name" to name,
                    "delay" to delay,
                ),
            )
        }
    }

    private fun logProxyDelayOutcome(response: String, mode: String) {
        runCatching {
            val envelope = JSONObject(response)
            if (!envelope.optBoolean("ok", false)) {
                // Core boundary errors are fixed, credential-free strings.
                Log.w(
                    TAG,
                    "proxy delay test rejected mode=$mode reason=" +
                        envelope.optString("error", "unknown"),
                )
                return
            }
            val results = envelope.optJSONObject("results") ?: JSONObject()
            var succeeded = 0
            val failures = linkedMapOf<String, Int>()
            for (name in results.keys()) {
                val item = results.optJSONObject(name) ?: continue
                if (item.optInt("delay", 0) > 0) {
                    succeeded++
                } else {
                    val category = item.optString("error", "unknown")
                    failures[category] = (failures[category] ?: 0) + 1
                }
            }
            Log.i(
                TAG,
                "proxy delay test finished mode=$mode succeeded=$succeeded " +
                    "failures=$failures",
            )
        }.onFailure {
            Log.w(TAG, "proxy delay test returned an invalid envelope")
        }
    }

    private fun handleCancelDelayTests(result: MethodChannel.Result) {
        lifecycleScope.launch {
            try {
                withContext(Dispatchers.IO) {
                    NativeCoreDelayTester.cancel()
                    EngineBridge.cancelDelayTestsSync()
                }
                result.success(true)
            } catch (_: Throwable) {
                Log.w(TAG, "cancelDelayTests failed")
                result.error("delay_cancel_failed", "Could not cancel proxy delay tests", null)
            }
        }
    }

    /**
     * Parses a single proxy share link via the Go convert engine. Runs on IO
     * because parsing (and the underlying mihomo work) should not touch the
     * main thread. Returns the JSON envelope verbatim; the Dart side decodes
     * the ok/error/proxy shape.
     */
    private fun handleParseProxyLink(call: MethodCall, result: MethodChannel.Result) {
        val link = call.argument<String>("link")
        if (link.isNullOrBlank()) {
            result.error("bad_args", "link required", null)
            return
        }
        lifecycleScope.launch {
            try {
                result.success(withContext(Dispatchers.IO) { EngineBridge.parseProxyLink(link) })
            } catch (_: Throwable) {
                Log.e(TAG, "parseProxyLink failed")
                result.error("parse_failed", "Could not parse proxy link", null)
            }
        }
    }

    /**
     * Parses already-downloaded subscription content (the host does the HTTP
     * GET) via the Go convert engine, on IO.
     */
    private fun handleParseSubscription(call: MethodCall, result: MethodChannel.Result) {
        val content = call.argument<String>("content")
        if (content == null) {
            result.error("bad_args", "content required", null)
            return
        }
        lifecycleScope.launch {
            try {
                result.success(withContext(Dispatchers.IO) { EngineBridge.parseSubscription(content) })
            } catch (_: Throwable) {
                Log.e(TAG, "parseSubscription failed")
                result.error("parse_failed", "Could not parse subscription", null)
            }
        }
    }

    private fun handleStart(call: MethodCall, result: MethodChannel.Result) {
        val yaml = call.argument<String>("configYaml")
        if (yaml.isNullOrBlank()) {
            result.error("bad_args", "configYaml missing or empty", null)
            return
        }
        // Optional VpnService.Builder parameter bundle (already JSON-encoded
        // by the Dart layer). Forwarded verbatim to the service.
        val tunOptionsJson = call.argument<String>("tunOptionsJson")
        val core = call.argument<String>("core") ?: VpnCore.MIHOMO.wireName
        // The actual establish + start runs inside the foreground service. We
        // only dispatch the intent here; success just means "dispatched", the
        // engine coming up is observed via getStatus polling on the Dart side.
        lifecycleScope.launch {
            try {
                EngineBridge.start(this@MainActivity, core, yaml, tunOptionsJson)
                result.success(true)
            } catch (_: Throwable) {
                Log.e(TAG, "start dispatch failed")
                result.error("start_failed", "Could not start VPN", null)
            }
        }
    }

    private fun handleStop(result: MethodChannel.Result) {
        lifecycleScope.launch {
            try {
                EngineBridge.stop(this@MainActivity)
                result.success(true)
            } catch (_: Throwable) {
                Log.e(TAG, "stop dispatch failed")
                result.error("stop_failed", "Could not stop VPN", null)
            }
        }
    }

    private fun handleRestart(result: MethodChannel.Result) {
        lifecycleScope.launch {
            try {
                EngineBridge.restart(this@MainActivity)
                result.success(true)
            } catch (_: Throwable) {
                Log.e(TAG, "restart dispatch failed")
                result.error("restart_failed", "Could not restart VPN", null)
            }
        }
    }

    private fun handleRestartWithConfig(call: MethodCall, result: MethodChannel.Result) {
        val yaml = call.argument<String>("configYaml")
        if (yaml.isNullOrBlank()) {
            result.error("bad_args", "configYaml missing or empty", null)
            return
        }
        val tunOptionsJson = call.argument<String>("tunOptionsJson")
        val core = call.argument<String>("core") ?: VpnCore.MIHOMO.wireName
        val rollbackKind = call.argument<String>("rollbackKind")
        val rollbackPayload = call.argument<String>("rollbackPayload")
        lifecycleScope.launch {
            try {
                result.success(
                    EngineBridge.restartWithConfig(
                        this@MainActivity,
                        core,
                        yaml,
                        tunOptionsJson,
                        rollbackKind,
                        rollbackPayload,
                    ),
                )
            } catch (_: Throwable) {
                Log.e(TAG, "config replacement restart dispatch failed")
                result.error("restart_failed", "Could not replace VPN configuration", null)
            }
        }
    }

    private fun handleGetStatus(result: MethodChannel.Result) {
        lifecycleScope.launch {
            try {
                result.success(EngineBridge.getStatusJson())
            } catch (_: Throwable) {
                result.error("status_failed", "Could not read VPN status", null)
            }
        }
    }

    private fun handleMatchesRuntimeConfig(
        call: MethodCall,
        result: MethodChannel.Result,
    ) {
        val yaml = call.argument<String>("configYaml")
        if (yaml.isNullOrBlank()) {
            result.error("bad_args", "configYaml missing or empty", null)
            return
        }
        val tunOptionsJson = call.argument<String>("tunOptionsJson")
        val core = call.argument<String>("core") ?: VpnCore.MIHOMO.wireName
        lifecycleScope.launch {
            try {
                result.success(
                    EngineBridge.matchesRuntimeConfig(
                        this@MainActivity,
                        core,
                        yaml,
                        tunOptionsJson,
                    ),
                )
            } catch (_: Throwable) {
                result.error(
                    "runtime_match_failed",
                    "Could not compare active VPN configuration",
                    null,
                )
            }
        }
    }

    private fun handleGetVersion(result: MethodChannel.Result) {
        lifecycleScope.launch {
            try {
                result.success(EngineBridge.getVersionJson())
            } catch (_: Throwable) {
                result.error("version_failed", "Could not read engine version", null)
            }
        }
    }

    private fun handleOpenVpnSettings(result: MethodChannel.Result) {
        try {
            startActivity(
                Intent(Settings.ACTION_VPN_SETTINGS).apply {
                    addFlags(Intent.FLAG_ACTIVITY_CLEAR_TOP)
                },
            )
            result.success(true)
        } catch (_: Throwable) {
            Log.e(TAG, "could not open Android VPN settings")
            result.error("vpn_settings_failed", "Could not open Android VPN settings", null)
        }
    }

    private fun handleGetSubscriptionHwid(result: MethodChannel.Result) {
        try {
            val androidId = Settings.Secure.getString(
                contentResolver,
                Settings.Secure.ANDROID_ID,
            )?.trim().orEmpty()
            val hwid = if (androidId.isNotEmpty()) {
                // UUID.nameUUIDFromBytes gives panels the expected 36-character
                // identifier without exposing Android's source identifier.
                UUID.nameUUIDFromBytes(
                    "$packageName:$androidId".toByteArray(Charsets.UTF_8),
                ).toString()
            } else {
                val preferences = getSharedPreferences(
                    SUBSCRIPTION_ID_PREFS,
                    MODE_PRIVATE,
                )
                preferences.getString(PREF_FALLBACK_HWID, null)
                    ?: UUID.randomUUID().toString().also {
                        preferences.edit().putString(PREF_FALLBACK_HWID, it).commit()
                    }
            }
            result.success(hwid)
        } catch (_: Throwable) {
            Log.w(TAG, "subscription device identifier unavailable")
            result.error(
                "subscription_hwid_unavailable",
                "Could not create subscription device identifier",
                null,
            )
        }
    }

    private fun updateDirectory(): File = File(cacheDir, "updates").apply { mkdirs() }

    /**
     * Hands a downloaded, SHA-256-verified Nozelt APK to the system installer.
     * Only files in the private update cache are accepted, and only an APK of
     * this package with a newer version. Android itself rejects a different
     * signing key. Returns "permission" after opening the "install unknown
     * apps" page when that permission is still missing.
     */
    @Suppress("DEPRECATION")
    private fun handleInstallUpdate(call: MethodCall, result: MethodChannel.Result) {
        val directory = updateDirectory().canonicalFile
        val file = call.argument<String>("path")?.let { File(it).canonicalFile }
        if (file == null || file.parentFile != directory || !file.isFile ||
            !file.name.endsWith(".apk")
        ) {
            result.error("invalid_update", "Update file is not in the update cache", null)
            return
        }
        try {
            val archive = packageManager.getPackageArchiveInfo(file.path, 0)
            val installed = packageManager.getPackageInfo(packageName, 0)
            val newer = archive != null && archive.packageName == packageName &&
                (if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
                    archive.longVersionCode > installed.longVersionCode
                } else {
                    archive.versionCode > installed.versionCode
                })
            if (!newer) {
                result.error("invalid_update", "Not a newer Nozelt build", null)
                return
            }
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O &&
                !packageManager.canRequestPackageInstalls()
            ) {
                startActivity(
                    Intent(
                        Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES,
                        Uri.parse("package:$packageName"),
                    ),
                )
                result.success("permission")
                return
            }
            val uri = FileProvider.getUriForFile(this, "$packageName.updates", file)
            startActivity(
                Intent(Intent.ACTION_VIEW).apply {
                    setDataAndType(uri, "application/vnd.android.package-archive")
                    addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                    addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                },
            )
            result.success("started")
        } catch (_: Throwable) {
            Log.e(TAG, "could not start the update installer")
            result.error("install_failed", "Could not start the installer", null)
        }
    }

    private fun handleOpenExternalUrl(
        call: MethodCall,
        result: MethodChannel.Result,
    ) {
        val value = call.argument<String>("url")
        val uri = value?.takeIf { it.length <= 8192 }?.let(Uri::parse)
        if (uri == null || uri.scheme != "https" || uri.host.isNullOrBlank()) {
            result.error("invalid_url", "Only valid HTTPS links can be opened", null)
            return
        }
        try {
            startActivity(
                Intent(Intent.ACTION_VIEW, uri).apply {
                    addFlags(Intent.FLAG_ACTIVITY_CLEAR_TOP)
                },
            )
            result.success(true)
        } catch (_: Throwable) {
            Log.e(TAG, "could not open external HTTPS link")
            result.error("url_open_failed", "Could not open the link", null)
        }
    }

    /**
     * Returns the installed apps as a list of `{packageName, label, system}`
     * maps for the split-tunnel picker. Labels-only (no icons) so the list
     * loads fast even with hundreds of apps; icons are fetched lazily via
     * [handleGetAppIcon]. Our own package is hidden because its routing is a
     * security invariant, not a user-selectable exception. The PackageManager
     * query runs on the IO dispatcher.
     */
    private fun handleGetInstalledApps(result: MethodChannel.Result) {
        lifecycleScope.launch {
            try {
                val apps = withContext(Dispatchers.IO) {
                    val pm = packageManager
                    val self = packageName
                    pm.getInstalledApplications(0)
                        .asSequence()
                        .filter { it.packageName != self }
                        .map { ai ->
                            mapOf(
                                "packageName" to ai.packageName,
                                "label" to pm.getApplicationLabel(ai).toString()
                                    .replace(Regex("[\\u0000-\\u001F\\u007F]"), " ")
                                    .take(MAX_APP_LABEL_CHARACTERS)
                                    .ifBlank { ai.packageName },
                                "system" to ((ai.flags and ApplicationInfo.FLAG_SYSTEM) != 0),
                            )
                        }
                        .sortedBy { (it["label"] as String).lowercase() }
                        .toList()
                }
                result.success(apps)
            } catch (_: Throwable) {
                Log.e(TAG, "getInstalledApps failed")
                result.error("apps_failed", "Could not list installed apps", null)
            }
        }
    }

    /**
     * Returns raw PNG bytes (96x96) for one app's icon, or an error if
     * the package has no resolvable icon. Rendered on the IO dispatcher so a
     * fast scroll does not jank the UI thread. The Dart side caches results.
     */
    private fun handleGetAppIcon(call: MethodCall, result: MethodChannel.Result) {
        val pkg = call.argument<String>("packageName")
        if (pkg.isNullOrBlank()) {
            result.error("bad_args", "packageName required", null)
            return
        }
        lifecycleScope.launch {
            val png = withContext(Dispatchers.IO) {
                iconSemaphore.withPermit {
                    try {
                        drawableToPngBytes(packageManager.getApplicationIcon(pkg), 96)
                    } catch (_: Throwable) {
                        Log.w(TAG, "getAppIcon failed for requested package")
                        null
                    }
                }
            }
            if (png != null) result.success(png) else result.error("icon_failed", "no icon available", null)
        }
    }

    /** Rasterises any Drawable (incl. adaptive icons) to raw PNG bytes. */
    private fun drawableToPngBytes(drawable: Drawable, size: Int): ByteArray {
        val bitmap = createBitmap(size, size)
        return try {
            val canvas = Canvas(bitmap)
            drawable.setBounds(0, 0, size, size)
            drawable.draw(canvas)
            ByteArrayOutputStream().use { stream ->
                bitmap.compress(Bitmap.CompressFormat.PNG, 100, stream)
                stream.toByteArray()
            }
        } finally {
            // Hundreds of third-party icons can be requested during a long
            // split-tunnel scroll. Release native bitmap storage promptly
            // instead of waiting for an unpredictable GC/finalizer cycle.
            bitmap.recycle()
        }
    }

    private fun handlePrepareVpn(result: MethodChannel.Result) {
        if (pendingPrepareResult != null) {
            result.error("busy", "another prepareVpn() is already in flight", null)
            return
        }
        pendingPrepareResult = result
        val intent = try {
            VpnService.prepare(this)
        } catch (_: Throwable) {
            pendingPrepareResult = null
            result.error("prepare_failed", "Could not prepare VPN permission", null)
            return
        }
        if (intent == null) {
            requestNotificationPermissionIfNeeded()
            return
        }
        try {
            @Suppress("DEPRECATION")
            startActivityForResult(intent, REQ_VPN_PREPARE)
        } catch (_: Throwable) {
            pendingPrepareResult = null
            result.error("prepare_failed", "Could not open VPN permission dialog", null)
        }
    }

    @Deprecated("Required for VpnService.prepare() consent dialog result")
    @Suppress("DEPRECATION")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode == REQ_VPN_PREPARE) {
            if (resultCode == Activity.RESULT_OK) {
                requestNotificationPermissionIfNeeded()
            } else {
                finishVpnPreparation(false)
            }
        } else if (requestCode == REQ_CONFIG_FILE) {
            finishConfigFilePick(
                if (resultCode == Activity.RESULT_OK) data?.data else null,
            )
        }
    }

    private fun requestNotificationPermissionIfNeeded() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU ||
            checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) ==
            PackageManager.PERMISSION_GRANTED
        ) {
            finishVpnPreparation(true)
            return
        }
        val preferences = getSharedPreferences(UI_PREFS, MODE_PRIVATE)
        if (preferences.getBoolean(PREF_NOTIFICATION_PERMISSION_REQUESTED, false)) {
            finishVpnPreparation(true)
            return
        }
        // Persist before opening system UI so an Activity recreation or OEM
        // kill cannot turn every reconnect into another permission prompt.
        preferences.edit()
            .putBoolean(PREF_NOTIFICATION_PERMISSION_REQUESTED, true)
            .commit()
        try {
            ActivityCompat.requestPermissions(
                this,
                arrayOf(Manifest.permission.POST_NOTIFICATIONS),
                REQ_NOTIFICATION_PERMISSION,
            )
        } catch (_: Throwable) {
            finishVpnPreparation(true)
        }
    }

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray,
    ) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode == REQ_NOTIFICATION_PERMISSION) {
            // A visible notification is strongly preferable, but Android
            // permits a VPN foreground service to run when the user declines.
            finishVpnPreparation(true)
        }
    }

    private fun finishVpnPreparation(granted: Boolean) {
        val pending = pendingPrepareResult
        pendingPrepareResult = null
        pending?.success(granted)
    }

    override fun onDestroy() {
        // The Flutter engine is going away, so deferred platform-channel
        // results can no longer be delivered. Drop the Activity references
        // explicitly instead of retaining them until a late system activity
        // result arrives (or forever if the picker/consent UI was replaced).
        pendingPrepareResult = null
        pendingConfigFileResult = null
        trafficStream?.shutdown()
        trafficStream = null
        loggerImpl?.let { logger ->
            logger.detach()
            // Activity recreation can overlap old onDestroy with the new
            // EventChannel listener. Detach only if this Activity still owns
            // the process-global Go logger, otherwise the new diagnostics
            // stream would be silently disconnected.
            EngineBridge.detachLogger(logger)
        }
        loggerImpl = null
        super.onDestroy()
    }
}

private class ConfigFileTooLargeException : Exception()
