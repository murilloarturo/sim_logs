package com.simconsole

import android.content.Context
import android.os.BatteryManager
import android.os.Build
import android.os.Debug
import android.os.PowerManager
import java.io.File
import java.util.concurrent.Executors
import java.util.concurrent.ScheduledExecutorService
import java.util.concurrent.TimeUnit

/**
 * Periodically samples memory / CPU / thermal / battery and emits via
 * [Metric.sample] using iOS-compatible metric names so the panel renders
 * both platforms in the same Metrics tab.
 *
 * Runs on a single background thread at 1 Hz. The host-app main thread is
 * untouched (everything queried here works off-main: `Debug.getMemoryInfo`,
 * `/proc/self/stat`, `BatteryManager`, `PowerManager.currentThermalStatus`).
 */
internal class MetricSampler(private val appContext: Context) {

    private val executor: ScheduledExecutorService = Executors.newSingleThreadScheduledExecutor { r ->
        Thread(r, "SimConsole.metric-sampler").apply { isDaemon = true }
    }
    private var peakResidentMb: Double = 0.0
    private var lastCpu: CpuSnapshot? = null

    fun start(intervalMs: Long = 1_000L) {
        executor.scheduleAtFixedRate(::tick, intervalMs, intervalMs, TimeUnit.MILLISECONDS)
    }

    fun stop() {
        executor.shutdownNow()
    }

    private fun tick() {
        // Each sampler is wrapped — one slow probe (rare) shouldn't break the others.
        runCatching { sampleMemory() }
        runCatching { sampleCpu() }
        runCatching { sampleThermal() }
        runCatching { sampleBattery() }
    }

    // ---------------------------------------------------------------------
    // Memory — Debug.getMemoryInfo().totalPss is "actual" memory the process is
    // costing the device (proportional set size, shared pages accounted for).
    // ---------------------------------------------------------------------

    private fun sampleMemory() {
        val info = Debug.MemoryInfo()
        Debug.getMemoryInfo(info)
        // totalPss is in KB.
        val mb = info.totalPss / 1024.0
        Metric.sample(name = "memory.resident_mb", value = mb)
        if (mb > peakResidentMb) {
            peakResidentMb = mb
            Metric.sample(name = "memory.peak_mb", value = peakResidentMb)
        }
    }

    // ---------------------------------------------------------------------
    // CPU — /proc/self/stat fields 14 (utime) + 15 (stime) in clock ticks.
    // The user-jiffy rate is ~100 Hz on most Android kernels but isn't
    // queryable without JNI. We compute percent against the wall-clock delta
    // assuming HZ=100, which matches what `top` and Android Studio's profiler
    // do. Off by a constant factor on weirdly-configured kernels but the
    // *relative* movement of the metric (the bit that matters for debugging)
    // is correct.
    // ---------------------------------------------------------------------

    private data class CpuSnapshot(val ticks: Long, val nanos: Long)

    private fun sampleCpu() {
        val now = readCpuTicks() ?: return
        val prev = lastCpu
        lastCpu = now
        if (prev == null) return
        val tickDelta = now.ticks - prev.ticks
        val wallSeconds = (now.nanos - prev.nanos) / 1_000_000_000.0
        if (wallSeconds <= 0.0) return
        // Assume HZ=100 (clock_t = 1/100s). Percent of one CPU core.
        val cpuSeconds = tickDelta / 100.0
        val percent = (cpuSeconds / wallSeconds) * 100.0
        Metric.sample(name = "cpu.process_pct", value = percent)
    }

    private fun readCpuTicks(): CpuSnapshot? {
        return try {
            val raw = File("/proc/self/stat").readText()
            // /proc/self/stat columns are space-separated, but field 2 is the
            // executable name in parens (may itself contain spaces). Skip past
            // the closing paren before tokenizing the rest.
            val close = raw.lastIndexOf(')')
            if (close < 0) return null
            val tokens = raw.substring(close + 2).split(' ')
            // After (comm) the indices reset: tokens[0] = state, so utime = tokens[11], stime = tokens[12].
            // (Linux /proc/stat docs index from 1 with comm being col 2, so col 14/15 minus the
            // two-column shift = our [11]/[12].)
            val utime = tokens[11].toLong()
            val stime = tokens[12].toLong()
            CpuSnapshot(ticks = utime + stime, nanos = System.nanoTime())
        } catch (_: Throwable) {
            null
        }
    }

    // ---------------------------------------------------------------------
    // Thermal — PowerManager.getCurrentThermalStatus is API 29+. Older
    // devices skip this entirely (parity with iOS, which doesn't have a
    // pre-iOS-11 fallback either).
    // ---------------------------------------------------------------------

    private fun sampleThermal() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) return
        val pm = appContext.getSystemService(Context.POWER_SERVICE) as? PowerManager ?: return
        val status = pm.currentThermalStatus
        Metric.sample(
            name = "thermal",
            value = status.toDouble(),
            fields = mapOf("state" to thermalLabel(status)),
        )
    }

    private fun thermalLabel(status: Int): String = when (status) {
        // Constants from android.os.PowerManager (THERMAL_STATUS_*).
        0 -> "none"
        1 -> "light"
        2 -> "moderate"
        3 -> "severe"
        4 -> "critical"
        5 -> "emergency"
        6 -> "shutdown"
        else -> "unknown"
    }

    // ---------------------------------------------------------------------
    // Battery
    // ---------------------------------------------------------------------

    private fun sampleBattery() {
        val bm = appContext.getSystemService(Context.BATTERY_SERVICE) as? BatteryManager ?: return
        val capacity = bm.getIntProperty(BatteryManager.BATTERY_PROPERTY_CAPACITY)
        if (capacity in 0..100) {
            // iOS reports 0..1; match the scale so panel renderers don't branch.
            Metric.sample(name = "battery.level", value = capacity / 100.0)
        }
        val status = bm.getIntProperty(BatteryManager.BATTERY_PROPERTY_STATUS)
        val charging = status == BatteryManager.BATTERY_STATUS_CHARGING ||
            status == BatteryManager.BATTERY_STATUS_FULL
        Metric.sample(name = "battery.charging", value = if (charging) 1.0 else 0.0)
    }
}
