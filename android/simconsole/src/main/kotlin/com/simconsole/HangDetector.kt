package com.simconsole

import android.os.Handler
import android.os.HandlerThread
import android.os.Looper

/**
 * Detects main-thread stalls and emits `metric.hang` envelopes. Mirrors the
 * iOS HangDetector behavior: every [PROBE_INTERVAL_MS] a background thread
 * posts a no-op Runnable to the main `Handler`. If [HANG_THRESHOLD_MS] elapses
 * before the main thread runs that probe, the difference is reported.
 *
 * The threshold matches iOS (250 ms). ANR territory on Android is 5 s, so 250
 * ms is *much* tighter — that's intentional, it catches user-perceptible jank
 * long before the system would react.
 */
internal class HangDetector {

    private val mainHandler = Handler(Looper.getMainLooper())
    private val workerThread = HandlerThread("SimConsole.hang-detector").apply {
        isDaemon = true
    }
    private lateinit var workerHandler: Handler
    @Volatile private var running = false

    @Volatile private var lastProbePostedAt: Long = 0
    @Volatile private var lastProbeRanAt: Long = 0

    fun start() {
        if (running) return
        running = true
        workerThread.start()
        workerHandler = Handler(workerThread.looper)
        lastProbeRanAt = System.currentTimeMillis()
        workerHandler.post(probeLoop)
    }

    fun stop() {
        running = false
        workerHandler.removeCallbacksAndMessages(null)
        workerThread.quitSafely()
    }

    private val probeLoop: Runnable = object : Runnable {
        override fun run() {
            if (!running) return
            val now = System.currentTimeMillis()

            // If the last probe hasn't returned and it's been > threshold, report
            // the in-flight stall now. Otherwise the user has to wait for the
            // main thread to recover before we see anything — too late.
            val sinceLastReturn = now - lastProbeRanAt
            if (sinceLastReturn > HANG_THRESHOLD_MS && lastProbePostedAt > lastProbeRanAt) {
                Metric.hang(durationMs = sinceLastReturn.toInt())
                // Treat this probe as "satisfied" so we don't double-report the
                // same stall on every poll cycle.
                lastProbeRanAt = now
            }

            lastProbePostedAt = now
            mainHandler.post {
                lastProbeRanAt = System.currentTimeMillis()
            }
            workerHandler.postDelayed(this, PROBE_INTERVAL_MS)
        }
    }

    companion object {
        private const val PROBE_INTERVAL_MS = 50L
        private const val HANG_THRESHOLD_MS = 250L
    }
}
