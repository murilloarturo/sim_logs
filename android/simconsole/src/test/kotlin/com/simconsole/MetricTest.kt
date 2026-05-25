package com.simconsole

import org.json.JSONObject
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test

/**
 * Covers the host-callable Metric API. Sampler classes (memory / CPU / FPS /
 * hang) require Android framework primitives (Choreographer, BatteryManager,
 * /proc/self/stat) and are integration-tested via the live emulator, not here.
 */
class MetricTest {

    private data class Emission(val tag: String, val level: SimConsole.Level, val payload: String)

    private val captured = mutableListOf<Emission>()
    private val sink = object : SimConsole.Sink {
        override fun emit(tag: String, level: SimConsole.Level, payload: String) {
            captured += Emission(tag, level, payload)
        }
    }

    @Before
    fun setUp() {
        captured.clear()
        SimConsole.sink = sink
        // Use the no-context bootstrap so samplers don't try to spawn a
        // HandlerThread inside a JVM unit test (Looper.getMainLooper would
        // throw without a Robolectric runtime).
        SimConsole.bootstrap(
            SimConsole.Configuration(subsystem = "com.example.test", enabled = true),
        )
    }

    @After
    fun tearDown() {
        SimConsole.bootstrap(SimConsole.Configuration(subsystem = "", enabled = false))
    }

    private fun envelopes(kind: String): List<JSONObject> =
        captured.map { JSONObject(it.payload) }.filter { it.optString("kind") == kind }

    @Test
    fun gaugeEmitsExpectedShape() {
        Metric.gauge(name = "cache.hit_rate", value = 0.87, fields = mapOf("region" to "us"))
        val e = envelopes("metric.gauge").single()
        assertEquals("cache.hit_rate", e.getString("name"))
        assertEquals(0.87, e.getDouble("value"), 0.0)
        assertEquals("us", e.getJSONObject("fields").getString("region"))
        assertTrue(e.has("t"))
    }

    @Test
    fun counterTracksRunningTotal() {
        Metric.counter("network.retries")              // delta=1, total=1
        Metric.counter("network.retries", 2.0)         // delta=2, total=3
        Metric.counter("network.retries")              // delta=1, total=4

        val emissions = envelopes("metric.counter")
        assertEquals(3, emissions.size)
        assertEquals(1.0, emissions[0].getDouble("delta"), 0.0)
        assertEquals(1.0, emissions[0].getDouble("total"), 0.0)
        assertEquals(2.0, emissions[1].getDouble("delta"), 0.0)
        assertEquals(3.0, emissions[1].getDouble("total"), 0.0)
        assertEquals(1.0, emissions[2].getDouble("delta"), 0.0)
        assertEquals(4.0, emissions[2].getDouble("total"), 0.0)
    }

    @Test
    fun signpostCapturesNameAndDuration() {
        Metric.signpost("decode", durationMs = 42)
        val e = envelopes("metric.signpost").single()
        assertEquals("decode", e.getString("name"))
        assertEquals(42, e.getInt("duration_ms"))
    }

    @Test
    fun measureEmitsSignpostWithMeasuredDuration() {
        val result = Metric.measure("work") {
            Thread.sleep(10)
            "done"
        }
        assertEquals("done", result)

        val e = envelopes("metric.signpost").single()
        assertEquals("work", e.getString("name"))
        assertTrue("expected duration >= 10ms, got ${e.getInt("duration_ms")}", e.getInt("duration_ms") >= 10)
    }

    @Test
    fun appFinishLaunchingIsIdempotent() {
        Metric.appStartLaunch()
        Thread.sleep(5)
        Metric.appFinishLaunching()
        Metric.appFinishLaunching()
        Metric.appFinishLaunching()

        val launches = envelopes("metric.launch")
        assertEquals("only first appFinishLaunching should emit, got ${launches.size}", 1, launches.size)
        assertTrue(launches.single().getInt("ms") >= 0)
    }

    @Test
    fun milestoneReportsTimeSinceLaunchAnchor() {
        Metric.appStartLaunch()
        Thread.sleep(5)
        Metric.launchMilestone("auth_ready", fields = mapOf("source" to "cold"))
        val e = envelopes("metric.milestone").single()
        assertEquals("auth_ready", e.getString("name"))
        assertTrue(e.getInt("ms_since_launch") >= 0)
        assertEquals("cold", e.getJSONObject("fields").getString("source"))
    }

    @Test
    fun emissionsRouteToMetricTag() {
        Metric.gauge("x", 1.0)
        val e = captured.single()
        assertEquals("SimConsole.metric", e.tag)
        assertEquals(SimConsole.Level.Info, e.level)
    }

    @Test
    fun nothingEmitsBeforeBootstrap() {
        SimConsole.bootstrap(SimConsole.Configuration(subsystem = "", enabled = false))
        captured.clear()
        Metric.gauge("ignored", 1.0)
        Metric.counter("ignored")
        Metric.signpost("ignored", 1)
        assertEquals(0, captured.size)
    }

    @Test
    fun internalSamplersEmitMetricSample() {
        Metric.sample("memory.resident_mb", 123.4)
        val e = envelopes("metric.sample").single()
        assertEquals("memory.resident_mb", e.getString("name"))
        assertEquals(123.4, e.getDouble("value"), 0.0)
        assertNotNull(e.optJSONObject("fields"))
    }

    @Test
    fun internalHangSchemaMatchesIos() {
        Metric.hang(durationMs = 320)
        val e = envelopes("metric.hang").single()
        assertEquals(320, e.getInt("duration_ms"))
    }
}
