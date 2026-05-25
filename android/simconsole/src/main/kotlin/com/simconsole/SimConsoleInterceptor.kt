package com.simconsole

import okhttp3.Interceptor
import okhttp3.MediaType.Companion.toMediaTypeOrNull
import okhttp3.Protocol
import okhttp3.Response
import okhttp3.ResponseBody.Companion.toResponseBody
import okio.Buffer
import java.io.IOException
import java.util.UUID

/**
 * Captures every request/response pair flowing through an OkHttp client and
 * emits it to the macOS panel via [SimConsole]. Wire it in DEBUG builds:
 *
 * ```kotlin
 * val client = OkHttpClient.Builder()
 *     .apply { if (BuildConfig.DEBUG) addInterceptor(SimConsoleInterceptor()) }
 *     .build()
 * ```
 *
 * Place this interceptor *last* in the chain. Network-level interceptors (e.g.
 * `addNetworkInterceptor`) see the request after OkHttp has injected its own
 * headers (Host, Content-Length, etc.) and the response before redirect
 * handling, which more closely matches what's on the wire — but they don't see
 * application-level retries. Application-level (`addInterceptor`) is the right
 * default for a dev console; the panel shows what your code *intended* to send.
 *
 * Bodies are buffered into memory and clipped to
 * [SimConsole.Configuration.maxBodyChars] before emission. Streaming or
 * binary bodies are surfaced with a `<N bytes>` placeholder so the panel
 * doesn't blow up on multi-megabyte uploads.
 */
class SimConsoleInterceptor : Interceptor {

    override fun intercept(chain: Interceptor.Chain): Response {
        val request = chain.request()
        if (!SimConsole.isEnabled) return chain.proceed(request)

        val id = UUID.randomUUID().toString()
        val started = System.nanoTime()

        val reqHeaders = headerMap(request.headers)
        val reqBody = bodyString(request)

        // Short-circuit: if the panel-pushed mock store has a rule for this
        // request, synthesize the response and skip the network entirely.
        val mock = MockStore.findMock(method = request.method, url = request.url.toString(), body = reqBody)
        if (mock != null) {
            SimConsole.networkRequest(
                id = id,
                method = request.method,
                url = request.url.toString(),
                headers = reqHeaders,
                body = reqBody,
                mocked = true,
            )
            return deliverMock(request, id, mock, started)
        }

        SimConsole.networkRequest(
            id = id,
            method = request.method,
            url = request.url.toString(),
            headers = reqHeaders,
            body = reqBody,
        )

        val response: Response = try {
            chain.proceed(request)
        } catch (e: IOException) {
            SimConsole.networkError(
                id = id,
                durationMs = elapsedMs(started),
                error = e.toString(),
            )
            throw e
        }

        val respHeaders = headerMap(response.headers)
        // peekBody copies the response stream into a buffer that the caller can
        // still consume — we never touch the original ResponseBody, so the host
        // app reads the same bytes regardless of whether we're attached.
        val peekSource = response.peekBody(MAX_BODY_PEEK_BYTES).string()
        val byteSize = peekSource.toByteArray(Charsets.UTF_8).size
        SimConsole.networkResponse(
            id = id,
            status = response.code,
            durationMs = elapsedMs(started),
            headers = respHeaders,
            body = if (peekSource.isEmpty()) null else peekSource,
            byteSize = byteSize,
        )

        return response
    }

    /**
     * Build a synthetic [Response] from a matched [Mock] and emit the paired
     * `net.response` envelope. Honors `delayMs` so panel-level "what if this
     * endpoint were slow?" experiments work.
     */
    private fun deliverMock(
        request: okhttp3.Request,
        id: String,
        mock: Mock,
        startedNanos: Long,
    ): Response {
        if (mock.delayMs > 0) {
            try {
                Thread.sleep(mock.delayMs.toLong())
            } catch (_: InterruptedException) {
                Thread.currentThread().interrupt()
            }
        }
        // Pick a Content-Type — OkHttp's ResponseBody needs one to decode bytes
        // through `string()`. Prefer the mocked Content-Type header if present.
        val mediaType = mock.response.headers
            .entries.firstOrNull { it.key.equals("Content-Type", ignoreCase = true) }
            ?.value
            ?.toMediaTypeOrNull()
        val bodyText = mock.response.body.orEmpty()
        val responseBody = bodyText.toResponseBody(mediaType)

        val builder = Response.Builder()
            .request(request)
            .protocol(Protocol.HTTP_1_1)
            .code(mock.response.status)
            .message(httpReasonPhrase(mock.response.status))
            .body(responseBody)
        // Copy mock headers, but skip Content-Length / Content-Type because OkHttp
        // derives Content-Length from the body bytes, and Content-Type was
        // already attached to the ResponseBody above.
        for ((name, value) in mock.response.headers) {
            if (name.equals("Content-Length", ignoreCase = true)) continue
            if (name.equals("Content-Type", ignoreCase = true)) continue
            builder.addHeader(name, value)
        }
        val response = builder.build()

        SimConsole.networkResponse(
            id = id,
            status = response.code,
            durationMs = elapsedMs(startedNanos),
            headers = headerMap(response.headers),
            body = bodyText.ifEmpty { null },
            byteSize = bodyText.toByteArray(Charsets.UTF_8).size,
            mocked = true,
        )
        return response
    }

    /** Best-effort reason phrase. OkHttp tolerates an empty string but most
     *  clients log nicer-looking rows when the standard text is present. */
    private fun httpReasonPhrase(code: Int): String = when (code) {
        200 -> "OK"; 201 -> "Created"; 202 -> "Accepted"; 204 -> "No Content"
        301 -> "Moved Permanently"; 302 -> "Found"; 304 -> "Not Modified"
        400 -> "Bad Request"; 401 -> "Unauthorized"; 403 -> "Forbidden"
        404 -> "Not Found"; 409 -> "Conflict"; 422 -> "Unprocessable Entity"
        429 -> "Too Many Requests"
        500 -> "Internal Server Error"; 502 -> "Bad Gateway"; 503 -> "Service Unavailable"
        else -> "Mocked"
    }

    private fun elapsedMs(startedNanos: Long): Int =
        ((System.nanoTime() - startedNanos) / 1_000_000L).toInt()

    private fun headerMap(headers: okhttp3.Headers): Map<String, String> {
        // OkHttp Headers can have duplicate keys (Set-Cookie, etc). We coalesce
        // duplicates with `,` since header values are formally comma-joinable
        // per RFC 7230 §3.2.2 — except Set-Cookie, which we drop to avoid
        // landing one mangled string in the panel.
        val out = linkedMapOf<String, String>()
        for (i in 0 until headers.size) {
            val name = headers.name(i)
            if (name.equals("Set-Cookie", ignoreCase = true)) continue
            val value = headers.value(i)
            out[name] = out[name]?.let { "$it,$value" } ?: value
        }
        return out
    }

    private fun bodyString(request: okhttp3.Request): String? {
        val body = request.body ?: return null
        return try {
            val buffer = Buffer()
            body.writeTo(buffer)
            // OkHttp request bodies have no Content-Encoding wrapping here —
            // they're whatever the caller wrote. Keep peeking out the first
            // chunk and let SimConsole.clip() decide how much to retain.
            if (buffer.size > MAX_BODY_PEEK_BYTES) {
                val head = buffer.readUtf8(MAX_BODY_PEEK_BYTES)
                "$head…[+${buffer.size} bytes]"
            } else if (isProbablyText(body.contentType()?.toString())) {
                buffer.readUtf8()
            } else {
                "<${buffer.size} bytes>"
            }
        } catch (e: Throwable) {
            "<unreadable body: ${e.message}>"
        }
    }

    private fun isProbablyText(contentType: String?): Boolean {
        if (contentType == null) return true   // assume text when unspecified
        val ct = contentType.lowercase()
        return ct.startsWith("text/") ||
            ct.contains("json") ||
            ct.contains("xml") ||
            ct.contains("javascript") ||
            ct.contains("form-urlencoded")
    }

    companion object {
        /**
         * Bodies larger than this aren't buffered into memory. The panel-side
         * row will display a "<N bytes>" placeholder. 1 MB is plenty for
         * normal API traffic and well below the level where parsing would
         * harm the host app's foreground responsiveness.
         */
        private const val MAX_BODY_PEEK_BYTES = 1L * 1024 * 1024
    }
}
