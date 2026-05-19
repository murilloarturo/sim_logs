import Foundation
import SimConsole

/// Owns a `URLSession` whose configuration has `SimConsoleURLProtocol`
/// prepended to its `protocolClasses`. Every request issued through this
/// session is automatically captured and surfaced on the Network tab.
final class DemoNetworkClient: ObservableObject {
    @Published var lastResponse: String = ""
    @Published var isBusy: Bool = false

    let session: URLSession

    init() {
        let config = URLSessionConfiguration.default
        #if DEBUG
        config.protocolClasses = [SimConsoleURLProtocol.self] + (config.protocolClasses ?? [])
        #endif
        config.timeoutIntervalForRequest = 15
        self.session = URLSession(configuration: config)
    }

    @MainActor
    func fetch(_ url: URL, method: String = "GET", body: Data? = nil, contentType: String? = nil) async {
        isBusy = true
        defer { isBusy = false }
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.httpBody = body
        if let contentType { req.setValue(contentType, forHTTPHeaderField: "Content-Type") }
        do {
            let (data, _) = try await session.data(for: req)
            lastResponse = String(data: data, encoding: .utf8)?.prefix(400).description ?? "<\(data.count) bytes>"
        } catch {
            lastResponse = "error: \(error.localizedDescription)"
        }
    }
}
