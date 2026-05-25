package com.simconsole

import org.json.JSONObject
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test

/**
 * Drives [SimConsole] through a fake [SimConsole.Sink] so we can assert on
 * exactly what would have gone to logcat without booting an emulator.
 */
class SimConsoleTest {

    private data class Emission(val tag: String, val level: SimConsole.Level, val payload: String)

    private val captured = mutableListOf<Emission>()
    private val captureSink = object : SimConsole.Sink {
        override fun emit(tag: String, level: SimConsole.Level, payload: String) {
            captured += Emission(tag, level, payload)
        }
    }

    @Before
    fun setUp() {
        captured.clear()
        SimConsole.sink = captureSink
        SimConsole.bootstrap(
            SimConsole.Configuration(subsystem = "com.example.test", enabled = true),
        )
    }

    @After
    fun tearDown() {
        // Reset for the next test class. We can't restore the original logcat sink
        // from here, but each test re-installs `captureSink` in setUp.
        SimConsole.bootstrap(
            SimConsole.Configuration(subsystem = "", enabled = false),
        )
    }

    @Test
    fun analyticsEmitsToAnalyticsTagWithCorrectShape() {
        SimConsole.analytics(event = "login_tapped", params = mapOf("source" to "home"))

        assertEquals(1, captured.size)
        val e = captured.single()
        assertEquals("SimConsole.analytics", e.tag)
        assertEquals(SimConsole.Level.Info, e.level)

        val obj = JSONObject(e.payload)
        assertEquals("analytics", obj.getString("kind"))
        assertEquals("login_tapped", obj.getString("event"))
        assertEquals("home", obj.getJSONObject("params").getString("source"))
        assertTrue(obj.has("t"))
        assertTrue(obj.isNull("screen"))
    }

    @Test
    fun screenEmitsScreenKind() {
        SimConsole.screen(name = "Home", params = mapOf("origin" to "deeplink"))

        val obj = JSONObject(captured.single().payload)
        assertEquals("screen", obj.getString("kind"))
        assertEquals("Home", obj.getString("screen"))
        assertEquals("deeplink", obj.getJSONObject("params").getString("origin"))
    }

    @Test
    fun logEmitsToEventTagAtMatchingLevel() {
        SimConsole.log("oops", level = SimConsole.Level.Warn, fields = mapOf("code" to 42))

        val e = captured.single()
        assertEquals("SimConsole.event", e.tag)
        assertEquals(SimConsole.Level.Warn, e.level)

        val obj = JSONObject(e.payload)
        assertEquals("log", obj.getString("kind"))
        assertEquals("warn", obj.getString("level"))
        assertEquals("oops", obj.getString("msg"))
        assertEquals(42, obj.getJSONObject("fields").getInt("code"))
    }

    @Test
    fun callsAreNoOpWhenNotBootstrapped() {
        SimConsole.bootstrap(SimConsole.Configuration(subsystem = "", enabled = false))
        captured.clear()

        SimConsole.analytics("x")
        SimConsole.screen("y")
        SimConsole.log("z")

        assertEquals(0, captured.size)
    }

    @Test
    fun oversizedPayloadIsChunkedWithChunkTagSuffix() {
        // Force a chunk-eligible payload through the public API.
        val bigField = "x".repeat(10_000)
        SimConsole.log("big", fields = mapOf("blob" to bigField))

        assertTrue("expected >1 emission, got ${captured.size}", captured.size > 1)
        for (e in captured) {
            assertEquals("SimConsole.event.chunk", e.tag)
            val obj = JSONObject(e.payload)
            assertEquals("chunk", obj.getString("kind"))
        }
    }
}
