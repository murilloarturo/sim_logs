package com.simconsole

import org.json.JSONArray
import org.json.JSONObject

/**
 * JSON serialization matching the iOS SDK's output (sorted keys, no escaped slashes).
 * The panel parses both platforms with the same code, so byte-for-byte parity matters.
 *
 * `org.json` is part of the Android stdlib — no extra dependency. JVM unit tests pull
 * it in via the json-${VERSION}.jar shipped with the Android Gradle plugin.
 */
internal object Envelope {

    /**
     * Serialize a top-level map to a JSON string with sorted keys.
     * Mirrors iOS `JSONSerialization.data(... .sortedKeys, .withoutEscapingSlashes)`.
     */
    fun encode(payload: Map<String, Any?>): String = buildString {
        appendSortedObject(this, payload)
    }

    private fun appendSortedObject(sb: StringBuilder, map: Map<String, Any?>) {
        sb.append('{')
        val keys = map.keys.sorted()
        var first = true
        for (k in keys) {
            if (!first) sb.append(',')
            first = false
            sb.append(JSONObject.quote(k))
            sb.append(':')
            appendValue(sb, map[k])
        }
        sb.append('}')
    }

    private fun appendValue(sb: StringBuilder, value: Any?) {
        when (value) {
            null -> sb.append("null")
            is String -> sb.append(JSONObject.quote(value))
            is Boolean -> sb.append(if (value) "true" else "false")
            is Number -> sb.append(formatNumber(value))
            is Map<*, *> -> {
                @Suppress("UNCHECKED_CAST")
                appendSortedObject(sb, (value as Map<String, Any?>))
            }
            is Iterable<*> -> {
                sb.append('[')
                var first = true
                for (item in value) {
                    if (!first) sb.append(',')
                    first = false
                    appendValue(sb, sanitize(item))
                }
                sb.append(']')
            }
            is Array<*> -> {
                sb.append('[')
                var first = true
                for (item in value) {
                    if (!first) sb.append(',')
                    first = false
                    appendValue(sb, sanitize(item))
                }
                sb.append(']')
            }
            else -> sb.append(JSONObject.quote(value.toString()))
        }
    }

    private fun formatNumber(n: Number): String {
        // Match iOS NSNumber emission: integers without `.0`, doubles with their natural repr.
        if (n is Float || n is Double) {
            val d = n.toDouble()
            if (d.isNaN() || d.isInfinite()) return "null"
            if (d == d.toLong().toDouble()) return d.toLong().toString()
            return d.toString()
        }
        return n.toString()
    }

    /**
     * Convert arbitrary host-app values into a JSON-safe shape. Mirrors iOS `sanitize`.
     * Strings, numbers, booleans, lists, and maps pass through. Anything else gets
     * `toString()`'d so callers can't crash the SDK by passing exotic types.
     */
    fun sanitize(value: Any?): Any? = when (value) {
        null -> null
        is String, is Boolean, is Number -> value
        is Map<*, *> -> {
            val out = linkedMapOf<String, Any?>()
            for ((k, v) in value) out[k.toString()] = sanitize(v)
            out
        }
        is Iterable<*> -> value.map { sanitize(it) }
        is Array<*> -> value.map { sanitize(it) }
        is JSONObject, is JSONArray -> value.toString()
        else -> value.toString()
    }

    fun sanitizeMap(map: Map<String, Any?>): Map<String, Any?> {
        val out = linkedMapOf<String, Any?>()
        for ((k, v) in map) out[k] = sanitize(v)
        return out
    }
}
