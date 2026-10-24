package dev.nozelt.nozelt

import android.content.Context
import android.os.SystemClock
import org.json.JSONArray
import org.json.JSONObject
import java.io.BufferedInputStream
import java.io.BufferedOutputStream
import java.net.IDN
import java.net.InetAddress
import java.net.InetSocketAddress
import java.net.ServerSocket
import java.net.Socket
import java.net.SocketTimeoutException
import java.net.URI
import java.nio.charset.StandardCharsets
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import java.util.concurrent.TimeoutException
import java.util.concurrent.atomic.AtomicLong
import javax.net.ssl.SSLSocket
import javax.net.ssl.SSLSocketFactory
import kotlin.math.min

/**
 * Tests Xray and sing-box nodes with the same executable and configuration
 * that carry VPN traffic. Each short-lived core exposes only a loopback SOCKS
 * inbound; the HTTP probe then traverses the provider's real outbound,
 * routing, balancer and transport implementation without translating it to a
 * different core.
 */
internal object NativeCoreDelayTester {
    private const val MAX_TARGETS = 4096
    // Every worker owns a complete short-lived Xray/sing-box process. A large
    // subscription must not start enough cores at once to exhaust Android's
    // memory/file-descriptor budget and make every otherwise healthy node
    // fail. AUTO targets can start observatory workers of their own, so four
    // top-level cores are the highest reliable value on mid-range phones.
    private const val MAX_WORKERS = 4
    private const val MIN_RUN_TIMEOUT_MS = 20_000L
    private const val MAX_RUN_TIMEOUT_MS = 60_000L
    private const val MAX_CONFIG_BYTES = 16 * 1024 * 1024
    private const val MAX_RESPONSE_HEADERS = 32 * 1024
    private val fallbackProbeUrls = listOf(
        "http://cp.cloudflare.com/generate_204",
        "http://connectivitycheck.gstatic.com/generate_204",
        "http://captive.apple.com/hotspot-detect.html",
    )
    private val loopbackIpv4 = InetAddress.getByName("127.0.0.1")
    private val generation = AtomicLong(0L)
    private val nextRunId = AtomicLong(0L)
    private val activeProbeRuns = ConcurrentHashMap<
        Long,
        ConcurrentHashMap<Int, NativeCoreProcess.ProbeHandle>,
        >()
    private val activeExecutors =
        ConcurrentHashMap<Long, java.util.concurrent.ExecutorService>()

    fun test(
        context: Context,
        core: VpnCore,
        targetsJson: String,
        timeoutMs: Int,
        onResult: ((name: String, delay: Int?) -> Unit)? = null,
    ): String {
        require(core != VpnCore.MIHOMO) { "native delay tester requires a native core" }
        // A node-level check and a profile-wide check are independent UI
        // operations. Starting either one must never cancel the other.
        // [generation] changes only on an explicit lifecycle cancellation.
        val runGeneration = generation.get()
        val runId = nextRunId.incrementAndGet()
        val targets = parseTargets(targetsJson)
        if (targets.isEmpty()) return envelope(emptyMap())
        val timeout = timeoutMs.coerceIn(500, 30_000)
        val pool = Executors.newFixedThreadPool(min(MAX_WORKERS, targets.size)) { runnable ->
            Thread(runnable, "nozelt-${core.wireName}-probe").apply { isDaemon = true }
        }
        val runProbes = ConcurrentHashMap<Int, NativeCoreProcess.ProbeHandle>()
        activeExecutors[runId] = pool
        activeProbeRuns[runId] = runProbes
        return try {
            val futures = targets.associateWith { target ->
                pool.submit<ProbeResult> {
                    val probed =
                        if (
                            generation.get() != runGeneration ||
                            Thread.currentThread().isInterrupted
                        ) {
                        ProbeResult(error = "cancelled")
                    } else {
                        probe(
                            context.applicationContext,
                            core,
                            target,
                            timeout,
                            runGeneration,
                            runProbes,
                        )
                    }
                    runCatching { onResult?.invoke(target.name, probed.delay) }
                    probed
                }
            }
            val results = linkedMapOf<String, ProbeResult>()
            val workerCount = min(MAX_WORKERS, targets.size)
            val batches = (targets.size + workerCount - 1) / workerCount
            val runTimeoutMs = (batches * 6_000L).coerceIn(
                MIN_RUN_TIMEOUT_MS,
                MAX_RUN_TIMEOUT_MS,
            )
            val deadline = SystemClock.elapsedRealtime() + runTimeoutMs
            for ((target, future) in futures) {
                val remaining = deadline - SystemClock.elapsedRealtime()
                results[target.name] = if (remaining <= 0L && !future.isDone) {
                    future.cancel(true)
                    ProbeResult(error = "timeout")
                } else {
                    try {
                        if (future.isDone) future.get() else future.get(remaining, TimeUnit.MILLISECONDS)
                    } catch (_: TimeoutException) {
                        future.cancel(true)
                        ProbeResult(error = "timeout")
                    } catch (_: Throwable) {
                        ProbeResult(error = "proxy test failed")
                    }
                }
            }
            envelope(results)
        } finally {
            pool.shutdownNow()
            stopRunProbes(runProbes)
            runCatching { pool.awaitTermination(2, TimeUnit.SECONDS) }
            activeExecutors.remove(runId, pool)
            activeProbeRuns.remove(runId, runProbes)
        }
    }

    fun cancel() {
        generation.incrementAndGet()
        for ((runId, executor) in activeExecutors.entries.toList()) {
            if (activeExecutors.remove(runId, executor)) {
                executor.shutdownNow()
            }
        }
        for (probes in activeProbeRuns.values.toList()) {
            stopRunProbes(probes)
        }
    }

    private fun stopRunProbes(
        probes: ConcurrentHashMap<Int, NativeCoreProcess.ProbeHandle>,
    ) {
        for (handle in probes.values.toList()) {
            if (probes.remove(handle.pid, handle)) {
                runCatching { NativeCoreProcess.stopProbe(handle) }
            }
        }
    }

    private fun probe(
        context: Context,
        core: VpnCore,
        target: ProbeTarget,
        timeoutMs: Int,
        runGeneration: Long,
        runProbes: ConcurrentHashMap<Int, NativeCoreProcess.ProbeHandle>,
    ): ProbeResult {
        val port = ServerSocket(0, 1, loopbackIpv4).use { it.localPort }
        // Any app can reach a loopback port, so each probe gets its own
        // random SOCKS account instead of an open proxy.
        val credentials = SocksCredentials.random()
        val config = buildProbeConfig(core, target.config, port, credentials)
        var handle: NativeCoreProcess.ProbeHandle? = null
        return try {
            handle = NativeCoreProcess.startProbe(context, core, config)
            runProbes[handle.pid] = handle
            if (!waitUntilListening(handle, port, runGeneration)) {
                preserveDebugLog(context, handle)
                return ProbeResult(error = "core startup failed")
            }
            if (generation.get() != runGeneration) return ProbeResult(error = "cancelled")
            val delay = measureThroughSocks(port, target.url, timeoutMs, credentials)
            ProbeResult(delay = delay)
        } catch (_: InterruptedException) {
            Thread.currentThread().interrupt()
            ProbeResult(error = "cancelled")
        } catch (failure: Throwable) {
            handle?.let { preserveDebugLog(context, it, failure) }
            ProbeResult(error = "proxy test failed")
        } finally {
            handle?.let {
                if (runProbes.remove(it.pid, it)) {
                    runCatching { NativeCoreProcess.stopProbe(it) }
                }
            }
        }
    }

    private fun preserveDebugLog(
        context: Context,
        handle: NativeCoreProcess.ProbeHandle,
        failure: Throwable? = null,
    ) {
        if (!BuildConfig.DEBUG) return
        runCatching {
            val output = java.io.File(
                context.noBackupFilesDir,
                "runtime/last-native-probe.log",
            )
            output.parentFile?.mkdirs()
            output.writeText(
                buildString {
                    append(handle.logFile.readText().takeLast(64 * 1024))
                    if (failure != null) {
                        append("\nNOZELT FAILURE ")
                        append(failure::class.java.simpleName)
                        append(": ")
                        append(failure.message.orEmpty().take(2048))
                    }
                },
            )
        }
    }

    private fun waitUntilListening(
        handle: NativeCoreProcess.ProbeHandle,
        port: Int,
        runGeneration: Long,
    ): Boolean {
        val deadline = SystemClock.elapsedRealtime() + 2_000L
        while (SystemClock.elapsedRealtime() < deadline) {
            if (generation.get() != runGeneration || Thread.currentThread().isInterrupted) {
                return false
            }
            if (!NativeCoreProcess.isProbeRunning(handle)) return false
            try {
                Socket().use { socket ->
                    socket.connect(InetSocketAddress(loopbackIpv4, port), 100)
                    return true
                }
            } catch (_: Throwable) {
                Thread.sleep(25L)
            }
        }
        return false
    }

    private class SocksCredentials(val user: String, val password: String) {
        companion object {
            private val random = java.security.SecureRandom()

            fun random(): SocksCredentials {
                fun token(): String {
                    val bytes = ByteArray(12)
                    random.nextBytes(bytes)
                    return bytes.joinToString("") { "%02x".format(it) }
                }
                return SocksCredentials(token(), token())
            }
        }
    }

    private fun buildProbeConfig(
        core: VpnCore,
        rawConfig: String,
        port: Int,
        credentials: SocksCredentials,
    ): String {
        check(rawConfig.toByteArray(Charsets.UTF_8).size <= MAX_CONFIG_BYTES) {
            "native probe configuration is too large"
        }
        val document = JSONObject(rawConfig)
        when (core) {
            VpnCore.XRAY -> {
                document.put(
                    "inbounds",
                    JSONArray().put(
                        JSONObject()
                            .put("tag", "nozelt-probe")
                            .put("listen", "127.0.0.1")
                            .put("port", port)
                            .put("protocol", "socks")
                            .put(
                                "settings",
                                JSONObject()
                                    .put("auth", "password")
                                    .put(
                                        "accounts",
                                        JSONArray().put(
                                            JSONObject()
                                                .put("user", credentials.user)
                                                .put("pass", credentials.password),
                                        ),
                                    )
                                    .put("udp", false),
                            ),
                    ),
                )
                document.put("log", JSONObject().put("loglevel", "warning"))
            }
            VpnCore.SING_BOX -> {
                document.put(
                    "inbounds",
                    JSONArray().put(
                        JSONObject()
                            .put("type", "socks")
                            .put("tag", "nozelt-probe")
                            .put("listen", "127.0.0.1")
                            .put("listen_port", port)
                            .put(
                                "users",
                                JSONArray().put(
                                    JSONObject()
                                        .put("username", credentials.user)
                                        .put("password", credentials.password),
                                ),
                            ),
                    ),
                )
                document.put(
                    "log",
                    JSONObject()
                        .put("level", "warn")
                        .put("timestamp", false),
                )
            }
            VpnCore.MIHOMO -> error("unreachable")
        }
        return document.toString()
    }

    /**
     * Nozelt's core-independent delay definition:
     *
     *  1. establish the core's real proxy path and issue a HEAD request;
     *  2. repeat the same request over the established HTTP connection;
     *  3. report the warm request, or the first request when the peer closes
     *     keep-alive.
     *
     * This excludes one-time core/TLS setup when possible and matches the
     * value users perceive on an already-connected VPN. Any syntactically
     * valid HTTP response proves reachability; whitelist gateways may return
     * a non-2xx status for public connectivity endpoints. One candidate
     * already performs both cold and warm HTTP exchanges; after it succeeds,
     * repeating the whole pair only doubles the healthy-node latency without
     * adding meaningful confidence. Failed candidates still rotate through
     * independent endpoints and retry the subscription endpoint.
     */
    private fun measureThroughSocks(
        localPort: Int,
        rawUrl: String,
        timeoutMs: Int,
        credentials: SocksCredentials,
    ): Int {
        var lastFailure = null as Throwable?
        val attemptTimeout = timeoutMs.coerceIn(500, 2_500)
        for (candidate in probeUrls(rawUrl)) {
            if (Thread.currentThread().isInterrupted) throw InterruptedException()
            try {
                return measureThroughSocksOnce(localPort, candidate, attemptTimeout, credentials)
            } catch (failure: Throwable) {
                if (failure is InterruptedException) throw failure
                lastFailure = failure
            }
        }
        throw lastFailure ?: IllegalStateException("all delay probes failed")
    }

    private fun probeUrls(rawUrl: String): List<String> {
        val unique = linkedSetOf(rawUrl)
        unique.addAll(fallbackProbeUrls)
        val values = unique.toList()
        if (values.size == 1) return listOf(values.first(), values.first())
        return buildList {
            add(values[0])
            add(values[1])
            add(values[0])
            if (values.size > 2) add(values[2])
        }
    }

    private fun measureThroughSocksOnce(
        localPort: Int,
        rawUrl: String,
        timeoutMs: Int,
        credentials: SocksCredentials,
    ): Int {
        val uri = URI(rawUrl)
        val scheme = uri.scheme?.lowercase()
        require(scheme == "http" || scheme == "https") { "unsupported probe URL" }
        val host = IDN.toASCII(uri.host ?: error("probe URL host is missing"))
        require(host.toByteArray(StandardCharsets.US_ASCII).size <= 255) {
            "probe URL host is too long"
        }
        val remotePort = if (uri.port > 0) uri.port else if (scheme == "https") 443 else 80
        val tcp = Socket()
        val deadline = SystemClock.elapsedRealtime() + timeoutMs
        try {
            val coldStarted = SystemClock.elapsedRealtime()
            tcp.soTimeout = remainingTimeout(deadline)
            tcp.connect(InetSocketAddress(loopbackIpv4, localPort), remainingTimeout(deadline))
            negotiateSocks5(tcp, host, remotePort, deadline, credentials)
            val transport = if (scheme == "https") {
                val tls = (SSLSocketFactory.getDefault() as SSLSocketFactory)
                    .createSocket(tcp, host, remotePort, true) as SSLSocket
                tls.soTimeout = remainingTimeout(deadline)
                tls.sslParameters = tls.sslParameters.apply {
                    endpointIdentificationAlgorithm = "HTTPS"
                }
                tls.startHandshake()
                tls
            } else {
                tcp
            }
            val path = buildString {
                append(if (uri.rawPath.isNullOrEmpty()) "/" else uri.rawPath)
                if (!uri.rawQuery.isNullOrEmpty()) append('?').append(uri.rawQuery)
            }
            val output = BufferedOutputStream(transport.getOutputStream())
            val input = BufferedInputStream(transport.getInputStream())
            transport.soTimeout = remainingTimeout(deadline)
            writeHeadRequest(output, path, host, remotePort, scheme, close = false)
            readStatus(input, transport, deadline)
            val coldDelay = elapsedDelay(coldStarted)

            return try {
                val warmStarted = SystemClock.elapsedRealtime()
                transport.soTimeout = remainingTimeout(deadline)
                writeHeadRequest(output, path, host, remotePort, scheme, close = true)
                readStatus(input, transport, deadline)
                elapsedDelay(warmStarted)
            } catch (_: Exception) {
                coldDelay
            }
        } finally {
            runCatching { tcp.close() }
        }
    }

    private fun writeHeadRequest(
        output: BufferedOutputStream,
        path: String,
        host: String,
        port: Int,
        scheme: String,
        close: Boolean,
    ) {
        val defaultPort = if (scheme == "https") 443 else 80
        val authority = if (port == defaultPort) host else "$host:$port"
        output.write(
            (
                "HEAD $path HTTP/1.1\r\n" +
                    "Host: $authority\r\n" +
                    "User-Agent: Nozelt/1.0\r\n" +
                    "Accept: */*\r\n" +
                    "Connection: ${if (close) "close" else "keep-alive"}\r\n\r\n"
                ).toByteArray(StandardCharsets.US_ASCII),
        )
        output.flush()
    }

    private fun elapsedDelay(started: Long): Int =
        (SystemClock.elapsedRealtime() - started)
            .coerceAtLeast(1L)
            .coerceAtMost(Int.MAX_VALUE.toLong())
            .toInt()

    private fun negotiateSocks5(
        socket: Socket,
        host: String,
        port: Int,
        deadline: Long,
        credentials: SocksCredentials,
    ) {
        val input = BufferedInputStream(socket.getInputStream())
        val output = BufferedOutputStream(socket.getOutputStream())
        output.write(byteArrayOf(5, 1, 2))
        output.flush()
        socket.soTimeout = remainingTimeout(deadline)
        val greeting = readExact(input, 2)
        check(greeting[0].toInt() == 5 && greeting[1].toInt() == 2) {
            "SOCKS authentication failed"
        }
        // RFC 1929 username/password sub-negotiation.
        val user = credentials.user.toByteArray(StandardCharsets.US_ASCII)
        val password = credentials.password.toByteArray(StandardCharsets.US_ASCII)
        output.write(byteArrayOf(1, user.size.toByte()))
        output.write(user)
        output.write(byteArrayOf(password.size.toByte()))
        output.write(password)
        output.flush()
        socket.soTimeout = remainingTimeout(deadline)
        val authReply = readExact(input, 2)
        check(authReply[0].toInt() == 1 && authReply[1].toInt() == 0) {
            "SOCKS authentication failed"
        }
        val hostBytes = host.toByteArray(StandardCharsets.US_ASCII)
        output.write(byteArrayOf(5, 1, 0, 3, hostBytes.size.toByte()))
        output.write(hostBytes)
        output.write(byteArrayOf((port ushr 8).toByte(), port.toByte()))
        output.flush()

        socket.soTimeout = remainingTimeout(deadline)
        val reply = readExact(input, 4)
        check(reply[0].toInt() == 5 && reply[1].toInt() == 0) {
            "SOCKS connection failed"
        }
        val addressLength = when (reply[3].toInt() and 0xff) {
            1 -> 4
            3 -> readExact(input, 1)[0].toInt() and 0xff
            4 -> 16
            else -> error("invalid SOCKS address")
        }
        readExact(input, addressLength + 2)
    }

    private fun readStatus(input: BufferedInputStream, socket: Socket, deadline: Long): Int {
        val header = ArrayList<Byte>()
        var matched = 0
        val marker = byteArrayOf(13, 10, 13, 10)
        while (header.size < MAX_RESPONSE_HEADERS && matched < marker.size) {
            socket.soTimeout = remainingTimeout(deadline)
            val next = input.read()
            check(next >= 0) { "unexpected end of HTTP response" }
            val byte = next.toByte()
            header.add(byte)
            matched = if (byte == marker[matched]) matched + 1 else if (byte == marker[0]) 1 else 0
        }
        check(matched == marker.size) { "HTTP response headers are too large" }
        val firstLine = String(header.toByteArray(), StandardCharsets.ISO_8859_1)
            .lineSequence()
            .first()
        return firstLine.split(' ').getOrNull(1)?.toIntOrNull()
            ?: error("invalid HTTP status")
    }

    private fun remainingTimeout(deadline: Long): Int {
        val remaining = deadline - SystemClock.elapsedRealtime()
        if (remaining <= 0L) throw SocketTimeoutException("delay probe timed out")
        return remaining.coerceAtMost(Int.MAX_VALUE.toLong()).toInt()
    }

    private fun readExact(input: BufferedInputStream, length: Int): ByteArray {
        val result = ByteArray(length)
        var offset = 0
        while (offset < length) {
            val count = input.read(result, offset, length - offset)
            check(count > 0) { "unexpected end of SOCKS response" }
            offset += count
        }
        return result
    }

    private fun parseTargets(value: String): List<ProbeTarget> {
        val array = JSONArray(value)
        require(array.length() <= MAX_TARGETS) { "too many native delay targets" }
        val names = mutableSetOf<String>()
        return List(array.length()) { index ->
            val item = array.getJSONObject(index)
            val name = item.getString("name")
            require(name.isNotBlank() && names.add(name)) { "invalid native delay target name" }
            val url = URI(item.getString("url"))
            require(
                (url.scheme.equals("http", true) || url.scheme.equals("https", true)) &&
                    !url.host.isNullOrBlank() &&
                    url.userInfo == null,
            ) {
                "invalid native delay target URL"
            }
            ProbeTarget(name, item.getString("config"), url.toString())
        }
    }

    private fun envelope(results: Map<String, ProbeResult>): String {
        val rendered = JSONObject()
        for ((name, result) in results) {
            val item = JSONObject()
            if (result.delay != null) item.put("delay", result.delay)
            if (result.error != null) item.put("error", result.error)
            rendered.put(name, item)
        }
        return JSONObject()
            .put("ok", true)
            .put("results", rendered)
            .toString()
    }

    private data class ProbeTarget(
        val name: String,
        val config: String,
        val url: String,
    )

    private data class ProbeResult(
        val delay: Int? = null,
        val error: String? = null,
    )
}
