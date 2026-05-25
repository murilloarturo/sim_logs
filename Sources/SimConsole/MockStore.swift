import Foundation

/// Reads mock rules from the panel-managed JSON file and serves them to
/// `SimConsoleURLProtocol` so matching requests get a synthesized response
/// instead of a network call.
///
/// Path resolution by environment:
///   - **Simulator**: `<SIMULATOR_HOST_HOME>/.sim-console/mocks-<bundle>.json`.
///     The simulator runtime exports `SIMULATOR_HOST_HOME` pointing at the Mac
///     user's home, and sim builds run under that UID with a relaxed sandbox
///     so the file is directly readable.
///   - **Physical device**: `<NSDocumentDirectory>/sim-console/mocks.json`.
///     The macOS panel pushes the file here via
///     `xcrun devicectl device copy to --domain-type appDataContainer`.
///     The panel and the SDK never share a filesystem on device, so this is
///     the cheapest transport that doesn't need a custom over-USB protocol.
///
/// Transport choice in both cases: the file is written atomically (temp +
/// rename or `devicectl copy`). We re-read on demand based on `mtime` rather
/// than installing a `DispatchSource` filesystem watcher — the atomic-rename
/// pattern reliably invalidates `EVFILT_VNODE` watchers, and a `stat()` per
/// outbound request is microseconds. Only requests that pass `canInit` ever
/// hit the lookup.
public final class MockStore {

    public static let shared = MockStore()

    private let queue = DispatchQueue(label: "com.simconsole.mocks", attributes: .concurrent)
    private var bundleId: String = ""
    private var path: String = ""
    private var cachedMocks: [Mock] = []
    private var cachedMTime: TimeInterval = 0

    private init() {}

    public func configure(bundleId: String) {
        queue.async(flags: .barrier) {
            self.bundleId = bundleId
            self.path = Self.resolvedPath(for: bundleId)
            self.cachedMocks = []
            self.cachedMTime = 0
            NSLog("[SimConsole] mocks path = \(self.path)")
        }
    }

    private static func resolvedPath(for bundleId: String) -> String {
        #if targetEnvironment(simulator)
        let env = ProcessInfo.processInfo.environment
        let home = env["SIMULATOR_HOST_HOME"] ?? NSHomeDirectory()
        let dir = (home as NSString).appendingPathComponent(".sim-console")
        return (dir as NSString).appendingPathComponent("mocks-\(bundleId).json")
        #else
        // App sandbox Documents dir — the only writable location reachable
        // from `devicectl copy to` with `--domain-type appDataContainer`.
        let docs = NSSearchPathForDirectoriesInDomains(.documentDirectory, .userDomainMask, true).first
            ?? NSHomeDirectory()
        let dir = (docs as NSString).appendingPathComponent("sim-console")
        return (dir as NSString).appendingPathComponent("mocks.json")
        #endif
    }

    public func findMock(for request: URLRequest) -> Mock? {
        // Mocking is active on both simulator and physical-device builds now.
        // Apps that link the package but skip `bootstrap` keep paying zero —
        // path is empty until configure() runs, so reloadIfChangedLocked returns
        // immediately with no mocks loaded.
        return queue.sync {
            reloadIfChangedLocked()
            for mock in cachedMocks where mock.enabled {
                if mock.match.matches(request) {
                    return mock
                }
            }
            return nil
        }
    }

    /// Public so tests can drive a forced reload from a known path.
    func _reloadFromPath(_ p: String) {
        queue.async(flags: .barrier) {
            self.path = p
            self.cachedMTime = 0
            self.reloadIfChangedLocked()
        }
    }

    func _currentMocks() -> [Mock] {
        queue.sync {
            reloadIfChangedLocked()
            return cachedMocks
        }
    }

    private func reloadIfChangedLocked() {
        guard !path.isEmpty else { return }
        let fm = FileManager.default
        guard let attrs = try? fm.attributesOfItem(atPath: path) else {
            // File missing → empty mocks
            if !cachedMocks.isEmpty { cachedMocks = [] }
            cachedMTime = 0
            return
        }
        let mtime = (attrs[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        if mtime == cachedMTime { return }
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else {
            cachedMocks = []
            cachedMTime = mtime
            return
        }
        do {
            let file = try JSONDecoder().decode(MockFile.self, from: data)
            cachedMocks = file.mocks
            cachedMTime = mtime
        } catch {
            // Malformed file — log + keep last good state to avoid flapping.
            NSLog("[SimConsole] mocks file at \(path) failed to parse: \(error)")
        }
    }
}
