import Foundation
import os

/// Performance + custom-metric API.
///
/// Two layers:
/// - **Auto-sampled system metrics** (memory, CPU, FPS, thermal, battery, hangs)
///   are emitted by `MetricSampler` once per second after `SimConsole.bootstrap`.
/// - **App-marked metrics** (this surface) are called explicitly by the host
///   app at meaningful points — launch milestones, custom signposts, gauges,
///   counters.
///
/// Both flow through `os.Logger(subsystem: <bundle>, category: "metric")`, so
/// the macOS sim-console + MCP tools pick them up via the same channel as
/// network and analytics events. Debug builds only.
///
/// Typical wiring:
/// ```
/// SimConsole.bootstrap(.init(subsystem: ...))
/// // ... later, in your @main App or scene delegate:
/// SimConsole.metric.launchMilestone("first_screen_visible")
/// SimConsole.metric.signpost("feed_decode", durationMs: 142)
/// SimConsole.metric.gauge("cache.hit_rate", value: 0.87)
/// SimConsole.metric.counter("network.retries", increment: 1)
/// ```
public enum Metric {

    /// Captured at SDK load. Drives `ms_since_launch` on milestones.
    /// Read from `/proc/<pid>/stat`-equivalent isn't available on iOS; we
    /// use the SDK-load timestamp as the anchor — close enough for dev work
    /// since `SimConsole.bootstrap` is called in `App.init` / `AppDelegate.didFinishLaunching`.
    public static let processStart: Date = {
        // First time this static is touched (module load), capture "now".
        Date()
    }()

    static let logger: Logger = {
        let subsystem = SimConsole._subsystem() ?? "sim-console"
        return Logger(subsystem: subsystem, category: "metric")
    }()

    private static let queue = DispatchQueue(label: "com.simconsole.metric", attributes: .concurrent)
    private static var counters: [String: Double] = [:]
    private static var launchStart: Date?
    private static var launchEmitted: Bool = false

    // MARK: - Launch (canonical two-event API)

    /// Anchors the start of the app's cold-launch measurement. Call at the
    /// earliest possible moment — typically the very top of
    /// `App.init()` / `application(_:didFinishLaunchingWithOptions:)`, right
    /// after `SimConsole.bootstrap(...)`. **First call wins** — subsequent
    /// calls are no-ops, so it's safe to drop this in places that may run
    /// more than once.
    ///
    /// If never called, `appFinishLaunching()` falls back to the SDK-load
    /// timestamp as the anchor.
    public static func appStartLaunch() {
        queue.async(flags: .barrier) {
            if launchStart == nil { launchStart = Date() }
        }
    }

    /// Emits the canonical `metric.launch` event with the elapsed milliseconds
    /// from `appStartLaunch()` (or SDK-load if absent) to now. Call ONCE when
    /// the first user-facing view becomes interactive — typically in your
    /// root view's `.onAppear`, in `application(_:didFinishLaunchingWithOptions:)`
    /// after window setup, or after your first content load completes.
    ///
    /// **Idempotent** — subsequent calls are no-ops. Safe to put in
    /// `.onAppear` of a root view that re-appears on tab switches; only the
    /// first call counts.
    public static func appFinishLaunching() {
        queue.async(flags: .barrier) {
            guard !launchEmitted else { return }
            launchEmitted = true
            let anchor = launchStart ?? processStart
            let ms = Int(Date().timeIntervalSince(anchor) * 1000)
            emit([
                "kind": "metric.launch",
                "ms": ms
            ])
        }
    }

    // MARK: - Launch milestones (optional intermediate checkpoints)

    /// Records an intermediate named milestone for the launch timeline
    /// (e.g. "auth_ready", "feed_loaded"). Distinct from the canonical
    /// launch event emitted by `appFinishLaunching()`. Use these to attribute
    /// time *between* checkpoints, not to define the launch endpoint itself.
    public static func launchMilestone(_ name: String, fields: [String: Any] = [:]) {
        let anchor: Date = queue.sync { launchStart ?? processStart }
        let ms = Int(Date().timeIntervalSince(anchor) * 1000)
        emit([
            "kind": "metric.milestone",
            "name": name,
            "ms_since_launch": ms,
            "fields": SimConsole._jsonSafe(fields)
        ])
    }

    // MARK: - Signposts

    /// Records a finished named region. Use `measure(_:body:)` to time
    /// inline; this overload is for cases where you compute duration
    /// elsewhere (callback completion, async event).
    public static func signpost(_ name: String, durationMs: Int, fields: [String: Any] = [:]) {
        emit([
            "kind": "metric.signpost",
            "name": name,
            "duration_ms": durationMs,
            "fields": SimConsole._jsonSafe(fields)
        ])
    }

    /// Times a synchronous block and emits a signpost when it returns.
    /// Returns whatever the block returns so call-sites stay clean.
    @discardableResult
    public static func measure<T>(_ name: String, fields: [String: Any] = [:], body: () throws -> T) rethrows -> T {
        let start = Date()
        let result = try body()
        let ms = Int(Date().timeIntervalSince(start) * 1000)
        signpost(name, durationMs: ms, fields: fields)
        return result
    }

    // MARK: - Gauges + counters

    /// Records a point-in-time value. Use for instantaneous metrics that
    /// change over time (active downloads, cache hit rate, queue depth).
    public static func gauge(_ name: String, value: Double, fields: [String: Any] = [:]) {
        emit([
            "kind": "metric.gauge",
            "name": name,
            "value": value,
            "fields": SimConsole._jsonSafe(fields)
        ])
    }

    /// Increments a named counter. The wire payload includes both the
    /// `delta` and the running `total` so the dashboard doesn't have to
    /// reduce on the read side. Counters are monotonically increasing per
    /// process; reset on app relaunch.
    public static func counter(_ name: String, increment: Double = 1, fields: [String: Any] = [:]) {
        let total: Double = queue.sync(flags: .barrier) {
            let next = (counters[name] ?? 0) + increment
            counters[name] = next
            return next
        }
        emit([
            "kind": "metric.counter",
            "name": name,
            "delta": increment,
            "total": total,
            "fields": SimConsole._jsonSafe(fields)
        ])
    }

    // MARK: - Internal (used by MetricSampler / HangDetector)

    static func sample(name: String, value: Double, fields: [String: Any] = [:]) {
        emit([
            "kind": "metric.sample",
            "name": name,
            "value": value,
            "fields": SimConsole._jsonSafe(fields)
        ])
    }

    static func hang(durationMs: Int) {
        emit([
            "kind": "metric.hang",
            "duration_ms": durationMs
        ])
    }

    // MARK: - Emit helper

    private static func emit(_ partialPayload: [String: Any]) {
        var payload = partialPayload
        payload["t"] = Date().timeIntervalSince1970
        logger.log("\(SimConsole._json(payload), privacy: .public)")
    }
}

extension SimConsole {
    /// Namespaced entry point: `SimConsole.metric.gauge(...)`.
    public static let metric = Metric.self

    // Cross-module helpers exposed for Metric.swift (kept `internal` would
    // require same-target visibility — these are package-internal already).
    static func _subsystem() -> String? {
        // SimConsole.configuration is private; expose through a thin accessor.
        // We don't have public read access; use Bundle.main as a fallback.
        Bundle.main.bundleIdentifier
    }

    static func _json(_ payload: [String: Any]) -> String {
        json(payload)
    }

    static func _jsonSafe(_ dict: [String: Any]) -> [String: Any] {
        var out: [String: Any] = [:]
        for (k, v) in dict {
            out[k] = sanitizeValue(v)
        }
        return out
    }

    private static func sanitizeValue(_ value: Any) -> Any {
        switch value {
        case let s as String: return s
        case let n as NSNumber: return n
        case let b as Bool: return b
        case let arr as [Any]: return arr.map(sanitizeValue)
        case let dict as [String: Any]: return _jsonSafe(dict)
        case is NSNull: return NSNull()
        default: return String(describing: value)
        }
    }
}
