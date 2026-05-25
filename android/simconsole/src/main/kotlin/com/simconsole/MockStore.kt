package com.simconsole

import android.util.Log
import java.io.File

/**
 * Reads mock rules from `/data/local/tmp/sim-console-mocks-<bundle>.json` and
 * serves them to [SimConsoleInterceptor] so matching requests get a synthesized
 * response instead of a network call.
 *
 * **The panel pushes the file via `adb push`** — see `Tools/sim-console.swift`'s
 * MockSync. We chose `/data/local/tmp/` because it's:
 *   - World-readable by app sandboxes (no Storage Access Framework dance),
 *   - Writable by `adb shell` without root,
 *   - Survives across debug installs (unlike the app's `cacheDir`).
 *
 * Transport choice (mirrors iOS): we **stat-poll on every outbound request**
 * rather than registering a [android.os.FileObserver]. The panel writes the
 * file with the atomic `temp + rename` pattern, which fires inotify events on
 * the *new* inode — easy to miss across a FileObserver lifecycle. A `stat()`
 * per request is microseconds and only requests that pass `canInit` (HTTP/S
 * scheme) ever hit the lookup.
 *
 * Inert until configured. [findMock] returns `null` until [configure] has run.
 */
object MockStore {

    private val lock = Any()
    private var path: String = ""
    @Volatile private var cached: List<Mock> = emptyList()
    @Volatile private var cachedMTime: Long = 0L

    fun configure(bundleId: String) {
        synchronized(lock) {
            path = "/data/local/tmp/sim-console-mocks-$bundleId.json"
            cached = emptyList()
            cachedMTime = 0L
            Log.i("SimConsole.mock", "mocks path = $path")
        }
    }

    /** Forced reload from a specified path. Test seam only. */
    internal fun reloadFromPath(p: String) {
        synchronized(lock) {
            path = p
            cachedMTime = 0L
            reloadIfChangedLocked()
        }
    }

    fun findMock(method: String, url: String, body: String?): Mock? {
        synchronized(lock) {
            if (path.isEmpty()) return null
            reloadIfChangedLocked()
            for (mock in cached) {
                if (!mock.enabled) continue
                if (mock.match.matches(method, url, body)) return mock
            }
            return null
        }
    }

    internal fun currentMocks(): List<Mock> {
        synchronized(lock) {
            reloadIfChangedLocked()
            return cached.toList()
        }
    }

    private fun reloadIfChangedLocked() {
        if (path.isEmpty()) return
        val file = File(path)
        if (!file.exists()) {
            if (cached.isNotEmpty()) cached = emptyList()
            cachedMTime = 0L
            return
        }
        val mtime = file.lastModified()
        if (mtime == cachedMTime) return
        try {
            val text = file.readText()
            cached = MockFile.parse(text).mocks
            cachedMTime = mtime
        } catch (e: Throwable) {
            // Malformed file — log and keep last-good state to avoid flapping.
            Log.w("SimConsole.mock", "failed to parse $path: ${e.message}")
        }
    }
}
