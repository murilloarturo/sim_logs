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

    /** True iff [bootstrap] has been called with `enabled = true`. */
    val isEnabled: Boolean get() = configuration?.enabled == true

    internal val maxBodyChars: Int get() = configuration?.maxBodyChars ?: 800

    /**
     * Wire the SDK. Idempotent — repeated calls overwrite the config. The `context`
     * arg is reserved for future phases (mock-file path resolution, ContentResolver
     * lookups) and not currently used.
     */
    @JvmStatic
    @JvmOverloads
    fun bootstrap(context: Context, subsystem: String, enabled: Boolean = true, maxBodyChars: Int = 800) {
        bootstrap(Configuration(subsystem = subsystem, enabled = enabled, maxBodyChars = maxBodyChars))
    }

    @JvmStatic
    fun bootstrap(config: Configuration) {
        synchronized(lock) {
            configuration = config
        }
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
