package com.simconsole

import org.junit.Assert.assertEquals
import org.junit.Test

class EnvelopeTest {

    @Test
    fun keysAreSortedAlphabetically() {
        val json = Envelope.encode(mapOf("z" to 1, "a" to 2, "m" to 3))
        assertEquals("""{"a":2,"m":3,"z":1}""", json)
    }

    @Test
    fun nullValuesEmitAsJsonNull() {
        val json = Envelope.encode(mapOf("screen" to null, "kind" to "analytics"))
        assertEquals("""{"kind":"analytics","screen":null}""", json)
    }

    @Test
    fun nestedMapsAreSortedRecursively() {
        val json = Envelope.encode(mapOf("a" to mapOf("z" to 1, "b" to 2)))
        assertEquals("""{"a":{"b":2,"z":1}}""", json)
    }

    @Test
    fun integersDoNotGainTrailingZero() {
        // Mirrors iOS behavior: NSNumber for an Int round-trips as "5", not "5.0".
        val json = Envelope.encode(mapOf("n" to 5))
        assertEquals("""{"n":5}""", json)
    }

    @Test
    fun doublesWithoutFractionalPartCollapseToInteger() {
        val json = Envelope.encode(mapOf("n" to 5.0))
        assertEquals("""{"n":5}""", json)
    }

    @Test
    fun booleansSerializeUnquoted() {
        val json = Envelope.encode(mapOf("mocked" to true, "enabled" to false))
        assertEquals("""{"enabled":false,"mocked":true}""", json)
    }

    @Test
    fun listsPreserveOrder() {
        val json = Envelope.encode(mapOf("xs" to listOf(3, 1, 2)))
        assertEquals("""{"xs":[3,1,2]}""", json)
    }

    @Test
    fun stringsAreEscaped() {
        val json = Envelope.encode(mapOf("msg" to "hello \"world\"\n"))
        assertEquals("""{"msg":"hello \"world\"\n"}""", json)
    }

    @Test
    fun unknownTypesFallBackToToString() {
        class Foo { override fun toString() = "foo!" }
        val json = Envelope.encode(mapOf("v" to Foo()))
        assertEquals("""{"v":"foo!"}""", json)
    }

    @Test
    fun sanitizeMapPassesThroughPrimitivesAndConvertsExotic() {
        class Foo { override fun toString() = "foo!" }
        val out = Envelope.sanitizeMap(mapOf("a" to 1, "b" to "x", "c" to Foo()))
        assertEquals(1, out["a"])
        assertEquals("x", out["b"])
        assertEquals("foo!", out["c"])
    }
}
