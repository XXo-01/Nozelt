package dev.nozelt.nozelt

import android.content.Context
import java.io.File
import java.net.HttpURLConnection
import java.net.URL
import java.security.MessageDigest

/**
 * Starts non-gomobile Go cores behind a process boundary.
 *
 * Xray and sing-box receive descriptor 3 as their TUN device. The process
 * boundary prevents their independent Go runtimes from colliding with the
 * embedded Mihomo runtime.
 */
internal object NativeCoreProcess {
    internal data class ProbeHandle(
        val pid: Int,
        val configFile: File,
        val logFile: File,
    )

    init {
        System.loadLibrary("nozelt_spawn")
    }

    private var activePid: Int = 0

    @Synchronized
    fun start(
        context: Context,
        core: VpnCore,
        configFile: File,
        tunFd: Int,
    ) {
        require(core != VpnCore.MIHOMO) { "Mihomo is embedded and cannot be spawned" }
        stop()
        val libraryName = when (core) {
            VpnCore.XRAY -> "libxray_exec.so"
            VpnCore.SING_BOX -> "libsingbox_exec.so"
            VpnCore.MIHOMO -> error("unreachable")
        }
        val executable = File(context.applicationInfo.nativeLibraryDir, libraryName)
        check(executable.isFile) { "Core executable is missing: ${executable.absolutePath}" }
        val logFile = File(context.noBackupFilesDir, "runtime/${core.wireName}.log").apply {
            parentFile?.mkdirs()
            if (length() > 1024L * 1024L) writeText("")
        }
        val assetDirectory = if (core == VpnCore.XRAY) {
            prepareXrayAssets(context).absolutePath
        } else {
            ""
        }
        val pid = nativeSpawn(
            executable.absolutePath,
            configFile.absolutePath,
            core.wireName,
            logFile.absolutePath,
            assetDirectory,
            tunFd,
        )
        check(pid > 0) { "Unable to start ${core.wireName}: native error $pid" }
        activePid = pid
        repeat(20) {
            Thread.sleep(25)
            check(nativeIsAlive(pid)) {
                val detail = runCatching { logFile.readText().takeLast(4000) }.getOrDefault("")
                "${core.displayName} stopped during startup${if (detail.isBlank()) "" else ": $detail"}"
            }
        }
    }

    @Synchronized
    fun isRunning(): Boolean {
        val pid = activePid
        return pid > 0 && nativeIsAlive(pid)
    }

    @Synchronized
    fun stop() {
        val pid = activePid
        activePid = 0
        if (pid > 0) nativeTerminate(pid)
    }

    /**
     * Starts an isolated listener-only core for latency testing. It never
     * receives a TUN descriptor and does not replace the active VPN process.
     */
    fun startProbe(
        context: Context,
        core: VpnCore,
        config: String,
    ): ProbeHandle {
        require(core != VpnCore.MIHOMO) { "Mihomo probes use the embedded core" }
        val runtimeDirectory = File(context.noBackupFilesDir, "runtime/probes").apply {
            mkdirs()
        }
        val configFile = File.createTempFile("probe-", ".json", runtimeDirectory)
        val logFile = File.createTempFile("probe-", ".log", runtimeDirectory)
        try {
            configFile.writeText(config, Charsets.UTF_8)
            configFile.setReadable(false, false)
            configFile.setReadable(true, true)
            val executable = coreExecutable(context, core)
            val assetDirectory = if (core == VpnCore.XRAY) {
                prepareXrayAssets(context).absolutePath
            } else {
                ""
            }
            val pid = nativeSpawn(
                executable.absolutePath,
                configFile.absolutePath,
                core.wireName,
                logFile.absolutePath,
                assetDirectory,
                -1,
            )
            check(pid > 0) { "Unable to start ${core.wireName} probe: native error $pid" }
            Thread.sleep(25)
            check(nativeIsAlive(pid)) {
                val detail = runCatching { logFile.readText().takeLast(4000) }.getOrDefault("")
                "${core.displayName} probe stopped during startup" +
                    if (detail.isBlank()) "" else ": $detail"
            }
            return ProbeHandle(pid, configFile, logFile)
        } catch (failure: Throwable) {
            runCatching { configFile.delete() }
            runCatching { logFile.delete() }
            throw failure
        }
    }

    fun isProbeRunning(handle: ProbeHandle): Boolean = nativeIsAlive(handle.pid)

    fun stopProbe(handle: ProbeHandle) {
        nativeTerminate(handle.pid)
        runCatching { handle.configFile.delete() }
        runCatching { handle.logFile.delete() }
    }

    private fun coreExecutable(context: Context, core: VpnCore): File {
        val libraryName = when (core) {
            VpnCore.XRAY -> "libxray_exec.so"
            VpnCore.SING_BOX -> "libsingbox_exec.so"
            VpnCore.MIHOMO -> error("Mihomo is embedded and has no executable")
        }
        return File(context.applicationInfo.nativeLibraryDir, libraryName).also {
            check(it.isFile) { "Core executable is missing: ${it.absolutePath}" }
        }
    }

    /** Shared GeoIP/GeoSite folder for Xray and the embedded Mihomo core. */
    internal fun geodataDirectory(context: Context): File = prepareXrayAssets(context)

    private fun prepareXrayAssets(context: Context): File {
        val directory = File(context.noBackupFilesDir, "xray-assets-v26.9.9").apply {
            mkdirs()
        }
        for (name in listOf("geoip.dat", "geosite.dat")) {
            val output = File(directory, name)
            if (output.isFile && output.length() > 0L) continue
            val temporary = File(directory, "$name.tmp")
            try {
                context.assets.open("xray/$name").use { input ->
                    temporary.outputStream().buffered().use { output ->
                        input.copyTo(output)
                    }
                }
                check(temporary.length() > 0L) { "Xray asset $name is empty" }
                check(temporary.renameTo(output)) { "Could not install Xray asset $name" }
            } finally {
                if (temporary.exists()) temporary.delete()
            }
        }
        return directory
    }

    fun updateXrayAssets(context: Context) {
        val directory = prepareXrayAssets(context)
        val staged = mutableListOf<Pair<File, File>>()
        try {
            for (name in listOf("geoip.dat", "geosite.dat")) {
                val base =
                    "https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/$name"
                val expected = downloadBytes("$base.sha256sum", 4096)
                    .toString(Charsets.UTF_8)
                    .trim()
                    .substringBefore(' ')
                    .lowercase()
                require(expected.matches(Regex("[0-9a-f]{64}"))) {
                    "Invalid checksum for $name"
                }
                val bytes = downloadBytes(base, 64 * 1024 * 1024)
                require(bytes.isNotEmpty()) { "Downloaded $name is empty" }
                val actual = MessageDigest.getInstance("SHA-256")
                    .digest(bytes)
                    .joinToString("") { "%02x".format(it) }
                require(actual == expected) { "Checksum mismatch for $name" }
                val temporary = File(directory, "$name.download")
                temporary.writeBytes(bytes)
                staged += temporary to File(directory, name)
            }
            for ((temporary, destination) in staged) {
                val backup = File(directory, "${destination.name}.backup")
                if (backup.exists()) backup.delete()
                if (destination.exists()) {
                    check(destination.renameTo(backup)) {
                        "Could not stage old ${destination.name}"
                    }
                }
                try {
                    check(temporary.renameTo(destination)) {
                        "Could not install ${destination.name}"
                    }
                    backup.delete()
                } catch (failure: Throwable) {
                    if (!destination.exists() && backup.exists()) {
                        backup.renameTo(destination)
                    }
                    throw failure
                }
            }
        } finally {
            for ((temporary, _) in staged) {
                if (temporary.exists()) temporary.delete()
            }
        }
    }

    private fun downloadBytes(url: String, maxBytes: Int): ByteArray {
        val connection = URL(url).openConnection() as HttpURLConnection
        connection.instanceFollowRedirects = true
        connection.connectTimeout = 12_000
        connection.readTimeout = 30_000
        connection.setRequestProperty("User-Agent", "Nozelt/1.0")
        try {
            check(connection.responseCode in 200..299) {
                "Geodata server returned ${connection.responseCode}"
            }
            val declared = connection.contentLengthLong
            require(declared < 0 || declared <= maxBytes) { "Geodata file is too large" }
            return connection.inputStream.use { input ->
                val output = java.io.ByteArrayOutputStream()
                val buffer = ByteArray(DEFAULT_BUFFER_SIZE)
                while (true) {
                    val read = input.read(buffer)
                    if (read < 0) break
                    require(output.size() + read <= maxBytes) { "Geodata file is too large" }
                    output.write(buffer, 0, read)
                }
                output.toByteArray()
            }
        } finally {
            connection.disconnect()
        }
    }

    private external fun nativeSpawn(
        executable: String,
        config: String,
        core: String,
        log: String,
        assetDirectory: String,
        tunFd: Int,
    ): Int

    private external fun nativeIsAlive(pid: Int): Boolean

    private external fun nativeTerminate(pid: Int)
}
