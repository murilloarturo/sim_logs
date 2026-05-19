import Foundation

/// `URLProtocol` subclass that emits `SimConsole.network(...)` events for
/// every request/response handled by a `URLSessionConfiguration` it's
/// registered on.
///
/// Wire it on a custom session config:
///
///     #if DEBUG
///     let config = URLSessionConfiguration.default
///     config.protocolClasses = [SimConsoleURLProtocol.self] + (config.protocolClasses ?? [])
///     let session = URLSession(configuration: config)
///     #endif
///
/// Or globally for `URLSession.shared` (best-effort — `URLSession.shared`
/// snapshots its config at first use, so registering early matters):
///
///     #if DEBUG
///     URLProtocol.registerClass(SimConsoleURLProtocol.self)
///     #endif
///
/// The class disables itself when `SimConsole.isEnabled == false`, so
/// production builds that link the package but skip `bootstrap` pay zero
/// overhead beyond a single bool check per request.
public final class SimConsoleURLProtocol: URLProtocol {

    private static let handledKey = "com.simconsole.handled"

    private var session: URLSession?
    private var dataTask: URLSessionDataTask?
    private var startedAt: Date = .distantPast
    private var requestId: String = ""
    private var responseBuffer = Data()

    public override class func canInit(with request: URLRequest) -> Bool {
        guard SimConsole.isEnabled else { return false }
        if URLProtocol.property(forKey: handledKey, in: request) != nil { return false }
        guard let scheme = request.url?.scheme?.lowercased() else { return false }
        return scheme == "http" || scheme == "https"
    }

    public override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    public override class func requestIsCacheEquivalent(_ a: URLRequest, to b: URLRequest) -> Bool {
        super.requestIsCacheEquivalent(a, to: b)
    }

    public override func startLoading() {
        guard let mutable = (request as NSURLRequest).mutableCopy() as? NSMutableURLRequest else {
            client?.urlProtocol(self, didFailWithError: URLError(.unknown))
            return
        }
        URLProtocol.setProperty(true, forKey: Self.handledKey, in: mutable)

        startedAt = Date()
        requestId = UUID().uuidString

        SimConsole.network(
            request: requestId,
            method: request.httpMethod ?? "GET",
            url: request.url?.absoluteString ?? "",
            headers: request.allHTTPHeaderFields ?? [:],
            body: bodyString(of: request)
        )

        let config = URLSessionConfiguration.ephemeral
        session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
        dataTask = session?.dataTask(with: mutable as URLRequest)
        dataTask?.resume()
    }

    public override func stopLoading() {
        dataTask?.cancel()
        session?.invalidateAndCancel()
        session = nil
        dataTask = nil
    }

    private func bodyString(of request: URLRequest) -> String? {
        if let data = request.httpBody {
            return String(data: data, encoding: .utf8) ?? "<\(data.count) bytes>"
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
            return String(data: data, encoding: .utf8) ?? "<\(data.count) bytes>"
        }
        return nil
    }

    fileprivate func durationMs() -> Int {
        Int(Date().timeIntervalSince(startedAt) * 1000)
    }
}

extension SimConsoleURLProtocol: URLSessionDataDelegate {

    public func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse, completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        completionHandler(.allow)
    }

    public func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        client?.urlProtocol(self, didLoad: data)
        responseBuffer.append(data)
    }

    public func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        defer {
            session.invalidateAndCancel()
            self.session = nil
            self.dataTask = nil
        }
        if let error {
            SimConsole.network(error: requestId, durationMs: durationMs(), error: String(describing: error))
            client?.urlProtocol(self, didFailWithError: error)
            return
        }

        let http = task.response as? HTTPURLResponse
        let headers: [String: String] = (http?.allHeaderFields as? [String: String]) ?? [:]
        let bodyPreview = String(data: responseBuffer, encoding: .utf8)

        SimConsole.network(
            response: requestId,
            status: http?.statusCode ?? -1,
            durationMs: durationMs(),
            headers: headers,
            body: bodyPreview,
            byteSize: responseBuffer.count
        )
        client?.urlProtocolDidFinishLoading(self)
    }
}
