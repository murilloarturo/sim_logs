import Foundation

/// One mock rule. Persisted as a row in `~/.sim-console/mocks-<bundle-id>.json`.
public struct Mock: Codable, Identifiable, Equatable {
    public var id: String
    public var match: MockMatch
    public var response: MockResponse
    public var delayMs: Int
    public var enabled: Bool
    public var createdAt: String

    enum CodingKeys: String, CodingKey {
        case id, match, response, enabled
        case delayMs = "delay_ms"
        case createdAt = "created_at"
    }

    public init(
        id: String = UUID().uuidString,
        match: MockMatch,
        response: MockResponse,
        delayMs: Int = 0,
        enabled: Bool = true,
        createdAt: String = ISO8601DateFormatter().string(from: Date())
    ) {
        self.id = id
        self.match = match
        self.response = response
        self.delayMs = delayMs
        self.enabled = enabled
        self.createdAt = createdAt
    }
}

public struct MockMatch: Codable, Equatable {
    public var method: String
    public var url: String
    /// Forward-compatible: when set, the request body must contain this
    /// substring for the mock to apply. v1 UI does not expose this; the
    /// iOS side honors it so power-users editing the JSON by hand can use it.
    public var bodyContains: String?

    enum CodingKeys: String, CodingKey {
        case method, url
        case bodyContains = "body_contains"
    }

    public init(method: String, url: String, bodyContains: String? = nil) {
        self.method = method
        self.url = url
        self.bodyContains = bodyContains
    }

    /// Exact match on method + full URL. Optionally requires the request body
    /// to contain `bodyContains`.
    public func matches(_ request: URLRequest) -> Bool {
        guard let url = request.url?.absoluteString else { return false }
        guard method.uppercased() == (request.httpMethod ?? "GET").uppercased() else { return false }
        guard url == self.url else { return false }
        if let needle = bodyContains, !needle.isEmpty {
            let body = MockMatch.requestBodyString(request) ?? ""
            return body.contains(needle)
        }
        return true
    }

    fileprivate static func requestBodyString(_ request: URLRequest) -> String? {
        if let data = request.httpBody {
            return String(data: data, encoding: .utf8)
        }
        if let stream = request.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var data = Data()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let n = stream.read(&buffer, maxLength: buffer.count)
                if n <= 0 { break }
                data.append(buffer, count: n)
            }
            return String(data: data, encoding: .utf8)
        }
        return nil
    }
}

public struct MockResponse: Codable, Equatable {
    public var status: Int
    public var headers: [String: String]
    public var body: String?

    public init(status: Int, headers: [String: String] = [:], body: String? = nil) {
        self.status = status
        self.headers = headers
        self.body = body
    }
}

/// File-level wrapper persisted as JSON.
struct MockFile: Codable {
    var version: Int
    var mocks: [Mock]
}
