package com.simconsole

import android.os.Handler
import android.os.Looper
import android.view.Choreographer

/**
 * Per-frame sampler that mirrors the iOS `CADisplayLink` FPS pipeline.
 *
 * `Choreographer.postFrameCallback` fires for every frame the system schedules
 * — typically 60 Hz on a phone, 120 Hz on ProMotion-class displays. We
 * accumulate frame counts and hitches over a 1-second window then emit two
 * samples per window:
 *
 *   - `fps.avg_1s`        — frames / second.
 *   - `fps.hitches_1s`    — count of frames whose inter-frame gap exceeded
 *                           ~25 ms (1.5× the 60 Hz nominal). Same threshold
 *                           the iOS sampler uses so cross-platform comparisons
 *                           don't drift.
 *
 * Must run on the main thread because Choreographer is per-Looper. We post the
 * start work to `Handler(Looper.getMainLooper())` so callers don't need to
 * worry about which thread they're on when calling [start].
 */
internal class FpsSampler {

    private val mainHandler = Handler(Looper.getMainLooper())
    private var started = false
    private var frameCount = 0
    private var hitchCount = 0
    private var lastFrameNanos: Long = 0
    private var windowStartNanos: Long = 0

    fun start() {
        mainHandler.post {
            if (started) return@post
            started = true
            Choreographer.getInstance().postFrameCallback(frameCallback)
        }
    }

    fun stop() {
        mainHandler.post {
            if (!started) return@post
            started = false
            Choreographer.getInstance().removeFrameCallback(frameCallback)
        }
    }

    private val frameCallback: Choreographer.FrameCallback = Choreographer.FrameCallback { frameTimeNanos ->
        if (!started) return@FrameCallback

        if (lastFrameNanos > 0L) {
            val gapNanos = frameTimeNanos - lastFrameNanos
            // 16.67 ms × 1.5 ≈ 25 ms; same threshold as iOS.
            if (gapNanos > 25_000_000L) hitchCount++
        }
        lastFrameNanos = frameTimeNanos
        frameCount++

        if (windowStartNanos == 0L) windowStartNanos = frameTimeNanos
        val windowNanos = frameTimeNanos - windowStartNanos
        if (windowNanos >= 1_000_000_000L) {
            val seconds = windowNanos / 1_000_000_000.0
            Metric.sample(name = "fps.avg_1s", value = frameCount / seconds)
            Metric.sample(name = "fps.hitches_1s", value = hitchCount.toDouble())
            frameCount = 0
            hitchCount = 0
            windowStartNanos = frameTimeNanos
        }

        // Re-register; Choreographer FrameCallback is one-shot. `this` inside
        // a SAM-converted lambda refers to the enclosing class, so reference
        // the named property instead.
        Choreographer.getInstance().postFrameCallback(frameCallback)
    }
}
