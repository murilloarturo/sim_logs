import Foundation

/// Reads mock rules from `~/.sim-console/mocks-<bundle-id>.json` and serves
/// them to `SimConsoleURLProtocol` so matching requests get a synthesized
/// response instead of a network call.
///
/// **Simulator-only.** On a real device the singleton is inert — `findMock`
/// always returns nil. Cross-process file access from inside an iOS app
/// relies on the simulator's relaxed sandbox, which doesn't exist on device.
///
/// Transport choice: the macOS app writes the file atomically (temp + rename).
/// We re-read on demand based on `mtime` instead of installing a
/// `DispatchSource` filesystem watcher — the atomic-rename pattern reliably
/// invalidates `EVFILT_VNODE` watchers, and an `stat()` per outbound request
/// is microseconds. Only requests that pass `canInit` ever hit the lookup.
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
            // Inside the iOS simulator, `NSHomeDirectory()` is the app's
            // sandbox container — useless for cross-process file sharing
            // with the Mac. `SIMULATOR_HOST_HOME` is the host user's home,
            // exported by Apple's simulator runtime, and reachable from
            // simulator-builds because they run as Mac processes under the
            // user's UID.
            let env = ProcessInfo.processInfo.environment
            let home = env["SIMULATOR_HOST_HOME"] ?? NSHomeDirectory()
            let dir = (home as NSString).appendingPathComponent(".sim-console")
            self.path = (dir as NSString).appendingPathComponent("mocks-\(bundleId).json")
            self.cachedMocks = []
            self.cachedMTime = 0
            NSLog("[SimConsole] mocks path = \(self.path)")
        }
    }

    public func findMock(for request: URLRequest) -> Mock? {
        #if targetEnvironment(simulator)
        return queue.sync {
            reloadIfChangedLocked()
            for mock in cachedMocks where mock.enabled {
                if mock.match.matches(request) {
                    return mock
                }
            }
            return nil
        }
        #else
        return nil
        #endif
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
