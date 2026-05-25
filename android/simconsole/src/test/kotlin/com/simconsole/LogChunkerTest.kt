package com.simconsole

import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class LogChunkerTest {

    @Test
    fun smallPayloadEmitsAsSingleLine() {
        val payload = """{"kind":"log","msg":"hi"}"""
        assertFalse(LogChunker.isOversized(payload))
        assertEquals(listOf(payload), LogChunker.chunk("any", payload))
    }

    @Test
    fun oversizedPayloadIsChunkedAndReassemblesByteForByte() {
        // 10 KB body — well over the 3500-byte threshold.
        val body = "x".repeat(10_000)
        val original = """{"kind":"log","msg":"$body"}"""
        assertTrue(LogChunker.isOversized(original))

        val chunks = LogChunker.chunk("test-id", original)
        assertTrue("expected >1 chunk, got ${chunks.size}", chunks.size > 1)

        // Each chunk must be a valid envelope.
        val parts = chunks.mapIndexed { idx, chunk ->
            val obj = JSONObject(chunk)
            assertEquals("chunk", obj.getString("kind"))
            assertEquals("test-id", obj.getString("id"))
            assertEquals(idx, obj.getInt("i"))
            assertEquals(chunks.size, obj.getInt("n"))
            obj.getString("part")
        }

        val reassembled = parts.joinToString("")
        assertEquals(original, reassembled)
    }

    @Test
    fun utf8BoundariesAreNeverSplit() {
        // Multi-byte UTF-8 ("🚀" = 4 bytes, "é" = 2 bytes) repeated to force chunking.
        val rocket = "🚀".repeat(500)   // 2000 bytes
        val accent = "é".repeat(2000)   // 4000 bytes
        val original = """{"kind":"log","msg":"$rocket$accent"}"""
        assertTrue(LogChunker.isOversized(original))

        val chunks = LogChunker.chunk("utf8-id", original)
        val reassembled = chunks
            .map { JSONObject(it).getString("part") }
            .joinToString("")

        // Byte-for-byte identical means no boundary mangled a multi-byte codepoint.
        assertEquals(original, reassembled)
    }
}
