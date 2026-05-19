import Foundation

// Typed models for SimConsole events. Use these for self-documenting call
// sites, or fall back to the `[String: Any]` dictionary form on the
// `SimConsole.analytics(event:params:)` etc. entry points — both styles emit
// the same wire format.

extension SimConsole {

    public struct AnalyticsEvent {
        public var name: String
        public var params: [String: Any]
        public var screen: String?

        public init(name: String, params: [String: Any] = [:], screen: String? = nil) {
            self.name = name
            self.params = params
            self.screen = screen
        }
    }

    public struct ScreenView {
        public var name: String
        public var params: [String: Any]

        public init(name: String, params: [String: Any] = [:]) {
            self.name = name
            self.params = params
        }
    }

    public struct NetworkRequestEvent {
        public var id: String
        public var method: String
        public var url: String
        public var headers: [String: String]
        public var body: String?

        public init(
            id: String = UUID().uuidString,
            method: String,
            url: String,
            headers: [String: String] = [:],
            body: String? = nil
        ) {
            self.id = id
            self.method = method
            self.url = url
            self.headers = headers
            self.body = body
        }
    }

    public struct NetworkResponseEvent {
        public var id: String
        public var status: Int
        public var durationMs: Int
        public var headers: [String: String]
        public var body: String?
        public var byteSize: Int?

        public init(
            id: String,
            status: Int,
            durationMs: Int,
            headers: [String: String] = [:],
            body: String? = nil,
            byteSize: Int? = nil
        ) {
            self.id = id
            self.status = status
            self.durationMs = durationMs
            self.headers = headers
            self.body = body
            self.byteSize = byteSize
        }
    }

    public struct NetworkErrorEvent {
        public var id: String
        public var durationMs: Int
        public var error: String

        public init(id: String, durationMs: Int, error: String) {
            self.id = id
            self.durationMs = durationMs
            self.error = error
        }
    }

    public struct LogEvent {
        public var message: String
        public var level: SimConsole.Level
        public var fields: [String: Any]

        public init(message: String, level: SimConsole.Level = .info, fields: [String: Any] = [:]) {
            self.message = message
            self.level = level
            self.fields = fields
        }
    }

    // MARK: - Typed-model overloads (thin wrappers over the dict-form API)

    public static func track(_ event: AnalyticsEvent) {
        analytics(event: event.name, params: event.params, screen: event.screen)
    }

    public static func track(_ view: ScreenView) {
        screen(view.name, params: view.params)
    }

    public static func track(_ request: NetworkRequestEvent) {
        network(request: request.id, method: request.method, url: request.url,
                headers: request.headers, body: request.body)
    }

    public static func track(_ response: NetworkResponseEvent) {
        network(response: response.id, status: response.status,
                durationMs: response.durationMs, headers: response.headers,
                body: response.body, byteSize: response.byteSize)
    }

    public static func track(_ error: NetworkErrorEvent) {
        network(error: error.id, durationMs: error.durationMs, error: error.error)
    }

    public static func track(_ event: LogEvent) {
        log(event.message, level: event.level, fields: event.fields)
    }
}
