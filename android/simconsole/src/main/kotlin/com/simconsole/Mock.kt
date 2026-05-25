package com.simconsole

import org.json.JSONArray
import org.json.JSONObject

/**
 * One mock rule. Persisted as a row in the panel-managed JSON file (see
 * [MockStore]).
 *
 * Field names and types must stay byte-for-byte compatible with the iOS Mock
 * struct in `Sources/SimConsole/Mock.swift`: the macOS panel writes one file
 * format and both SDKs read it. The iOS UI exposes `body_contains` only via
 * manual edits, but both SDKs honor it.
 */
data class Mock(
    val id: String,
    val match: MockMatch,
    val response: MockResponse,
    val delayMs: Int = 0,
    val enabled: Boolean = true,
    val createdAt: String = "",
) {
    internal companion object {
        fun fromJson(obj: JSONObject): Mock = Mock(
            id = obj.getString("id"),
            match = MockMatch.fromJson(obj.getJSONObject("match")),
            response = MockResponse.fromJson(obj.getJSONObject("response")),
            delayMs = obj.optInt("delay_ms", 0),
            enabled = obj.optBoolean("enabled", true),
            createdAt = obj.optString("created_at", ""),
        )
    }
}

data class MockMatch(
    val method: String,
    val url: String,
    val bodyContains: String? = null,
) {
    /** Exact match on method + full URL, optionally requiring the body substring. */
    fun matches(method: String, url: String, body: String?): Boolean {
        if (!this.method.equals(method, ignoreCase = true)) return false
        if (this.url != url) return false
        val needle = bodyContains
        if (!needle.isNullOrEmpty()) {
            return body?.contains(needle) == true
        }
        return true
    }

    internal companion object {
        fun fromJson(obj: JSONObject): MockMatch = MockMatch(
            method = obj.getString("method"),
            url = obj.getString("url"),
            bodyContains = obj.optString("body_contains").ifEmpty { null },
        )
    }
}

data class MockResponse(
    val status: Int,
    val headers: Map<String, String> = emptyMap(),
    val body: String? = null,
) {
    internal companion object {
        fun fromJson(obj: JSONObject): MockResponse {
            val headers = mutableMapOf<String, String>()
            obj.optJSONObject("headers")?.let { hdr ->
                for (key in hdr.keys()) headers[key] = hdr.getString(key)
            }
            val bodyStr = if (obj.has("body") && !obj.isNull("body")) obj.optString("body") else null
            return MockResponse(
                status = obj.getInt("status"),
                headers = headers,
                body = bodyStr,
            )
        }
    }
}

/** Top-level JSON file shape. Mirrors iOS `MockFile`. */
internal data class MockFile(val version: Int, val mocks: List<Mock>) {
    companion object {
        fun parse(text: String): MockFile {
            val obj = JSONObject(text)
            val arr = obj.optJSONArray("mocks") ?: JSONArray()
            val mocks = (0 until arr.length()).map { Mock.fromJson(arr.getJSONObject(it)) }
            return MockFile(version = obj.optInt("version", 1), mocks = mocks)
        }
    }
}
