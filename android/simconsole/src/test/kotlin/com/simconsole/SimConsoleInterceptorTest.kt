package com.simconsole

import mockwebserver3.MockResponse
import mockwebserver3.MockWebServer
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import org.json.JSONObject
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test

class SimConsoleInterceptorTest {

    private data class Emission(val tag: String, val level: SimConsole.Level, val payload: String)

    private val captured = mutableListOf<Emission>()
    private val sink = object : SimConsole.Sink {
        override fun emit(tag: String, level: SimConsole.Level, payload: String) {
            synchronized(captured) { captured += Emission(tag, level, payload) }
        }
    }

    private lateinit var server: MockWebServer
    private lateinit var client: OkHttpClient

    @Before
    fun setUp() {
        captured.clear()
        SimConsole.sink = sink
        SimConsole.bootstrap(
            SimConsole.Configuration(subsystem = "com.example.test", enabled = true),
        )
        server = MockWebServer().apply { start() }
        client = OkHttpClient.Builder()
            .addInterceptor(SimConsoleInterceptor())
            .build()
    }

    @After
    fun tearDown() {
        server.close()
        SimConsole.bootstrap(SimConsole.Configuration(subsystem = "", enabled = false))
    }

    private fun envelopes(kind: String): List<JSONObject> =
        captured.map { JSONObject(it.payload) }.filter { it.optString("kind") == kind }

    @Test
    fun getRequestEmitsRequestAndResponseEnvelopes() {
        server.enqueue(
            MockResponse.Builder()
                .code(200)
                .addHeader("Content-Type", "application/json")
                .body("""{"ok":true}""")
                .build(),
        )

        val response = client.newCall(
            Request.Builder().url(server.url("/hello?q=1")).build(),
        ).execute()
        response.use { assertEquals(200, it.code) }

        val req = envelopes("net.request").single()
        assertEquals("GET", req.getString("method"))
        assertTrue(req.getString("url").endsWith("/hello?q=1"))
        assertTrue(req.has("id"))

        val resp = envelopes("net.response").single()
        assertEquals(200, resp.getInt("status"))
        assertEquals(req.getString("id"), resp.getString("id"))
        assertTrue("duration should be non-negative", resp.getInt("duration_ms") >= 0)

        // net.body for the response (request had no body).
        val bodies = envelopes("net.body")
        val responseBody = bodies.single { it.getString("direction") == "response" }
        assertEquals("""{"ok":true}""", responseBody.getString("body"))
    }

    @Test
    fun postBodyIsCapturedAndPairedToRequest() {
        server.enqueue(MockResponse.Builder().code(201).build())

        val body = """{"name":"alice"}""".toRequestBody("application/json".toMediaType())
        client.newCall(
            Request.Builder().url(server.url("/users")).post(body).build(),
        ).execute().close()

        val req = envelopes("net.request").single()
        val reqBody = envelopes("net.body").single { it.getString("direction") == "request" }
        assertEquals(req.getString("id"), reqBody.getString("id"))
        assertEquals("""{"name":"alice"}""", reqBody.getString("body"))
    }

    @Test
    fun headersEmitOneEnvelopePerName() {
        server.enqueue(
            MockResponse.Builder()
                .code(200)
                .addHeader("X-Test", "alpha")
                .addHeader("X-Other", "beta")
                .body("ok")
                .build(),
        )

        client.newCall(
            Request.Builder()
                .url(server.url("/h"))
                .header("Authorization", "Bearer abc")
                .build(),
        ).execute().close()

        val reqHeaders = envelopes("net.header").filter { it.getString("direction") == "request" }
        assertTrue(
            "expected Authorization header to be captured, got ${reqHeaders.map { it.getString("name") }}",
            reqHeaders.any { it.getString("name") == "Authorization" && it.getString("value") == "Bearer abc" },
        )

        val respHeaderNames = envelopes("net.header")
            .filter { it.getString("direction") == "response" }
            .map { it.getString("name") }
        assertTrue("X-Test" in respHeaderNames)
        assertTrue("X-Other" in respHeaderNames)
    }

    @Test
    fun setCookieIsDroppedToAvoidCoalescingMangling() {
        server.enqueue(
            MockResponse.Builder()
                .code(200)
                .addHeader("Set-Cookie", "session=1; Path=/")
                .addHeader("Set-Cookie", "csrf=2; Path=/")
                .body("ok")
                .build(),
        )

        client.newCall(Request.Builder().url(server.url("/c")).build()).execute().close()

        val names = envelopes("net.header")
            .filter { it.getString("direction") == "response" }
            .map { it.getString("name").lowercase() }
        assertTrue("set-cookie shouldn't be captured", "set-cookie" !in names)
    }

    @Test
    fun networkFailureEmitsNetError() {
        // Point the client at a closed port so connect fails fast.
        server.close()

        var caught: Throwable? = null
        try {
            client.newCall(
                Request.Builder().url(server.url("/dead")).build(),
            ).execute().close()
        } catch (e: Throwable) {
            caught = e
        }
        assertTrue("expected the request to fail", caught != null)

        val err = envelopes("net.error").single()
        assertTrue(err.has("error"))
        assertTrue("duration_ms must be present", err.has("duration_ms"))
        assertEquals(envelopes("net.request").single().getString("id"), err.getString("id"))
    }

    @Test
    fun matchedMockShortCircuitsTheNetwork() {
        // Bind a temp mocks file.
        val tmp = java.io.File.createTempFile("mocks-", ".json")
        tmp.writeText(
            """{"version":1,"mocks":[
              {"id":"m1","match":{"method":"GET","url":"https://mocked.invalid/x"},
               "response":{"status":418,"headers":{"X-Brewed-By":"sim-console"},"body":"I'm a teapot"},
               "delay_ms":0,"enabled":true,"created_at":""}
            ]}""".trimIndent(),
        )
        MockStore.reloadFromPath(tmp.absolutePath)

        val response = client.newCall(
            okhttp3.Request.Builder().url("https://mocked.invalid/x").build(),
        ).execute()
        response.use {
            assertEquals(418, it.code)
            assertEquals("sim-console", it.header("X-Brewed-By"))
            assertEquals("I'm a teapot", it.body!!.string())
        }

        // Both request and response envelopes should carry mocked=true.
        val req = envelopes("net.request").single()
        val resp = envelopes("net.response").single()
        assertTrue("request should be marked mocked", req.optBoolean("mocked"))
        assertTrue("response should be marked mocked", resp.optBoolean("mocked"))
        assertEquals(req.getString("id"), resp.getString("id"))

        // Sanity: server-side enqueueing wasn't consumed. (If the interceptor
        // had let it through, MockWebServer would have surfaced an unexpected
        // request error on the response below.)
        assertEquals(0, server.requestCount)
    }

    @Test
    fun mockDelayIsHonored() {
        val tmp = java.io.File.createTempFile("mocks-", ".json")
        tmp.writeText(
            """{"version":1,"mocks":[
              {"id":"m1","match":{"method":"GET","url":"https://slow.invalid/x"},
               "response":{"status":200,"headers":{},"body":"hi"},
               "delay_ms":120,"enabled":true,"created_at":""}
            ]}""".trimIndent(),
        )
        MockStore.reloadFromPath(tmp.absolutePath)

        val start = System.currentTimeMillis()
        client.newCall(
            okhttp3.Request.Builder().url("https://slow.invalid/x").build(),
        ).execute().close()
        val elapsed = System.currentTimeMillis() - start
        assertTrue("expected >=120 ms elapsed, got $elapsed", elapsed >= 120)
    }

    @Test
    fun bodyIsClippedAtMaxBodyChars() {
        SimConsole.bootstrap(
            SimConsole.Configuration(subsystem = "com.example.test", enabled = true, maxBodyChars = 16),
        )
        server.enqueue(
            MockResponse.Builder().code(200).body("0123456789ABCDEFGHIJKLM").build(),
        )

        client.newCall(Request.Builder().url(server.url("/x")).build()).execute().close()

        val body = envelopes("net.body").single { it.getString("direction") == "response" }
        val text = body.getString("body")
        assertTrue("expected clip marker, got '$text'", text.contains("…[+"))
        assertTrue("expected text to start with the first maxBodyChars bytes", text.startsWith("0123456789ABCDEF"))
    }
}
