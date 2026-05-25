package com.simconsole

import android.content.Context
import android.util.Log
import java.util.UUID

/**
 * Entry point for the in-app side of `sim-console` on Android.
 *
 * Routes structured events through `android.util.Log` with stable tags so the
 * companion `sim-console` macOS app — which subscribes to `adb logcat -v threadtime`
 * with a `SimConsole.*:V *:S` filter — can pick them up.
 *
 * The JSON envelope is byte-for-byte compatible with the iOS SDK so the panel
 * parses both platforms with one code path. See [Envelope] for the exact shape.
 *
 * **Debug-only.** Calls become no-ops if `bootstrap` was never invoked or if it
 * was called with `enabled = false`. Don't ship this enabled in a production binary.
 *
 * Typical wiring in an `Application.onCreate()`:
 *
 * ```kotlin
 * if (BuildConfig.DEBUG) {
 *     SimConsole.bootstrap(this, subsystem = BuildConfig.APPLICATION_ID)
 * }
 * ```
 */
object SimConsole {

    enum class Level { Debug, Info, Warn, Error }

    /**
     * Pluggable transport so unit tests can capture emissions without an emulator.
     * Production uses [LogcatSink], which calls into `android.util.Log`.
     */
    internal interface Sink {
        fun emit(tag: String, level: Level, payload: String)
    }

    data class Configuration(
        val subsystem: String,
        val enabled: Boolean = true,
        val maxBodyChars: Int = 800,
    )

    private val lock = Any()
    @Volatile private var configuration: Configuration? = null
    @Volatile internal var sink: Sink = LogcatSink

    private var metricSampler: MetricSampler? = null
    private var fpsSampler: FpsSampler? = null
    private var hangDetector: HangDetector? = null

    /** True iff [bootstrap] has been called with `enabled = true`. */
    val isEnabled: Boolean get() = configuration?.enabled == true

    internal val maxBodyChars: Int get() = configuration?.maxBodyChars ?: 800

    /**
     * Wire the SDK. Idempotent — repeated calls overwrite the config. The
     * `context.applicationContext` is retained for the lifetime of the process
     * so background samplers can query system services without leaking an
     * Activity reference.
     */
    @JvmStatic
    @JvmOverloads
    fun bootstrap(context: Context, subsystem: String, enabled: Boolean = true, maxBodyChars: Int = 800) {
        bootstrap(
            config = Configuration(subsystem = subsystem, enabled = enabled, maxBodyChars = maxBodyChars),
            appContext = context.applicationContext,
        )
    }

    @JvmStatic
    fun bootstrap(config: Configuration) {
        bootstrap(config = config, appContext = null)
    }

    private fun bootstrap(config: Configuration, appContext: Context?) {
        synchronized(lock) {
            configuration = config
            // Anchor launch timing immediately so milestones report from the
            // SDK-load moment if the host never calls Metric.appStartLaunch().
            Metric.processStart
            if (!config.enabled) {
                stopSamplersLocked()
                return
            }
            // Idempotent: don't stack samplers if bootstrap is called again.
            stopSamplersLocked()
            if (appContext != null) {
                metricSampler = MetricSampler(appContext).also { it.start() }
            }
            fpsSampler = FpsSampler().also { it.start() }
            hangDetector = HangDetector().also { it.start() }
        }
    }

    private fun stopSamplersLocked() {
        metricSampler?.stop(); metricSampler = null
        fpsSampler?.stop(); fpsSampler = null
        hangDetector?.stop(); hangDetector = null
    }

    // ---------------------------------------------------------------------
    // Analytics
    // ---------------------------------------------------------------------

    @JvmStatic
    @JvmOverloads
    fun analytics(event: String, params: Map<String, Any?> = emptyMap(), screen: String? = null) {
        if (!isEnabled) return
        val payload = mutableMapOf<String, Any?>(
            "kind" to "analytics",
            "t" to now(),
            "event" to event,
            "params" to Envelope.sanitizeMap(params),
            "screen" to screen,
        )
        emit("SimConsole.analytics", Level.Info, payload)
    }

    @JvmStatic
    @JvmOverloads
    fun screen(name: String, params: Map<String, Any?> = emptyMap()) {
        if (!isEnabled) return
        val payload = mapOf<String, Any?>(
            "kind" to "screen",
            "t" to now(),
            "screen" to name,
            "params" to Envelope.sanitizeMap(params),
        )
        emit("SimConsole.analytics", Level.Info, payload)
    }

    // ---------------------------------------------------------------------
    // Network
    //
    // Three-stage emission per request — mirrors iOS Sources/SimConsole.swift:
    //   1. net.request   — method + URL + headers + body, when the request fires
    //   2. net.response  — status + duration + headers + body, when it returns
    //                      (or net.error if the call failed)
    //   3. net.header / net.body — one envelope per header and one for the body,
    //                      so a single bloated header doesn't truncate the row
    //
    // The panel pairs everything by `id`. Bodies are clipped to maxBodyChars.
    // ---------------------------------------------------------------------

    @JvmStatic
    @JvmOverloads
    fun networkRequest(
        id: String,
        method: String,
        url: String,
        headers: Map<String, String> = emptyMap(),
        body: String? = null,
        mocked: Boolean = false,
    ) {
        if (!isEnabled) return
        val payload = mutableMapOf<String, Any?>(
            "kind" to "net.request",
            "t" to now(),
            "id" to id,
            "method" to method,
            "url" to url,
        )
        if (mocked) payload["mocked"] = true
        emit("SimConsole.network", Level.Info, payload)
        emitHeaders(id, "request", headers)
        emitBody(id, "request", body)
    }

    @JvmStatic
    @JvmOverloads
    fun networkResponse(
        id: String,
        status: Int,
        durationMs: Int,
        headers: Map<String, String> = emptyMap(),
        body: String? = null,
        byteSize: Int? = null,
        mocked: Boolean = false,
    ) {
        if (!isEnabled) return
        val payload = mutableMapOf<String, Any?>(
            "kind" to "net.response",
            "t" to now(),
            "id" to id,
            "status" to status,
            "duration_ms" to durationMs,
        )
        if (byteSize != null) payload["byte_size"] = byteSize
        if (mocked) payload["mocked"] = true
        emit("SimConsole.network", Level.Info, payload)
        emitHeaders(id, "response", headers)
        emitBody(id, "response", body)
    }

    @JvmStatic
    fun networkError(id: String, durationMs: Int, error: String) {
        if (!isEnabled) return
        val payload = mapOf<String, Any?>(
            "kind" to "net.error",
            "t" to now(),
            "id" to id,
            "duration_ms" to durationMs,
            "error" to error,
        )
        emit("SimConsole.network", Level.Warn, payload)
    }

    private fun emitHeaders(id: String, direction: String, headers: Map<String, String>) {
        if (headers.isEmpty()) return
        for ((name, value) in headers) {
            val payload = mapOf<String, Any?>(
                "kind" to "net.header",
                "t" to now(),
                "id" to id,
                "direction" to direction,
                "name" to name,
                "value" to clip(value).orEmpty(),
            )
            emit("SimConsole.network", Level.Info, payload)
        }
    }

    private fun emitBody(id: String, direction: String, body: String?) {
        if (body.isNullOrEmpty()) return
        val payload = mapOf<String, Any?>(
            "kind" to "net.body",
            "t" to now(),
            "id" to id,
            "direction" to direction,
            "body" to clip(body),
        )
        emit("SimConsole.network", Level.Info, payload)
    }

    private fun clip(s: String?): String? {
        if (s.isNullOrEmpty()) return s
        val max = maxBodyChars
        if (s.length <= max) return s
        return s.substring(0, max) + "…[+${s.length - max} chars]"
    }

    // ---------------------------------------------------------------------
    // Generic log
    // ---------------------------------------------------------------------

    @JvmStatic
    @JvmOverloads
    fun log(message: String, level: Level = Level.Info, fields: Map<String, Any?> = emptyMap()) {
        if (!isEnabled) return
        val payload = mapOf<String, Any?>(
            "kind" to "log",
            "t" to now(),
            "level" to level.toWire(),
            "msg" to message,
            "fields" to Envelope.sanitizeMap(fields),
        )
        emit("SimConsole.event", level, payload)
    }

    // ---------------------------------------------------------------------
    // Internal emission path
    // ---------------------------------------------------------------------

    /** Used by [Metric] (separate file, same package). Pinned to `Level.Info`. */
    internal fun emitMetric(payload: Map<String, Any?>) {
        emit("SimConsole.metric", Level.Info, payload)
    }

    private fun emit(tag: String, level: Level, payload: Map<String, Any?>) {
        val json = Envelope.encode(payload)
        if (!LogChunker.isOversized(json)) {
            sink.emit(tag, level, json)
            return
        }
        val id = UUID.randomUUID().toString()
        for (chunk in LogChunker.chunk(id, json)) {
            sink.emit("$tag.chunk", level, chunk)
        }
    }

    private fun now(): Double = System.currentTimeMillis() / 1000.0

    private fun Level.toWire(): String = when (this) {
        Level.Debug -> "debug"
        Level.Info -> "info"
        Level.Warn -> "warn"
        Level.Error -> "error"
    }

    /** Default sink — writes to `android.util.Log`. */
    private object LogcatSink : Sink {
        override fun emit(tag: String, level: Level, payload: String) {
            when (level) {
                Level.Debug -> Log.d(tag, payload)
                Level.Info -> Log.i(tag, payload)
                Level.Warn -> Log.w(tag, payload)
                Level.Error -> Log.e(tag, payload)
            }
        }
    }
}
