import Foundation
import os

/// Entry point for the in-app side of `sim-console`.
///
/// Routes structured events through `os.Logger` so the companion `sim-console`
/// macOS app — which subscribes to `xcrun simctl spawn <UDID> log stream` —
/// can pick them up via predicates that match `subsystem == <bundle-id> AND
/// category == "analytics" | "network" | "event"`.
///
/// All payloads are emitted with `%{public}@` so the unified logging system
/// won't redact them to `<private>`. Use in **debug builds only** — never ship
/// this enabled in a production binary.
///
/// Wire by calling `SimConsole.bootstrap(...)` once at launch, e.g.:
///
///     #if DEBUG
///     SimConsole.bootstrap(.init(subsystem: Bundle.main.bundleIdentifier ?? "app"))
///     #endif
public enum SimConsole {

    public struct Configuration {
        public var subsystem: String
        public var enabled: Bool
        public var maxBodyChars: Int

        public init(
            subsystem: String,
            enabled: Bool = true,
            maxBodyChars: Int = 800
        ) {
            self.subsystem = subsystem
            self.enabled = enabled
            self.maxBodyChars = maxBodyChars
        }
    }

    private static var configuration: Configuration?
    private static let queue = DispatchQueue(label: "com.simconsole.emit")

    private static var analyticsLogger: Logger?
    private static var networkLogger: Logger?
    private static var eventLogger: Logger?

    public static func bootstrap(_ config: Configuration) {
        queue.sync {
            configuration = config
            guard config.enabled else { return }
            analyticsLogger = Logger(subsystem: config.subsystem, category: "analytics")
            networkLogger   = Logger(subsystem: config.subsystem, category: "network")
            eventLogger     = Logger(subsystem: config.subsystem, category: "event")
        }
        // MockStore reads ~/.sim-console/mocks-<bundle>.json. Inert outside
        // the simulator. Wiring it up here means SimConsoleURLProtocol can
        // consult it on every outbound request without further setup.
        MockStore.shared.configure(bundleId: config.subsystem)
    }

    public static var isEnabled: Bool {
        queue.sync { configuration?.enabled == true }
    }

    static var maxBodyChars: Int {
        queue.sync { configuration?.maxBodyChars ?? 800 }
    }

    // MARK: Analytics

    public static func analytics(event: String, params: [String: Any] = [:], screen: String? = nil) {
        guard let logger = analyticsLogger else { return }
        let payload: [String: Any] = [
            "kind": "analytics",
            "t": now(),
            "event": event,
            "params": jsonSafe(params),
            "screen": screen as Any
        ]
        logger.log("\(json(payload), privacy: .public)")
    }

    public static func screen(_ name: String, params: [String: Any] = [:]) {
        guard let logger = analyticsLogger else { return }
        let payload: [String: Any] = [
            "kind": "screen",
            "t": now(),
            "screen": name,
            "params": jsonSafe(params)
        ]
        logger.log("\(json(payload), privacy: .public)")
    }

    // MARK: Network

    public static func network(request id: String, method: String, url: String, headers: [String: String] = [:], body: String? = nil, mocked: Bool = false) {
        guard let logger = networkLogger else { return }
        var payload: [String: Any] = [
            "kind": "net.request",
            "t": now(),
            "id": id,
            "method": method,
            "url": url
        ]
        if mocked { payload["mocked"] = true }
        logger.log("\(json(payload), privacy: .public)")
        emitHeaders(id: id, direction: "request", headers: headers)
        emitBody(id: id, direction: "request", body: body)
    }

    public static func network(response id: String, status: Int, durationMs: Int, headers: [String: String] = [:], body: String? = nil, byteSize: Int? = nil, mocked: Bool = false) {
        guard let logger = networkLogger else { return }
        var payload: [String: Any] = [
            "kind": "net.response",
            "t": now(),
            "id": id,
            "status": status,
            "duration_ms": durationMs
        ]
        if let byteSize { payload["byte_size"] = byteSize }
        if mocked { payload["mocked"] = true }
        logger.log("\(json(payload), privacy: .public)")
        emitHeaders(id: id, direction: "response", headers: headers)
        emitBody(id: id, direction: "response", body: body)
    }

    /// Each header is emitted as its own log line. A single bloated CDN header
    /// (report-to, nel, alt-svc, etc.) can be ~300 chars on its own — bundled
    /// into one payload they overflow `os_log`'s per-line limit and the whole
    /// event gets truncated before the parser can see `"kind"`. Per-header
    /// events trade volume for reliability: each line is small and parseable.
    private static func emitHeaders(id: String, direction: String, headers: [String: String]) {
        guard let logger = networkLogger, !headers.isEmpty else { return }
        for (name, value) in headers {
            let payload: [String: Any] = [
                "kind": "net.header",
                "t": now(),
                "id": id,
                "direction": direction,
                "name": name,
                "value": clip(value) ?? ""
            ]
            logger.log("\(json(payload), privacy: .public)")
        }
    }

    /// Body events live on their own log line so the meta row above can't be
    /// truncated by `os_log`'s per-line limit. The companion macOS app
    /// pairs them to the meta row by `id` + `direction`.
    private static func emitBody(id: String, direction: String, body: String?) {
        guard let logger = networkLogger,
              let body, !body.isEmpty else { return }
        let payload: [String: Any] = [
            "kind": "net.body",
            "t": now(),
            "id": id,
            "direction": direction,
            "body": clip(body) as Any
        ]
        logger.log("\(json(payload), privacy: .public)")
    }

    public static func network(error id: String, durationMs: Int, error: String) {
        guard let logger = networkLogger else { return }
        let payload: [String: Any] = [
            "kind": "net.error",
            "t": now(),
            "id": id,
            "duration_ms": durationMs,
            "error": error
        ]
        logger.log("\(json(payload), privacy: .public)")
    }

    // MARK: Generic event

    public enum Level: String {
        case debug, info, warn, error
    }

    public static func log(_ message: String, level: Level = .info, fields: [String: Any] = [:]) {
        guard let logger = eventLogger else { return }
        let payload: [String: Any] = [
            "kind": "log",
            "t": now(),
            "level": level.rawValue,
            "msg": message,
            "fields": jsonSafe(fields)
        ]
        switch level {
        case .debug: logger.debug("\(json(payload), privacy: .public)")
        case .info:  logger.info("\(json(payload), privacy: .public)")
        case .warn:  logger.warning("\(json(payload), privacy: .public)")
        case .error: logger.error("\(json(payload), privacy: .public)")
        }
    }

    // MARK: Helpers

    private static func now() -> Double { Date().timeIntervalSince1970 }

    private static func clip(_ s: String?) -> String? {
        guard let s, !s.isEmpty else { return s }
        let max = maxBodyChars
        if s.count <= max { return s }
        let head = s.prefix(max)
        return "\(head)…[+\(s.count - max) chars]"
    }

    private static func jsonSafe(_ dict: [String: Any]) -> [String: Any] {
        var out: [String: Any] = [:]
        for (k, v) in dict {
            out[k] = sanitize(v)
        }
        return out
    }

    private static func sanitize(_ value: Any) -> Any {
        switch value {
        case let s as String: return s
        case let n as NSNumber: return n
        case let b as Bool: return b
        case let arr as [Any]: return arr.map(sanitize)
        case let dict as [String: Any]: return jsonSafe(dict)
        case is NSNull: return NSNull()
        default: return String(describing: value)
        }
    }

    static func json(_ payload: [String: Any]) -> String {
        guard JSONSerialization.isValidJSONObject(payload),
              let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys, .withoutEscapingSlashes]),
              let s = String(data: data, encoding: .utf8)
        else {
            return "{\"kind\":\"log\",\"msg\":\"sim-console: unencodable payload\"}"
        }
        return s
    }
}
