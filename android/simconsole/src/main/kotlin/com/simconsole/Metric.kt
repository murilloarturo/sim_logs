package com.simconsole

import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.atomic.AtomicReference

/**
 * Performance + custom-metric API. Mirrors the iOS `Metric` surface so the
 * panel and MCP server render Android samples through the exact same parser.
 *
 * Two emission layers:
 *   1. Auto-sampled system metrics ([MetricSampler], [FpsSampler], [HangDetector])
 *      started by [SimConsole.bootstrap]. Run on background threads except FPS
 *      which has to live on the main thread (`Choreographer`).
 *   2. App-marked metrics (this surface) — explicit calls from the host app
 *      at meaningful points (launch milestones, custom signposts, gauges).
 *
 * Both flow through [SimConsole.emit] under the `SimConsole.metric` logcat tag
 * so chunking + transport stay centralized. DEBUG builds only.
 */
object Metric {

    /**
     * Captured at first access — usually when [SimConsole.bootstrap] is called.
     * Drives `ms_since_launch` for milestones when [appStartLaunch] hasn't been
     * explicitly invoked. Close enough for dev work: bootstrap is the right
     * place to anchor since it's invoked in `Application.onCreate`.
     */
    val processStart: Long by lazy { System.currentTimeMillis() }

    private val launchStart = AtomicReference<Long?>(null)
    private val launchEmitted = AtomicReference(false)
    private val counters = ConcurrentHashMap<String, Double>()

    // ---------------------------------------------------------------------
    // Launch (canonical two-event API)
    // ---------------------------------------------------------------------

    /**
     * Anchors the start of the app's cold-launch measurement. **First call wins.**
     * Call at the earliest moment in `Application.onCreate` — typically right
     * after [SimConsole.bootstrap]. If never called, [appFinishLaunching] falls
     * back to [processStart].
     */
    @JvmStatic
    fun appStartLaunch() {
        launchStart.compareAndSet(null, System.currentTimeMillis())
    }

    /**
     * Emits the canonical `metric.launch` event with elapsed milliseconds from
     * [appStartLaunch] (or [processStart] if absent) to now. **Idempotent** —
     * subsequent calls are no-ops, so it's safe to drop in a root view's first-
     * resume / first-content-loaded callback that may fire repeatedly.
     */
    @JvmStatic
    fun appFinishLaunching() {
        if (!launchEmitted.compareAndSet(false, true)) return
        val anchor = launchStart.get() ?: processStart
        val ms = (System.currentTimeMillis() - anchor).toInt()
        emit(mapOf("kind" to "metric.launch", "ms" to ms))
    }

    // ---------------------------------------------------------------------
    // Milestones
    // ---------------------------------------------------------------------

    /**
     * Records an intermediate named milestone in the launch timeline (e.g.
     * "auth_ready", "feed_loaded"). Distinct from the canonical [appFinishLaunching]
     * endpoint — use these to attribute time *between* checkpoints.
     */
    @JvmStatic
    @JvmOverloads
    fun launchMilestone(name: String, fields: Map<String, Any?> = emptyMap()) {
        val anchor = launchStart.get() ?: processStart
        val ms = (System.currentTimeMillis() - anchor).toInt()
        emit(
            mapOf(
                "kind" to "metric.milestone",
                "name" to name,
                "ms_since_launch" to ms,
                "fields" to Envelope.sanitizeMap(fields),
            ),
        )
    }

    // ---------------------------------------------------------------------
    // Signposts
    // ---------------------------------------------------------------------

    @JvmStatic
    @JvmOverloads
    fun signpost(name: String, durationMs: Int, fields: Map<String, Any?> = emptyMap()) {
        emit(
            mapOf(
                "kind" to "metric.signpost",
                "name" to name,
                "duration_ms" to durationMs,
                "fields" to Envelope.sanitizeMap(fields),
            ),
        )
    }

    /**
     * Times a synchronous block and emits a signpost when it returns. Returns
     * whatever the block returned so call-sites stay clean.
     */
    @JvmStatic
    @JvmOverloads
    inline fun <T> measure(name: String, fields: Map<String, Any?> = emptyMap(), body: () -> T): T {
        val start = System.currentTimeMillis()
        val result = body()
        val ms = (System.currentTimeMillis() - start).toInt()
        signpost(name, ms, fields)
        return result
    }

    // ---------------------------------------------------------------------
    // Gauges + counters
    // ---------------------------------------------------------------------

    @JvmStatic
    @JvmOverloads
    fun gauge(name: String, value: Double, fields: Map<String, Any?> = emptyMap()) {
        emit(
            mapOf(
                "kind" to "metric.gauge",
                "name" to name,
                "value" to value,
                "fields" to Envelope.sanitizeMap(fields),
            ),
        )
    }

    /**
     * Increments a named counter. The wire payload includes both `delta` and
     * the running `total` so the dashboard doesn't have to reduce on the read
     * side. Counters reset on process restart.
     */
    @JvmStatic
    @JvmOverloads
    fun counter(name: String, increment: Double = 1.0, fields: Map<String, Any?> = emptyMap()) {
        val total = counters.compute(name) { _, current -> (current ?: 0.0) + increment }!!
        emit(
            mapOf(
                "kind" to "metric.counter",
                "name" to name,
                "delta" to increment,
                "total" to total,
                "fields" to Envelope.sanitizeMap(fields),
            ),
        )
    }

    // ---------------------------------------------------------------------
    // Internal — used by MetricSampler / FpsSampler / HangDetector
    // ---------------------------------------------------------------------

    @JvmStatic
    internal fun sample(name: String, value: Double, fields: Map<String, Any?> = emptyMap()) {
        emit(
            mapOf(
                "kind" to "metric.sample",
                "name" to name,
                "value" to value,
                "fields" to Envelope.sanitizeMap(fields),
            ),
        )
    }

    @JvmStatic
    internal fun hang(durationMs: Int) {
        emit(mapOf("kind" to "metric.hang", "duration_ms" to durationMs))
    }

    @JvmStatic
    @PublishedApi
    internal fun emit(partial: Map<String, Any?>) {
        if (!SimConsole.isEnabled) return
        val payload = partial.toMutableMap().apply { put("t", System.currentTimeMillis() / 1000.0) }
        SimConsole.emitMetric(payload)
    }
}
