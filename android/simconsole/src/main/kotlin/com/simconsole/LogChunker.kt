package com.simconsole

/**
 * Logcat has a per-line payload cap (~4 KB on most kernels; the userspace `Log` API
 * silently truncates payloads above the limit). Network bodies and large analytics
 * params blow past it. We split anything over the threshold into N parts and let the
 * macOS panel reassemble by `id` + index.
 *
 * Chunk envelope shape (matches the panel's parser):
 *
 *     {"kind":"chunk","id":"<uuid>","i":<0-based>,"n":<total>,"part":"<raw piece>"}
 *
 * The `part` field is a substring of the original JSON, not itself JSON. The panel
 * concatenates all `part`s in order and parses the result as the real envelope.
 */
internal object LogChunker {

    /**
     * Conservative threshold: stay well under the documented ~4 KB logcat line cap to
     * leave headroom for the tag, level, pid/tid prefix, and the chunk-envelope wrapper.
     */
    const val MAX_PAYLOAD_BYTES = 3500

    fun isOversized(payload: String): Boolean =
        payload.toByteArray(Charsets.UTF_8).size > MAX_PAYLOAD_BYTES

    /**
     * Split `payload` into N chunked envelopes. Splitting is done on byte boundaries
     * but rewound to the nearest code-point boundary so reassembly never reconstructs
     * a mangled UTF-8 sequence.
     */
    fun chunk(id: String, payload: String): List<String> {
        val bytes = payload.toByteArray(Charsets.UTF_8)
        if (bytes.size <= MAX_PAYLOAD_BYTES) return listOf(payload)

        val pieces = mutableListOf<String>()
        var offset = 0
        while (offset < bytes.size) {
            var end = (offset + MAX_PAYLOAD_BYTES).coerceAtMost(bytes.size)
            // Rewind to a UTF-8 code-point boundary: bytes 0xxxxxxx (ASCII) or 11xxxxxx
            // (leading byte of a multi-byte sequence) are valid starts. 10xxxxxx is a
            // continuation byte — if we land on one, walk back until we don't.
            if (end < bytes.size) {
                while (end > offset && (bytes[end].toInt() and 0xC0) == 0x80) {
                    end--
                }
            }
            pieces += String(bytes, offset, end - offset, Charsets.UTF_8)
            offset = end
        }

        val total = pieces.size
        return pieces.mapIndexed { i, part ->
            Envelope.encode(
                mapOf(
                    "kind" to "chunk",
                    "id" to id,
                    "i" to i,
                    "n" to total,
                    "part" to part,
                ),
            )
        }
    }
}
