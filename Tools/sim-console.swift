// sim-console — SwiftUI-based dev console that sits beside a running iOS
// Simulator. Row-based SwiftUI list (LazyVStack) so scroll + tab switching
// stay snappy regardless of how many entries accumulate.
//
// AX-positioning beside the Simulator window. `xcrun simctl spawn log stream`
// is the ingestion source for every tab. JSON payloads emitted by the
// companion SimConsole SDK get parsed into structured rows: paired
// net.request/net.response, named analytics events with collapsible params,
// generic log rows. Tabs that aren't structured (Errors, All) render the
// compact log-line as text.
//
// Usage:
//   sim-console --device <UDID> --tag "<sim window title>" \
//               [--alt-tag "<original name>"] \
//               [--app-label "App Name"] [--accent #7c9cff] \
//               [--width 560] [--gap 8] [--side right|left] \
//               [--level default|info|debug] \
//               --tab "<kind>|Name|<NSPredicate>" \
//               [--tab ...]
//
// Tab spec format: "<kind>|<Name>|<predicate>". `kind` is one of:
//   network    — parses net.request / net.response / net.error JSON into rows
//   analytics  — parses analytics / screen JSON into rows
//   text       — raw log lines (App / Errors / All, etc.)
//
// At least one --tab is required.

import Cocoa
import SwiftUI
import ApplicationServices
import Combine

// ---------------------------------------------------------------------------
// MARK: - CLI args

enum Platform: String { case ios, android, web }

struct TabSpec {
    enum Kind: String { case network, analytics, text, metric }
    let kind: Kind
    let name: String
    /// Source-filter expression. On iOS this is an NSPredicate passed to
    /// `simctl spawn log stream --predicate`. On Android it's the trailing
    /// filterspec passed to `adb logcat`, e.g. `SimConsole.analytics:V *:S`.
    let predicate: String
}

struct Args {
    var platform: Platform = .ios
    var device = ""
    var tag = ""
    var altTag = ""
    var appLabel = ""
    var accent = Color(red: 0.49, green: 0.61, blue: 1.0)
    var width: CGFloat = 560
    var gap: CGFloat = 8
    var side = "right"
    var level = "info"
    var tabs: [TabSpec] = []
    var exportTo: String = ""
    var bundleId: String = ""
    /// Path to the `adb` binary. Discovered at startup when empty.
    var adbPath: String = ""
    /// Path to `idevicesyslog` (libimobiledevice). Discovered at startup when
    /// empty. Used for streaming logs from a USB-connected iPhone since
    /// `xcrun devicectl` doesn't have a log-stream subcommand.
    var ideviceSyslogPath: String = ""
    /// Explicit override for the iOS device executable name passed to
    /// `idevicesyslog -p <name>`. Defaults to the bundle id's last component,
    /// which only works when CFBundleExecutable matches that suffix (e.g.
    /// bundle id `com.acme.demoapp` and executable `demoapp`). For projects
    /// where PRODUCT_NAME differs in case (`DemoApp`) or shape, callers can
    /// pass `--ios-process-name DemoApp` to override.
    var iosProcessName: String = ""
    /// When true, the panel is a user-positionable floating window rather
    /// than a borderless overlay that tracks the sim/emulator. Required for
    /// USB-connected physical devices (no on-screen device window to dock to).
    var detached: Bool = false
    /// Path to the NDJSON file the web bridge appends events to. Each tab
    /// spawns `tail -n 0 -F <path>` so events stream in line-by-line — same
    /// shape as `simctl spawn log stream` output. Defaults to
    /// `~/.sim-console/web-bridge-events.log` when --platform web is passed.
    var webSource: String = ""
}

func parseColor(_ hex: String) -> Color? {
    var s = hex
    if s.hasPrefix("#") { s.removeFirst() }
    guard s.count == 6, let v = UInt32(s, radix: 16) else { return nil }
    let r = Double((v >> 16) & 0xff) / 255.0
    let g = Double((v >> 8) & 0xff) / 255.0
    let b = Double(v & 0xff) / 255.0
    return Color(red: r, green: g, blue: b)
}

func parseTabSpec(_ raw: String) -> TabSpec? {
    let parts = raw.split(separator: "|", maxSplits: 2, omittingEmptySubsequences: false)
    guard parts.count == 3,
          let kind = TabSpec.Kind(rawValue: String(parts[0]).trimmingCharacters(in: .whitespaces))
    else { return nil }
    let name = String(parts[1]).trimmingCharacters(in: .whitespaces)
    let predicate = String(parts[2]).trimmingCharacters(in: .whitespaces)
    guard !name.isEmpty, !predicate.isEmpty else { return nil }
    return TabSpec(kind: kind, name: name, predicate: predicate)
}

func parseArgs() -> Args {
    var a = Args()
    let argv = CommandLine.arguments
    var i = 1
    while i < argv.count - 1 {
        switch argv[i] {
        case "--device":     a.device = argv[i+1]; i += 2
        case "--tag":        a.tag = argv[i+1]; i += 2
        case "--alt-tag":    a.altTag = argv[i+1]; i += 2
        case "--app-label":  a.appLabel = argv[i+1]; i += 2
        case "--accent":     if let c = parseColor(argv[i+1]) { a.accent = c }; i += 2
        case "--width":      a.width = CGFloat(Int(argv[i+1]) ?? 560); i += 2
        case "--gap":        a.gap = CGFloat(Int(argv[i+1]) ?? 8); i += 2
        case "--side":       a.side = argv[i+1]; i += 2
        case "--level":      a.level = argv[i+1]; i += 2
        case "--tab":
            if let t = parseTabSpec(argv[i+1]) { a.tabs.append(t) }
            i += 2
        case "--export-to": a.exportTo = argv[i+1]; i += 2
        case "--bundle-id": a.bundleId = argv[i+1]; i += 2
        case "--platform":
            if let p = Platform(rawValue: argv[i+1]) { a.platform = p }
            i += 2
        case "--adb-path":  a.adbPath = argv[i+1]; i += 2
        case "--idevicesyslog-path": a.ideviceSyslogPath = argv[i+1]; i += 2
        case "--ios-process-name": a.iosProcessName = argv[i+1]; i += 2
        case "--web-source": a.webSource = argv[i+1]; i += 2
        case "--detached":  a.detached = true; i += 1
        default: i += 1
        }
    }
    if a.platform == .android && a.adbPath.isEmpty {
        a.adbPath = resolveAdbPath()
    }
    if a.platform == .ios && a.detached && a.ideviceSyslogPath.isEmpty {
        a.ideviceSyslogPath = resolveIdeviceSyslogPath()
    }
    if a.platform == .web {
        // Web is always "detached" — there's no on-screen device window to
        // dock against, and the panel is the only visible surface. Default
        // the source file path if the caller didn't pass one.
        a.detached = true
        if a.webSource.isEmpty {
            a.webSource = (NSHomeDirectory() as NSString)
                .appendingPathComponent(".sim-console/web-bridge-events.log")
        }
    }
    return a
}

/// Resolve a path to `adb`. GUI-launched processes don't inherit the user's
/// shell PATH, so we probe common install locations explicitly before falling
/// back to the bare command name.
func resolveAdbPath() -> String {
    let candidates = [
        ProcessInfo.processInfo.environment["ADB"] ?? "",
        NSHomeDirectory() + "/Library/Android/sdk/platform-tools/adb",
        "/opt/homebrew/bin/adb",
        "/usr/local/bin/adb",
        "/usr/bin/adb",
    ]
    for c in candidates where !c.isEmpty && FileManager.default.isExecutableFile(atPath: c) {
        return c
    }
    return "adb"
}

/// Resolve `idevicesyslog` (from libimobiledevice). Homebrew installs to
/// `/opt/homebrew/bin/` on Apple Silicon and `/usr/local/bin/` on Intel.
func resolveIdeviceSyslogPath() -> String {
    let candidates = [
        ProcessInfo.processInfo.environment["IDEVICESYSLOG"] ?? "",
        "/opt/homebrew/bin/idevicesyslog",
        "/usr/local/bin/idevicesyslog",
    ]
    for c in candidates where !c.isEmpty && FileManager.default.isExecutableFile(atPath: c) {
        return c
    }
    return "idevicesyslog"
}

// ---------------------------------------------------------------------------
// MARK: - Diagnostic

let diagURL = URL(fileURLWithPath: "/tmp/sim-console.log")
func diag(_ msg: String) {
    let ts = ISO8601DateFormatter().string(from: Date())
    let line = "[\(ts)] \(msg)\n"
    if let data = line.data(using: .utf8) {
        if FileManager.default.fileExists(atPath: diagURL.path) {
            if let h = try? FileHandle(forWritingTo: diagURL) {
                h.seekToEndOfFile(); h.write(data); try? h.close()
            }
        } else {
            try? data.write(to: diagURL)
        }
    }
}

// ---------------------------------------------------------------------------
// MARK: - Accessibility helpers (mirror sim-frame + sim-overlay)

func nudgeAXPrompt() -> Bool {
    let opts: NSDictionary = [
        kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true
    ]
    let trusted = AXIsProcessTrustedWithOptions(opts)
    diag("AX trusted: \(trusted)")
    return trusted
}

func findSimulatorWindow(matching tag: String, fallback: String = "") -> AXUIElement? {
    var firstFallback: AXUIElement?
    for app in NSWorkspace.shared.runningApplications {
        guard app.bundleIdentifier == "com.apple.iphonesimulator" else { continue }
        let appRef = AXUIElementCreateApplication(app.processIdentifier)
        var windowsRef: AnyObject?
        AXUIElementCopyAttributeValue(appRef, kAXWindowsAttribute as CFString, &windowsRef)
        guard let windows = windowsRef as? [AXUIElement] else { continue }
        for window in windows {
            var titleRef: AnyObject?
            AXUIElementCopyAttributeValue(window, kAXTitleAttribute as CFString, &titleRef)
            guard let title = titleRef as? String else { continue }
            if title.contains(tag) { return window }
            if !fallback.isEmpty && firstFallback == nil && title.contains(fallback) {
                firstFallback = window
            }
        }
    }
    return firstFallback
}

func windowFrame(_ window: AXUIElement) -> CGRect? {
    var positionRef: AnyObject?
    var sizeRef: AnyObject?
    guard AXUIElementCopyAttributeValue(window, kAXPositionAttribute as CFString, &positionRef) == .success,
          AXUIElementCopyAttributeValue(window, kAXSizeAttribute as CFString, &sizeRef) == .success
    else { return nil }
    var pos = CGPoint.zero
    var size = CGSize.zero
    AXValueGetValue(positionRef as! AXValue, .cgPoint, &pos)
    AXValueGetValue(sizeRef as! AXValue, .cgSize, &size)
    return CGRect(origin: pos, size: size)
}

/// Convert a top-down screen-space rect (from AX or CGWindow) into Cocoa's
/// bottom-up space. The *primary* display anchors both coordinate systems:
/// CGWindow's origin is the primary's top-left; Cocoa's origin is the
/// primary's bottom-left. The flip is `cocoa_y = primary_height - cg_y - cg_height`.
///
/// `NSScreen.screens.first` is documented as having unspecified order — on a
/// multi-monitor setup the first array entry may not be the primary, which
/// would make the conversion silently wrong. Find the primary explicitly by
/// the screen whose Cocoa frame.origin == .zero (the menu-bar display).
func axToCocoa(_ axRect: CGRect) -> CGRect {
    let primary = NSScreen.screens.first(where: { $0.frame.origin == .zero })
        ?? NSScreen.main
        ?? NSScreen.screens.first
    guard let primary else { return axRect }
    let primaryHeight = primary.frame.height
    return CGRect(
        x: axRect.origin.x,
        y: primaryHeight - axRect.origin.y - axRect.size.height,
        width: axRect.size.width,
        height: axRect.size.height
    )
}

func simulatorAppRunning() -> Bool {
    NSWorkspace.shared.runningApplications.contains {
        $0.bundleIdentifier == "com.apple.iphonesimulator"
    }
}

/// The Android Emulator (`qemu-system-*`) isn't a bundled `.app` so neither
/// `NSWorkspace.runningApplications` nor AX surfaces its windows directly. We
/// query the window server instead via `CGWindowListCopyWindowInfo`, which
/// enumerates every on-screen window by owner process name. Returns the
/// device-screen window's frame in CGWindow top-down coordinates, ready to
/// flip through `axToCocoa(_:)`.
///
/// `tag` is accepted for symmetry with the iOS lookup but currently unused —
/// qemu windows have empty titles, so we identify by owner name plus pick the
/// largest layer-0 window (which is always the device screen; toolbars and
/// extended controls are smaller / on higher layers).
func findEmulatorWindowFrame(matching tag: String = "") -> CGRect? {
    // The Android emulator can render as multiple adjacent on-screen windows
    // — e.g. the Pixel device screen plus a separate extended-controls
    // sidebar (`qemu-system-*`) sitting right next to it. The user sees them
    // as one visual footprint, so the docking edge for SimConsole must be the
    // outer edge of the *union* of all qemu windows, not just the largest one.
    //
    // Returning only the biggest window would dock the panel *inside* the
    // sidebar (or leave a sidebar-sized gap on the other side), which the
    // user perceives as "attach is broken".
    //
    // We anchor on the largest qemu window (the device screen — at least
    // 100px tall to skip the thin titlebar widgets), then expand the rect to
    // include every other layer-0 qemu window whose bounds intersect or
    // touch it. Touch test uses 2px slop so a 0-1px CGWindow gap between
    // adjacent windows still counts as adjacent.
    let list = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] ?? []
    var rects: [CGRect] = []
    for w in list {
        let owner = (w[kCGWindowOwnerName as String] as? String ?? "").lowercased()
        guard owner.hasPrefix("qemu") else { continue }
        guard (w[kCGWindowLayer as String] as? Int ?? -1) == 0 else { continue }
        guard let bnds = w[kCGWindowBounds as String] as? [String: NSNumber] else { continue }
        let x = CGFloat(truncating: bnds["X"] ?? 0)
        let y = CGFloat(truncating: bnds["Y"] ?? 0)
        let width = CGFloat(truncating: bnds["Width"] ?? 0)
        let height = CGFloat(truncating: bnds["Height"] ?? 0)
        guard width > 0, height > 0 else { continue }
        rects.append(CGRect(x: x, y: y, width: width, height: height))
    }
    // Anchor on the largest one taller than 100px — that's the device screen.
    let anchor = rects
        .filter { $0.height > 100 }
        .max { ($0.width * $0.height) < ($1.width * $1.height) }
    guard var combined = anchor else { return nil }
    // Iteratively absorb any other qemu window that's visually adjacent
    // *side-by-side* with the current combined rect. The emulator's
    // sidebar/extended-controls window typically sits a few pixels to the
    // right of the device screen (observed: ~7px gap), so we use a 12px X
    // slop to count those as adjacent.
    //
    // Vertical filter: a popup menu / dropdown from the toolbar can appear
    // above or below the device screen with no Y-overlap; absorbing those
    // makes the union rect jitter every tick. So require at least 50% Y
    // overlap with the current combined rect before absorbing.
    let xSlop: CGFloat = 12
    var grew = true
    while grew {
        grew = false
        for r in rects where r != combined && !combined.contains(r) {
            // X-adjacency: their X ranges touch (with 12px slop)
            let xTouches = (r.minX - xSlop) <= combined.maxX && (r.maxX + xSlop) >= combined.minX
            if !xTouches { continue }
            // Y-overlap >= 50% of the smaller window's height
            let yOverlap = max(0, min(combined.maxY, r.maxY) - max(combined.minY, r.minY))
            let yRequired = 0.5 * min(combined.height, r.height)
            if yOverlap < yRequired { continue }
            combined = combined.union(r)
            grew = true
        }
    }
    return combined
}

/// Mirrors `simulatorAppRunning()`. CGWindowList sees qemu's windows even
/// though it has no app bundle, so we just check whether any survive.
/// Persists the panel's last on-screen frame so the user doesn't have to
/// re-position the detached panel every launch. Stored at
/// `~/.sim-console/panel-frame-<bundleId>.json`. Falls back to a sensible
/// default rect (right-of-primary-screen) when no saved state exists.
final class PanelFrameStore {
    private let path: String

    init(bundleId: String) {
        let dir = (NSHomeDirectory() as NSString).appendingPathComponent(".sim-console")
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        // Sanitize bundle id for filesystem use (dots are fine, but be paranoid).
        let safe = bundleId.replacingOccurrences(of: "/", with: "_")
        self.path = (dir as NSString).appendingPathComponent("panel-frame-\(safe).json")
    }

    func load() -> NSRect? {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Double],
              let x = obj["x"], let y = obj["y"],
              let w = obj["width"], let h = obj["height"],
              w > 100, h > 100
        else { return nil }
        return NSRect(x: x, y: y, width: w, height: h)
    }

    func save(_ rect: NSRect) {
        let obj: [String: Double] = [
            "x": Double(rect.minX),
            "y": Double(rect.minY),
            "width": Double(rect.width),
            "height": Double(rect.height),
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys]) else { return }
        try? data.write(to: URL(fileURLWithPath: path), options: [.atomic])
    }
}

func emulatorAppRunning() -> Bool {
    let list = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] ?? []
    for w in list {
        let owner = (w[kCGWindowOwnerName as String] as? String ?? "").lowercased()
        if owner.hasPrefix("qemu") { return true }
    }
    return false
}

// ---------------------------------------------------------------------------
// MARK: - Models

struct NetworkEntry: Identifiable {
    let id: String
    let method: String
    let url: String
    var requestHeaders: [String: String]
    var requestBody: String?
    var status: Int?
    var durationMs: Int?
    var responseHeaders: [String: String] = [:]
    var responseBody: String?
    var byteSize: Int?
    var error: String?
    var mocked: Bool = false
    let createdAt: Date

    var hostAndPath: String {
        guard let u = URL(string: url) else { return url }
        let host = u.host ?? ""
        let path = u.path.isEmpty ? "/" : u.path
        let query = (u.query.map { "?\($0)" }) ?? ""
        return host + path + query
    }
}

struct AnalyticsEntry: Identifiable {
    let id: UUID = UUID()
    let kind: String           // "analytics" | "screen"
    let event: String
    let params: [String: AnyCodable]
    let screen: String?
    let timestamp: Date
}

struct TextEntry: Identifiable {
    let id: UUID = UUID()
    let line: String
    let messageType: MessageType
    let timestamp: Date

    enum MessageType {
        case `default`, info, debug, error, fault
    }
}

// AnyCodable so JSON params with mixed value types decode without ceremony.
struct AnyCodable: Codable, Hashable {
    let value: Any

    init(_ value: Any) { self.value = value }

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil()                                { self.value = NSNull() }
        else if let v = try? c.decode(Bool.self)        { self.value = v }
        else if let v = try? c.decode(Int.self)         { self.value = v }
        else if let v = try? c.decode(Double.self)      { self.value = v }
        else if let v = try? c.decode(String.self)      { self.value = v }
        else if let v = try? c.decode([AnyCodable].self){ self.value = v.map(\.value) }
        else if let v = try? c.decode([String: AnyCodable].self) {
            self.value = v.mapValues(\.value)
        } else {
            self.value = NSNull()
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch value {
        case let v as Bool:    try c.encode(v)
        case let v as Int:     try c.encode(v)
        case let v as Double:  try c.encode(v)
        case let v as String:  try c.encode(v)
        case let v as [Any]:   try c.encode(v.map(AnyCodable.init))
        case let v as [String: Any]: try c.encode(v.mapValues(AnyCodable.init))
        default: try c.encodeNil()
        }
    }

    static func == (lhs: AnyCodable, rhs: AnyCodable) -> Bool {
        String(describing: lhs.value) == String(describing: rhs.value)
    }
    func hash(into h: inout Hasher) { h.combine(String(describing: value)) }

    var display: String {
        switch value {
        case let v as String: return v
        case let v as Bool: return String(v)
        case let v as Int: return String(v)
        case let v as Double: return String(v)
        case is NSNull: return "null"
        case let v as [Any]: return "[" + v.map { AnyCodable($0).display }.joined(separator: ", ") + "]"
        case let v as [String: Any]:
            let pairs = v.map { "\($0.key): \(AnyCodable($0.value).display)" }
            return "{" + pairs.joined(separator: ", ") + "}"
        default: return String(describing: value)
        }
    }
}

// MARK: - Metrics (samples, milestones, signposts, gauges, counters, hangs)

struct MetricSample: Identifiable {
    let id: UUID = UUID()
    let name: String              // "memory.resident_mb", "fps.avg_1s", etc.
    let value: Double
    let timestamp: Date
    let fields: [String: AnyCodable]
}

struct MetricMilestone: Identifiable {
    let id: UUID = UUID()
    let name: String
    let msSinceLaunch: Int
    let timestamp: Date
    let fields: [String: AnyCodable]
}

struct MetricSignpost: Identifiable {
    let id: UUID = UUID()
    let name: String
    let durationMs: Int
    let timestamp: Date
    let fields: [String: AnyCodable]
}

struct MetricGauge: Identifiable {
    let id: UUID = UUID()
    let name: String
    let value: Double
    let timestamp: Date
    let fields: [String: AnyCodable]
}

struct MetricCounter: Identifiable {
    let id: UUID = UUID()
    let name: String
    let delta: Double
    let total: Double
    let timestamp: Date
    let fields: [String: AnyCodable]
}

struct MetricHang: Identifiable {
    let id: UUID = UUID()
    let durationMs: Int
    let timestamp: Date
}

/// Canonical app-launch event — emitted exactly once per process by the iOS
/// SDK when `SimConsole.metric.appFinishLaunching()` is called. The panel
/// reads only the FIRST such event so the "LAUNCH" header doesn't update
/// when the user revisits a view.
struct MetricLaunch: Identifiable {
    let id: UUID = UUID()
    let ms: Int
    let timestamp: Date
}

enum MetricEntry: Identifiable {
    case sample(MetricSample)
    case milestone(MetricMilestone)
    case signpost(MetricSignpost)
    case gauge(MetricGauge)
    case counter(MetricCounter)
    case hang(MetricHang)
    case launch(MetricLaunch)

    var id: String {
        switch self {
        case .sample(let e): return "sm-\(e.id.uuidString)"
        case .milestone(let e): return "ml-\(e.id.uuidString)"
        case .signpost(let e): return "sp-\(e.id.uuidString)"
        case .gauge(let e): return "gg-\(e.id.uuidString)"
        case .counter(let e): return "ct-\(e.id.uuidString)"
        case .hang(let e): return "hg-\(e.id.uuidString)"
        case .launch(let e): return "lc-\(e.id.uuidString)"
        }
    }
}

enum TabEntry: Identifiable {
    case network(NetworkEntry)
    case analytics(AnalyticsEntry)
    case text(TextEntry)
    case metric(MetricEntry)

    var id: String {
        switch self {
        case .network(let e): return "net-\(e.id)"
        case .analytics(let e): return "ana-\(e.id.uuidString)"
        case .text(let e): return "txt-\(e.id.uuidString)"
        case .metric(let e): return "met-\(e.id)"
        }
    }
}

// ---------------------------------------------------------------------------
// MARK: - Exporter (NDJSON sink for MCP / external consumers)

/// Appends one JSON object per line to `path` for every entry that flows
/// through any tab. Network entries get re-emitted every time their row
/// state changes (request → response → headers → body), so a consumer can
/// either replay all events or dedup by `(kind, id)` and take the latest.
///
/// The file is truncated on startup so each `sim-console` run produces a
/// fresh log.
final class Exporter {
    let path: String
    private let queue = DispatchQueue(label: "sim-console.exporter", qos: .utility)
    private var handle: FileHandle?

    init?(path: String) {
        guard !path.isEmpty else { return nil }
        let url = URL(fileURLWithPath: path)
        let dir = url.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: path, contents: nil)
        guard let h = try? FileHandle(forWritingTo: url) else {
            diag("exporter: failed to open \(path)")
            return nil
        }
        self.path = path
        self.handle = h
        diag("exporter: writing to \(path)")
    }

    func write(_ payload: [String: Any]) {
        queue.async { [weak self] in
            guard let self,
                  let handle = self.handle,
                  JSONSerialization.isValidJSONObject(payload),
                  let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys, .withoutEscapingSlashes])
            else { return }
            handle.write(data)
            handle.write(Data([0x0a]))
        }
    }
}

// ---------------------------------------------------------------------------
// MARK: - Chunk reassembly

/// Reassembles oversized payloads that the Android SDK splits across multiple
/// logcat lines. Each piece is a `{kind:"chunk", id, i, n, part}` envelope; we
/// buffer them by `id` and surface the concatenated `part`s as a single JSON
/// string once all `n` pieces have arrived.
///
/// Used by every tab — iOS doesn't currently chunk, but the assembler is a
/// no-op for non-chunk lines so wiring it unconditionally has zero cost and
/// keeps the dispatch path identical across platforms.
final class ChunkAssembler {
    private struct Pending {
        let total: Int
        var parts: [Int: String]
        var firstSeen: Date
    }
    private var pending: [String: Pending] = [:]
    /// Drop incomplete chunk groups after this many seconds — bounds memory in
    /// the face of a dropped device or crashed emitter that never finished a set.
    private let ttl: TimeInterval = 30

    /// Returns the line (or reassembled JSON) ready for downstream parsing, or
    /// `nil` if `rawLine` was a chunk envelope and we're still waiting for more.
    func absorb(_ rawLine: String) -> String? {
        // Fast path: most log lines aren't chunk envelopes. Parse JSON only
        // when the marker substring is present. Tolerate optional whitespace
        // around the colon so the panel handles JSON from pretty-printers and
        // bridges as well as the compact form the SDK emits.
        guard rawLine.contains("\"kind\":\"chunk\"") ||
              rawLine.contains("\"kind\": \"chunk\"")
        else { return rawLine }

        guard let payload = Self.extractJson(rawLine),
              let data = payload.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              (obj["kind"] as? String) == "chunk",
              let id = obj["id"] as? String,
              let i = obj["i"] as? Int,
              let n = obj["n"] as? Int,
              let part = obj["part"] as? String
        else {
            // Looked like a chunk but didn't parse — let the caller try normal dispatch.
            return rawLine
        }

        gcExpired()
        var pen = pending[id] ?? Pending(total: n, parts: [:], firstSeen: Date())
        pen.parts[i] = part
        pending[id] = pen

        if pen.parts.count >= n {
            pending.removeValue(forKey: id)
            return (0..<n).compactMap { pen.parts[$0] }.joined()
        }
        return nil
    }

    private func gcExpired() {
        let cutoff = Date().addingTimeInterval(-ttl)
        pending = pending.filter { $0.value.firstSeen > cutoff }
    }

    private static func extractJson(_ line: String) -> String? {
        guard let r = line.range(of: "{") else { return nil }
        return String(line[r.lowerBound...]).replacingOccurrences(of: "\\134", with: "\\")
    }
}

// ---------------------------------------------------------------------------
// MARK: - Tab view model

final class TabViewModel: ObservableObject, Identifiable {
    let id: String
    let spec: TabSpec
    @Published var entries: [TabEntry] = []
    @Published var unread: Int = 0
    @Published var filterQuery: String = ""

    private var process: Process?
    private var carry: String = ""
    private var requestIndex: [String: Int] = [:]  // net id → position in entries
    private let maxEntries: Int = 1000
    private let chunker = ChunkAssembler()
    weak var exporter: Exporter?
    /// Source-module substring to match in each idevicesyslog line. On the
    /// iOS-device path idevicesyslog only filters by process name and dumps
    /// every os_log call under that process — UIKitCore, RunningBoardServices,
    /// HangTracer, CoreFoundation, etc. Without an additional filter every
    /// tab would fill its 1000-entry buffer with UIKit chatter and evict the
    /// real SimConsole events within seconds.
    ///
    /// Apple's unified log attaches the calling Swift module name to each
    /// record, and idevicesyslog renders that in parens after the process:
    ///   "May 26 11:08 DemoApp(SimConsole)[49149] <Notice>: {...}"
    ///   "May 26 11:08 DemoApp(UIKitCore)[49149] <Notice>: handleKeyboard..."
    /// We match on "(SimConsole)[" to accept SDK emissions and reject the
    /// rest. The per-tab kind dispatch downstream then routes JSON events to
    /// the right typed view.
    ///
    /// Empty string means "accept everything" — used by the "All" tab so the
    /// user can still see UIKit / RunningBoardServices noise when debugging.
    private var iosDeviceLineFilter: String = ""

    init(spec: TabSpec) {
        self.id = "\(spec.kind.rawValue)-\(spec.name)"
        self.spec = spec
    }

    func start(args: Args) {
        // For the USB-device path, idevicesyslog can only filter by process
        // name. Typed tabs (metric/network/analytics + the "Logs" event tab)
        // want only SDK emissions and would otherwise be drowned in UIKit
        // chatter. The "All" tab — identified by the absence of a category
        // constraint in the tab's predicate — wants the firehose so a
        // developer can see the entire process's log stream.
        if args.platform == .ios && args.detached {
            let hasCategoryConstraint = Self.extractCategoryFromPredicate(spec.predicate).isEmpty == false
            iosDeviceLineFilter = hasCategoryConstraint ? "(SimConsole)[" : ""
        }
        switch args.platform {
        case .ios:
            if args.detached {
                startIOSDevice(udid: args.device, ideviceSyslogPath: args.ideviceSyslogPath, bundleId: args.bundleId, iosProcessName: args.iosProcessName)
            } else {
                startIOSSimulator(device: args.device, level: args.level)
            }
        case .android:
            startAndroid(serial: args.device, adbPath: args.adbPath)
        case .web:
            startWeb(source: args.webSource)
        }
    }

    /// Spawn `tail -n 0 -F <file>` so each tab streams the NDJSON events the
    /// web bridge appends. `-F` (capital) survives log rotation; `-n 0` skips
    /// the historical backlog so we only see lines emitted after the panel
    /// attaches (mirrors `adb logcat -T 1` and `simctl spawn log stream`).
    /// The per-tab `kind`-dispatch in `ingest` filters lines to the right
    /// typed view — no extra predicate filter needed since the bridge only
    /// writes SDK events.
    private func startWeb(source: String) {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/tail")
        proc.arguments = ["-n", "0", "-F", source]
        runStreamingProcess(proc, label: "web")
    }

    /// Pull the `category == "X"` constraint out of an NSPredicate string.
    /// Returns "" if the predicate doesn't have one — e.g. the "All" tab.
    private static func extractCategoryFromPredicate(_ predicate: String) -> String {
        // Match: category == "metric" (with optional whitespace around ==).
        // The predicate strings the skill emits are stable enough for a
        // simple regex; we explicitly do NOT try to parse the whole NSPredicate.
        guard let r = predicate.range(of: #"category\s*==\s*\"([^\"]+)\""#, options: .regularExpression)
        else { return "" }
        // Slice out just the captured group.
        let slice = predicate[r]
        guard let q = slice.range(of: "\"") else { return "" }
        let after = slice.index(after: q.lowerBound)
        guard let qEnd = slice.range(of: "\"", range: after..<slice.endIndex) else { return "" }
        return String(slice[after..<qEnd.lowerBound])
    }

    private func startIOSSimulator(device: String, level: String) {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        proc.arguments = [
            "simctl", "spawn", device, "log", "stream",
            "--predicate", spec.predicate,
            "--level", level,
            "--style", "compact"
        ]
        runStreamingProcess(proc, label: "ios-sim")
    }

    /// Spawn `idevicesyslog -u <udid> [-p <proc>]` for USB-connected iPhones.
    /// Output format is similar enough to `log stream --style compact` that
    /// the existing JSON-substring extractor works without changes.
    ///
    /// `xcrun devicectl` was the originally planned tool but it has no
    /// log-stream subcommand — only `launch / signal / suspend / resume`.
    /// libimobiledevice's `idevicesyslog` is the only off-the-shelf path
    /// that surfaces the unified log from a paired USB device.
    private func startIOSDevice(udid: String, ideviceSyslogPath: String, bundleId: String, iosProcessName: String) {
        let proc = Process()
        let path = ideviceSyslogPath.isEmpty ? "idevicesyslog" : ideviceSyslogPath
        proc.executableURL = URL(fileURLWithPath: path.hasPrefix("/") ? path : "/usr/bin/env")
        var argv: [String] = []
        if !path.hasPrefix("/") { argv.append(path) }
        if !udid.isEmpty { argv.append(contentsOf: ["-u", udid]) }
        // `-x` makes idevicesyslog exit when the device disconnects, which
        // tickDetached picks up via the dead subprocess.
        argv.append("-x")
        // idevicesyslog's `-p` matches process names case-sensitively, which
        // equals the app's CFBundleExecutable on iOS. Caller can override via
        // --ios-process-name (e.g. when PRODUCT_NAME = "DemoApp" but bundle
        // id ends in "demoapp"). Without an override we derive from the
        // bundle id's last component as the best-effort default.
        let procName: String? = iosProcessName.isEmpty
            ? (bundleId.isEmpty ? nil : bundleId.split(separator: ".").last.map(String.init))
            : iosProcessName
        if let procName, !procName.isEmpty {
            argv.append(contentsOf: ["-p", procName])
        }
        proc.arguments = argv
        runStreamingProcess(proc, label: "ios-device")
    }

    /// Spawn `adb logcat -v threadtime -T 1 <filterspec>`. The `-T 1` flag skips
    /// the device's log backlog so we only see events generated after the panel
    /// starts. `spec.predicate` carries the logcat filterspec verbatim (e.g.
    /// `"SimConsole.analytics:V SimConsole.analytics.chunk:V *:S"`).
    private func startAndroid(serial: String, adbPath: String) {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: adbPath.hasPrefix("/") ? adbPath : "/usr/bin/env")
        var argv: [String] = []
        if !adbPath.hasPrefix("/") { argv.append(adbPath) }
        if !serial.isEmpty { argv.append(contentsOf: ["-s", serial]) }
        argv.append(contentsOf: ["logcat", "-v", "threadtime", "-T", "1"])
        // Split the filterspec on whitespace so each token is its own argv slot
        // — `adb logcat` expects them as separate args, not a single space-joined string.
        let filterTokens = spec.predicate.split(separator: " ").map(String.init)
        argv.append(contentsOf: filterTokens)
        proc.arguments = argv
        runStreamingProcess(proc, label: "android")
    }

    private func runStreamingProcess(_ proc: Process, label: String) {
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = pipe
        let handle = pipe.fileHandleForReading
        handle.readabilityHandler = { [weak self] h in
            guard let self else { return }
            let data = h.availableData
            if data.isEmpty { return }
            guard let s = String(data: data, encoding: .utf8) else { return }
            DispatchQueue.main.async { self.consume(s) }
        }
        do {
            try proc.run()
            self.process = proc
            diag("tab '\(spec.name)' [\(label)] pid=\(proc.processIdentifier) filter=\(spec.predicate)")
        } catch {
            diag("tab '\(spec.name)' [\(label)] stream failed: \(error)")
        }
    }

    func stop() {
        process?.terminate()
        process = nil
    }

    func clearUnread() { unread = 0 }

    // MARK: ingestion

    private func consume(_ chunk: String) {
        let combined = carry + chunk
        let lines = combined.split(separator: "\n", omittingEmptySubsequences: false)
        carry = combined.hasSuffix("\n") ? "" : String(lines.last ?? "")
        for line in lines.dropLast() where !line.isEmpty {
            let s = String(line)
            // iOS-device firehose filter: drop non-SDK lines for typed tabs.
            // See `iosDeviceLineFilter` doc for the rationale and format.
            if !iosDeviceLineFilter.isEmpty, !s.contains(iosDeviceLineFilter) {
                continue
            }
            ingest(s)
        }
    }

    private func ingest(_ rawLine: String) {
        if Self.isBoilerplate(rawLine) { return }
        // Reassemble Android-side chunked envelopes before per-kind dispatch.
        // For non-chunk lines this returns the input unchanged. For partial
        // chunks it returns nil and the line is swallowed until the set completes.
        guard let resolved = chunker.absorb(rawLine) else { return }
        switch spec.kind {
        case .network:   ingestNetwork(resolved)
        case .analytics: ingestAnalytics(resolved)
        case .text:      ingestText(resolved)
        case .metric:    ingestMetric(resolved)
        }
    }

    private func ingestMetric(_ rawLine: String) {
        guard let payload = Self.extractJson(rawLine),
              let data = payload.data(using: .utf8) else {
            ingestText(rawLine); return
        }
        struct Decoded: Decodable {
            let kind: String?
            let name: String?
            let value: Double?
            let duration_ms: Int?
            let ms_since_launch: Int?
            let ms: Int?
            let delta: Double?
            let total: Double?
            let t: Double?
            let fields: [String: AnyCodable]?
        }
        guard let d = try? JSONDecoder().decode(Decoded.self, from: data),
              let kind = d.kind else {
            ingestText(rawLine); return
        }
        let ts = d.t.flatMap { Date(timeIntervalSince1970: $0) } ?? Date()
        let fields = d.fields ?? [:]
        switch kind {
        case "metric.sample":
            guard let name = d.name, let value = d.value else { return }
            append(.metric(.sample(MetricSample(name: name, value: value, timestamp: ts, fields: fields))))
        case "metric.milestone":
            guard let name = d.name, let ms = d.ms_since_launch else { return }
            append(.metric(.milestone(MetricMilestone(name: name, msSinceLaunch: ms, timestamp: ts, fields: fields))))
        case "metric.signpost":
            guard let name = d.name, let ms = d.duration_ms else { return }
            append(.metric(.signpost(MetricSignpost(name: name, durationMs: ms, timestamp: ts, fields: fields))))
        case "metric.gauge":
            guard let name = d.name, let value = d.value else { return }
            append(.metric(.gauge(MetricGauge(name: name, value: value, timestamp: ts, fields: fields))))
        case "metric.counter":
            guard let name = d.name, let delta = d.delta, let total = d.total else { return }
            append(.metric(.counter(MetricCounter(name: name, delta: delta, total: total, timestamp: ts, fields: fields))))
        case "metric.hang":
            guard let ms = d.duration_ms else { return }
            append(.metric(.hang(MetricHang(durationMs: ms, timestamp: ts))))
        case "metric.launch":
            guard let ms = d.ms else { return }
            append(.metric(.launch(MetricLaunch(ms: ms, timestamp: ts))))
        default:
            ingestText(rawLine)
        }
    }

    private func ingestText(_ rawLine: String) {
        let mt = Self.parseMessageType(rawLine)
        append(.text(TextEntry(line: rawLine, messageType: mt, timestamp: Date())))
    }

    private func ingestAnalytics(_ rawLine: String) {
        guard let payload = Self.extractJson(rawLine),
              let data = payload.data(using: .utf8) else {
            ingestText(rawLine)
            return
        }
        struct Decoded: Decodable {
            let kind: String?
            let event: String?
            let screen: String?
            let params: [String: AnyCodable]?
            let t: Double?
        }
        guard let d = try? JSONDecoder().decode(Decoded.self, from: data) else {
            ingestText(rawLine)
            return
        }
        let ts = d.t.flatMap { Date(timeIntervalSince1970: $0) } ?? Date()
        let kind = d.kind ?? "analytics"
        if kind == "screen" {
            append(.analytics(AnalyticsEntry(
                kind: "screen",
                event: d.screen ?? "(screen)",
                params: d.params ?? [:],
                screen: d.screen,
                timestamp: ts
            )))
        } else if kind == "analytics" {
            append(.analytics(AnalyticsEntry(
                kind: "analytics",
                event: d.event ?? "(unnamed)",
                params: d.params ?? [:],
                screen: d.screen,
                timestamp: ts
            )))
        } else {
            ingestText(rawLine)
        }
    }

    private func ingestNetwork(_ rawLine: String) {
        guard let payload = Self.extractJson(rawLine),
              let data = payload.data(using: .utf8) else {
            ingestText(rawLine)
            return
        }
        struct Decoded: Decodable {
            let kind: String?
            let id: String?
            let t: Double?
            let method: String?
            let url: String?
            let headers: [String: String]?
            let body: String?
            let status: Int?
            let duration_ms: Int?
            let byte_size: Int?
            let error: String?
            let direction: String?
            let name: String?
            let value: String?
            let mocked: Bool?
        }
        guard let d = try? JSONDecoder().decode(Decoded.self, from: data),
              let id = d.id, let kind = d.kind else {
            ingestText(rawLine)
            return
        }
        switch kind {
        case "net.request":
            var entry = NetworkEntry(
                id: id,
                method: d.method ?? "?",
                url: d.url ?? "",
                requestHeaders: d.headers ?? [:],
                requestBody: d.body,
                status: nil,
                durationMs: nil,
                responseHeaders: [:],
                responseBody: nil,
                byteSize: nil,
                error: nil,
                createdAt: d.t.flatMap { Date(timeIntervalSince1970: $0) } ?? Date()
            )
            if d.mocked == true { entry.mocked = true }
            append(.network(entry))
            requestIndex[id] = entries.count - 1
        case "net.response":
            if let idx = requestIndex[id],
               case .network(var existing) = entries[idx] {
                existing.status = d.status
                existing.durationMs = d.duration_ms
                existing.byteSize = d.byte_size
                existing.responseHeaders = d.headers ?? [:]
                existing.responseBody = d.body
                if d.mocked == true { existing.mocked = true }
                entries[idx] = .network(existing)
                exportNetworkUpdate(existing)
            } else {
                // Response without matching request — synthesize a row anyway.
                var entry = NetworkEntry(
                    id: id, method: "?", url: "(unknown — response without request)",
                    requestHeaders: [:], requestBody: nil,
                    status: d.status, durationMs: d.duration_ms,
                    responseHeaders: d.headers ?? [:], responseBody: d.body,
                    byteSize: d.byte_size, error: nil,
                    createdAt: d.t.flatMap { Date(timeIntervalSince1970: $0) } ?? Date()
                )
                if d.mocked == true { entry.mocked = true }
                append(.network(entry))
            }
        case "net.error":
            if let idx = requestIndex[id],
               case .network(var existing) = entries[idx] {
                existing.error = d.error
                existing.durationMs = d.duration_ms
                entries[idx] = .network(existing)
                exportNetworkUpdate(existing)
            } else {
                ingestText(rawLine)
            }
        case "net.body":
            // Body arrives on its own log entry so the meta row above can't
            // be truncated by os_log's per-line limit. Pair by id + direction.
            if let idx = requestIndex[id],
               case .network(var existing) = entries[idx] {
                switch d.direction {
                case "request":  existing.requestBody = d.body
                case "response": existing.responseBody = d.body
                default: break
                }
                entries[idx] = .network(existing)
                exportNetworkUpdate(existing)
            }
        case "net.header":
            // One log entry per header — pair to existing row by id + direction.
            if let idx = requestIndex[id],
               case .network(var existing) = entries[idx],
               let name = d.name {
                let value = d.value ?? ""
                switch d.direction {
                case "request":  existing.requestHeaders[name] = value
                case "response": existing.responseHeaders[name] = value
                default: break
                }
                entries[idx] = .network(existing)
                exportNetworkUpdate(existing)
            }
        default:
            ingestText(rawLine)
        }
    }

    private func append(_ entry: TabEntry) {
        entries.append(entry)
        if entries.count > maxEntries {
            let drop = entries.count - maxEntries
            entries.removeFirst(drop)
            // Reindex network ids that survived eviction.
            requestIndex.removeAll()
            for (i, e) in entries.enumerated() {
                if case .network(let n) = e { requestIndex[n.id] = i }
            }
        }
        unread += 1
        exportEntry(entry)
    }

    private func exportEntry(_ entry: TabEntry) {
        guard let exporter else { return }
        exporter.write(serialize(entry))
    }

    /// Called after mutating a network row in-place so the exporter sees the
    /// new state. The exporter dedups by `id` on read.
    private func exportNetworkUpdate(_ entry: NetworkEntry) {
        guard let exporter else { return }
        exporter.write(serialize(.network(entry)))
    }

    private func serialize(_ entry: TabEntry) -> [String: Any] {
        switch entry {
        case .network(let n):
            var d: [String: Any] = [
                "kind": "network",
                "tab": spec.name,
                "ts": n.createdAt.timeIntervalSince1970,
                "id": n.id,
                "method": n.method,
                "url": n.url,
                "request_headers": n.requestHeaders,
                "response_headers": n.responseHeaders
            ]
            if let v = n.requestBody  { d["request_body"]  = v }
            if let v = n.responseBody { d["response_body"] = v }
            if let v = n.status       { d["status"]        = v }
            if let v = n.durationMs   { d["duration_ms"]   = v }
            if let v = n.byteSize     { d["byte_size"]     = v }
            if let v = n.error        { d["error"]         = v }
            return d
        case .analytics(let a):
            return [
                "kind": a.kind,             // "analytics" | "screen"
                "tab": spec.name,
                "ts": a.timestamp.timeIntervalSince1970,
                "event": a.event,
                "screen": a.screen as Any,
                "params": a.params.mapValues { $0.value }
            ]
        case .text(let t):
            // Try to extract a structured JSON payload from the compact log
            // line so SimConsole.log(...) calls in the Logs tab are queryable.
            var d: [String: Any] = [
                "kind": "text",
                "tab": spec.name,
                "ts": t.timestamp.timeIntervalSince1970,
                "line": t.line,
                "message_type": String(describing: t.messageType)
            ]
            if let payload = TabViewModel.extractJsonFromText(t.line) {
                d["payload"] = payload
            }
            return d
        case .metric(let m):
            var d: [String: Any] = [
                "tab": spec.name,
            ]
            switch m {
            case .sample(let s):
                d["kind"] = "metric.sample"
                d["ts"] = s.timestamp.timeIntervalSince1970
                d["name"] = s.name
                d["value"] = s.value
                d["fields"] = s.fields.mapValues { $0.value }
            case .milestone(let s):
                d["kind"] = "metric.milestone"
                d["ts"] = s.timestamp.timeIntervalSince1970
                d["name"] = s.name
                d["ms_since_launch"] = s.msSinceLaunch
                d["fields"] = s.fields.mapValues { $0.value }
            case .signpost(let s):
                d["kind"] = "metric.signpost"
                d["ts"] = s.timestamp.timeIntervalSince1970
                d["name"] = s.name
                d["duration_ms"] = s.durationMs
                d["fields"] = s.fields.mapValues { $0.value }
            case .gauge(let s):
                d["kind"] = "metric.gauge"
                d["ts"] = s.timestamp.timeIntervalSince1970
                d["name"] = s.name
                d["value"] = s.value
                d["fields"] = s.fields.mapValues { $0.value }
            case .counter(let s):
                d["kind"] = "metric.counter"
                d["ts"] = s.timestamp.timeIntervalSince1970
                d["name"] = s.name
                d["delta"] = s.delta
                d["total"] = s.total
                d["fields"] = s.fields.mapValues { $0.value }
            case .hang(let s):
                d["kind"] = "metric.hang"
                d["ts"] = s.timestamp.timeIntervalSince1970
                d["duration_ms"] = s.durationMs
            case .launch(let s):
                d["kind"] = "metric.launch"
                d["ts"] = s.timestamp.timeIntervalSince1970
                d["ms"] = s.ms
            }
            return d
        }
    }

    private static func extractJsonFromText(_ line: String) -> [String: Any]? {
        guard let r = line.range(of: "{") else { return nil }
        let tail = String(line[r.lowerBound...]).replacingOccurrences(of: "\\134", with: "\\")
        guard let data = tail.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data, options: []),
              let dict = obj as? [String: Any]
        else { return nil }
        return dict
    }

    // MARK: parsing helpers

    /// Extract the JSON object from a compact-style log line.
    /// Compact lines look like:
    ///   "2026-05-19 16:48:15.150 I  ExampleApp[64990:1ae2bef] [subsystem:category] {...}"
    /// We just locate the first `{` and return the substring from there.
    ///
    /// `log stream --style compact` octal-escapes literal backslashes as
    /// `\134`, which corrupts JSON-encoded body fields (`\"` in the original
    /// JSON becomes `\134"` in the log line). Undo that escape so JSONDecoder
    /// sees the original payload.
    private static func extractJson(_ line: String) -> String? {
        guard let r = line.range(of: "{") else { return nil }
        let tail = String(line[r.lowerBound...])
        return tail.replacingOccurrences(of: "\\134", with: "\\")
    }

    /// Resolve the log-level letter from either iOS `log stream --style compact`
    /// (3rd token) or Android `logcat -v threadtime` (5th token). The level is
    /// always the first standalone single-letter token after the timestamp prefix,
    /// so we just scan tokens until we find a recognized one.
    private static func parseMessageType(_ line: String) -> TextEntry.MessageType {
        let parts = line.split(separator: " ", maxSplits: 8, omittingEmptySubsequences: true)
        for p in parts {
            switch String(p) {
            case "E":  return .error
            case "F":  return .fault
            case "I":  return .info
            case "D", "Db": return .debug
            // "W" (Android warn) and "V" (verbose) fall through to default.
            default: continue
            }
        }
        return .default
    }

    // Setup banners emitted by each transport on startup.
    private static func isBoilerplate(_ line: String) -> Bool {
        // iOS `log stream --style compact`:
        if line.hasPrefix("getpwuid_r ") { return true }
        if line.hasPrefix("Filtering the log data using ") { return true }
        if line.hasPrefix("Timestamp ") { return true }
        if line.hasPrefix("Skipping info and debug messages") { return true }
        // Android `adb logcat`:
        if line.hasPrefix("--------- beginning of") { return true }
        return false
    }
}

// ---------------------------------------------------------------------------
// MARK: - SwiftUI

private enum Theme {
    static let bg = Color(red: 0.08, green: 0.08, blue: 0.08)
    static let rowBg = Color(red: 0.10, green: 0.10, blue: 0.10)
    static let rowAlt = Color(red: 0.12, green: 0.12, blue: 0.12)
    /// One step lighter than `bg` so the header reads as elevated chrome
    /// without dominating the view the way a bright accent band did.
    static let headerBg = Color(red: 0.13, green: 0.13, blue: 0.13)
    static let stroke = Color.white.opacity(0.06)
    static let textPrimary = Color.white.opacity(0.93)
    static let textSecondary = Color.white.opacity(0.62)
    static let textDim = Color.white.opacity(0.40)
    static let mono = Font.system(size: 11, weight: .regular, design: .monospaced)
    static let monoBold = Font.system(size: 11, weight: .semibold, design: .monospaced)
    static let body = Font.system(size: 12)
}

struct RootView: View {
    @ObservedObject var state: ConsoleState

    var body: some View {
        VStack(spacing: 0) {
            // No standalone header bar — the title bar already shows
            // "SimConsole — <subsystem>", so a second label below it was
            // pure redundancy with a loud accent band. The Attach/Detach
            // toggle moved into SegmentBar (right-aligned, separated from
            // the tabs).
            SegmentBar(state: state)
            SearchBar(state: state)
            Divider().background(Theme.stroke)
            tabContent
        }
        .background(Theme.bg)
        .preferredColorScheme(.dark)
    }

    @ViewBuilder
    private var tabContent: some View {
        if let active = state.activeTab {
            switch active.spec.kind {
            case .network:   NetworkList(model: active, mockStore: state.mockStore)
            case .analytics: AnalyticsList(model: active)
            case .text:      TextList(model: active)
            case .metric:    MetricsList(model: active)
            }
        } else {
            Text("No tabs configured")
                .foregroundColor(Theme.textSecondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

final class ConsoleState: ObservableObject {
    @Published var tabs: [TabViewModel]
    @Published var activeIndex: Int = 0
    /// When `true`, the panel snaps to and follows the sim/emulator window
    /// every tick. When `false`, the user can move and resize the window
    /// freely (and we persist its frame). Set false by the Controller for
    /// USB-device launches where there's no on-screen window to dock to.
    @Published var attached: Bool = true
    /// Disables the attach toggle UI when there's no sim/emulator window
    /// available (e.g., physical USB device, or platform doesn't support docking).
    @Published var attachAvailable: Bool = true
    let appLabel: String
    let accent: Color
    let mockStore: MockStore?

    init(tabs: [TabViewModel], appLabel: String, accent: Color, mockStore: MockStore?) {
        self.tabs = tabs
        self.appLabel = appLabel
        self.accent = accent
        self.mockStore = mockStore
    }

    var activeTab: TabViewModel? {
        guard activeIndex >= 0, activeIndex < tabs.count else { return nil }
        return tabs[activeIndex]
    }

    func select(_ index: Int) {
        guard index >= 0, index < tabs.count else { return }
        activeIndex = index
        tabs[index].clearUnread()
    }
}

struct HeaderBar: View {
    @ObservedObject var state: ConsoleState
    var body: some View {
        HStack(spacing: 8) {
            // Small accent pill on the left — keeps the user's --accent
            // color as visual identity without flooding the whole bar with
            // bright blue. The label text reads against the dark panel chrome
            // instead, which integrates with the rest of the UI.
            Circle()
                .fill(state.accent)
                .frame(width: 7, height: 7)
                .padding(.leading, 12)
            Text(state.appLabel)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(Theme.textSecondary)
            Spacer()
            AttachToggle(state: state)
                .padding(.trailing, 8)
        }
        .frame(maxWidth: .infinity, minHeight: 26, alignment: .leading)
        .background(Theme.headerBg)
        .overlay(
            // Hairline separator below the header — gives the bar a clean
            // edge against the tab strip without needing a heavier border.
            Rectangle()
                .fill(Color.white.opacity(0.06))
                .frame(height: 1),
            alignment: .bottom
        )
    }
}

/// One-button attach/detach toggle. Shows in the header bar.
/// - When `attachAvailable` is false (USB device, etc.), the button is hidden
///   since there's no sim/emulator window to dock to.
/// - When attached, label reads "Detach" — clicking it stops tracking and
///   lets the user move/resize freely.
/// - When detached, label reads "Attach" — clicking it re-docks to the sim.
struct AttachToggle: View {
    @ObservedObject var state: ConsoleState
    var body: some View {
        if state.attachAvailable {
            Button(action: {
                state.attached.toggle()
                diag("AttachToggle → \(state.attached ? "attached" : "detached")")
            }) {
                HStack(spacing: 5) {
                    Image(systemName: state.attached ? "pin.slash.fill" : "pin.fill")
                        .font(.system(size: 11, weight: .semibold))
                    Text(state.attached ? "Detach" : "Attach")
                        .font(.system(size: 12, weight: .semibold))
                }
                .foregroundColor(.black)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(Color.white)
                .cornerRadius(6)
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(Color.black.opacity(0.15), lineWidth: 1)
                )
            }
            .buttonStyle(.plain)
            .help(state.attached
                ? "Currently tracking the sim/emulator window. Click to free the panel."
                : "Currently freestanding. Click to snap back beside the sim/emulator window.")
        }
    }
}

struct SegmentBar: View {
    @ObservedObject var state: ConsoleState
    /// True when the tab strip needs more horizontal room than the
    /// container provides → render the prev/next arrows and clip the
    /// strip; programmatic scroll keeps the active tab in view.
    @State private var tabsOverflow = false

    var body: some View {
        HStack(spacing: 8) {
            // Tab strip: lives in its own clipped region with NO user
            // scroll gesture. When tabs overflow, the chevron buttons on
            // either side step the active selection through the list.
            // `scrollDisabled(true)` is iOS 16+ / macOS 13+ — kills the
            // trackpad swipe so the only way to move between tabs is the
            // tab chip itself or the arrows.
            ScrollViewReader { proxy in
                HStack(spacing: 4) {
                    if tabsOverflow {
                        ArrowButton(systemName: "chevron.left", enabled: state.activeIndex > 0) {
                            let next = max(0, state.activeIndex - 1)
                            state.select(next)
                            withAnimation(.easeOut(duration: 0.15)) {
                                proxy.scrollTo(state.tabs[next].id, anchor: .center)
                            }
                        }
                    }
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 4) {
                            ForEach(Array(state.tabs.enumerated()), id: \.element.id) { idx, tab in
                                SegmentChip(
                                    label: tab.spec.name,
                                    badge: tab === state.activeTab ? 0 : tab.unread,
                                    active: idx == state.activeIndex,
                                    // Metric tabs are *always* live recording from the
                                    // moment the panel attaches — surface that with a
                                    // pulsing red dot instead of an ever-growing event
                                    // counter the user can't act on.
                                    isLiveStream: tab.spec.kind == .metric
                                )
                                .id(tab.id)
                                .onTapGesture {
                                    state.select(idx)
                                    withAnimation(.easeOut(duration: 0.15)) {
                                        proxy.scrollTo(tab.id, anchor: .center)
                                    }
                                }
                            }
                        }
                        .padding(.trailing, 4)
                        .background(
                            // Measure the intrinsic tab-strip width and
                            // compare to the container so we know whether
                            // arrows are needed. PreferenceKey carries the
                            // measurement up to the outer GeometryReader.
                            GeometryReader { tabsGeo in
                                Color.clear.preference(
                                    key: TabsContentWidthKey.self,
                                    value: tabsGeo.size.width
                                )
                            }
                        )
                    }
                    .scrollDisabled(true)
                    if tabsOverflow {
                        ArrowButton(systemName: "chevron.right", enabled: state.activeIndex < state.tabs.count - 1) {
                            let next = min(state.tabs.count - 1, state.activeIndex + 1)
                            state.select(next)
                            withAnimation(.easeOut(duration: 0.15)) {
                                proxy.scrollTo(state.tabs[next].id, anchor: .center)
                            }
                        }
                    }
                }
            }
            // Attach/Detach toggle pinned on the right, OUTSIDE the tab
            // region's scrollview. `layoutPriority(1)` makes SwiftUI
            // reserve its intrinsic width first so it's always visible
            // regardless of how many tabs are showing. Hidden entirely on
            // platforms where there's no on-screen device window to dock
            // to (USB iPhone, Android, web — see AttachToggle's
            // `attachAvailable` guard).
            AttachToggle(state: state)
                .layoutPriority(1)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .background(
            // Outer GeometryReader catches the parent width so we can
            // compare against the tab-strip width preference.
            GeometryReader { outerGeo in
                Color.clear.preference(
                    key: SegmentBarWidthKey.self,
                    value: outerGeo.size.width
                )
            }
        )
        .onPreferenceChange(TabsContentWidthKey.self) { tabsW in
            tabsContentWidth = tabsW
            recomputeOverflow()
        }
        .onPreferenceChange(SegmentBarWidthKey.self) { barW in
            barWidth = barW
            recomputeOverflow()
        }
    }

    /// Latest measurements from the two preference keys. Kept as @State so
    /// updates flow through the normal SwiftUI publishing pipeline (no
    /// global / actor-isolated storage to chase).
    @State private var tabsContentWidth: CGFloat = 0
    @State private var barWidth: CGFloat = 0

    private func recomputeOverflow() {
        // 90pt is a generous estimate of the AttachToggle's width
        // (Attach / Detach labels both fit). Add 24pt of slack for the
        // HStack spacing + per-side padding so we don't toggle modes
        // when the strip is right at the edge.
        let toggleEstimate: CGFloat = 90
        let slack: CGFloat = 24
        guard barWidth > 0, tabsContentWidth > 0 else { return }
        tabsOverflow = tabsContentWidth + toggleEstimate + slack > barWidth
    }
}

/// Preference key carrying the tab strip's intrinsic content width up to
/// SegmentBar's overflow detector.
private struct TabsContentWidthKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

/// Preference key carrying SegmentBar's own outer width.
private struct SegmentBarWidthKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        let v = nextValue()
        if v > 0 { value = v }
    }
}

/// Small chevron button styled like AttachToggle (white background,
/// black icon, subtle border) so the bar reads as one coherent control
/// strip. Disabled when there's no tab to step to in that direction.
private struct ArrowButton: View {
    let systemName: String
    let enabled: Bool
    let action: () -> Void

    var body: some View {
        Button(action: enabled ? action : {}) {
            Image(systemName: systemName)
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(enabled ? .black : .gray)
                .frame(width: 24, height: 24)
                .background(Color.white)
                .cornerRadius(6)
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(Color.black.opacity(0.15), lineWidth: 1)
                )
                .opacity(enabled ? 1 : 0.5)
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
    }
}

struct SegmentChip: View {
    let label: String
    let badge: Int
    let active: Bool
    let isLiveStream: Bool
    @State private var pulsing: Bool = false

    var body: some View {
        HStack(spacing: 4) {
            Text(label)
                .font(.system(size: 13, weight: active ? .semibold : .regular))
                .foregroundColor(active ? Theme.textPrimary : Theme.textSecondary)
            if isLiveStream {
                // Always show the pulsing recording dot for live-stream tabs
                // (selected or not) — it's the "this is always recording"
                // signal, not an unread-count indicator.
                Circle()
                    .fill(Color(red: 1.0, green: 0.30, blue: 0.30))
                    .frame(width: 6, height: 6)
                    .opacity(pulsing ? 1.0 : 0.30)
                    .animation(
                        .easeInOut(duration: 0.9).repeatForever(autoreverses: true),
                        value: pulsing
                    )
                    .onAppear { pulsing = true }
                    .help("Live recording")
            } else if badge > 0 {
                Text(badge > 99 ? "99+" : String(badge))
                    .font(.system(size: 9, weight: .semibold))
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(Color.white.opacity(0.18))
                    .foregroundColor(Theme.textPrimary)
                    .clipShape(Capsule())
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(active ? Color.white.opacity(0.10) : Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: 4))
    }
}

struct SearchBar: View {
    @ObservedObject var state: ConsoleState
    var body: some View {
        let binding = Binding<String>(
            get: { state.activeTab?.filterQuery ?? "" },
            set: { state.activeTab?.filterQuery = $0 }
        )
        HStack {
            Image(systemName: "magnifyingglass")
                .foregroundColor(Theme.textDim)
                .font(.system(size: 11))
            TextField("Filter (substring, case-insensitive)", text: binding)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .foregroundColor(Theme.textPrimary)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(Theme.rowBg)
        .overlay(RoundedRectangle(cornerRadius: 4).stroke(Theme.stroke, lineWidth: 0.5))
        .padding(.horizontal, 6)
        .padding(.bottom, 4)
    }
}

// ---------------------------------------------------------------------------
// MARK: - Network list

struct NetworkList: View {
    @ObservedObject var model: TabViewModel
    var mockStore: MockStore?
    @State private var expanded: Set<String> = []

    var filtered: [NetworkEntry] {
        let q = model.filterQuery.trimmingCharacters(in: .whitespaces).lowercased()
        return model.entries.compactMap { entry -> NetworkEntry? in
            guard case .network(let e) = entry else { return nil }
            if q.isEmpty { return e }
            if e.url.lowercased().contains(q) { return e }
            if e.method.lowercased().contains(q) { return e }
            if let status = e.status, String(status).contains(q) { return e }
            if let body = e.responseBody?.lowercased(), body.contains(q) { return e }
            if let body = e.requestBody?.lowercased(), body.contains(q) { return e }
            return nil
        }
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 1) {
                    ForEach(filtered) { e in
                        NetworkRow(entry: e, expanded: expanded.contains(e.id), mockStore: mockStore)
                            .id(e.id)
                            .onTapGesture {
                                if expanded.contains(e.id) { expanded.remove(e.id) }
                                else { expanded.insert(e.id) }
                            }
                    }
                    Color.clear.frame(height: 1).id("BOTTOM")
                }
            }
            .onChange(of: filtered.count) { _ in
                withAnimation(.linear(duration: 0.05)) { proxy.scrollTo("BOTTOM", anchor: .bottom) }
            }
        }
    }
}

struct NetworkRow: View {
    let entry: NetworkEntry
    let expanded: Bool
    var mockStore: MockStore?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center, spacing: 8) {
                MethodPill(method: entry.method)
                Text(entry.hostAndPath)
                    .font(Theme.mono)
                    .foregroundColor(Theme.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 4)
                if entry.mocked {
                    MockedBadge()
                }
                StatusBadge(status: entry.status, error: entry.error)
                if let ms = entry.durationMs {
                    Text("\(ms)ms")
                        .font(Theme.mono)
                        .foregroundColor(Theme.textSecondary)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            if expanded {
                NetworkDetail(entry: entry, mockStore: mockStore)
                    .padding(.horizontal, 8)
                    .padding(.bottom, 8)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.rowBg)
        .contentShape(Rectangle())
    }
}

struct MethodPill: View {
    let method: String
    var color: Color {
        switch method.uppercased() {
        case "GET":    return Color(red: 0.30, green: 0.65, blue: 1.00)
        case "POST":   return Color(red: 0.35, green: 0.80, blue: 0.55)
        case "PUT":    return Color(red: 0.95, green: 0.70, blue: 0.30)
        case "PATCH":  return Color(red: 0.85, green: 0.60, blue: 0.30)
        case "DELETE": return Color(red: 0.95, green: 0.40, blue: 0.40)
        default:       return Color.gray
        }
    }
    var body: some View {
        Text(method.uppercased())
            .font(.system(size: 9, weight: .bold, design: .monospaced))
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(color.opacity(0.20))
            .foregroundColor(color)
            .clipShape(RoundedRectangle(cornerRadius: 3))
            .frame(minWidth: 44)
    }
}

/// Pill that marks a network row as "mocked" in the collapsed list view.
/// Single-letter "M" keeps the row tight — the full "MOCKED" label lives in
/// the expanded detail. Same warm accent in both places so they read as one
/// consistent visual language.
struct MockedBadge: View {
    var body: some View {
        Text("M")
            .font(.system(size: 9, weight: .bold, design: .monospaced))
            .padding(.horizontal, 5).padding(.vertical, 2)
            .background(Color(red: 0.95, green: 0.70, blue: 0.30).opacity(0.20))
            .foregroundColor(Color(red: 0.95, green: 0.70, blue: 0.30))
            .clipShape(RoundedRectangle(cornerRadius: 3))
            .help("Mocked response")
    }
}

struct StatusBadge: View {
    let status: Int?
    let error: String?
    var body: some View {
        if let err = error {
            Text("ERR")
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .padding(.horizontal, 5).padding(.vertical, 2)
                .background(Color(red: 0.95, green: 0.30, blue: 0.30).opacity(0.20))
                .foregroundColor(Color(red: 1.0, green: 0.45, blue: 0.45))
                .clipShape(RoundedRectangle(cornerRadius: 3))
                .help(err)
        } else if let s = status {
            Text(String(s))
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .padding(.horizontal, 5).padding(.vertical, 2)
                .background(statusColor(s).opacity(0.20))
                .foregroundColor(statusColor(s))
                .clipShape(RoundedRectangle(cornerRadius: 3))
        } else {
            Text("…")
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .padding(.horizontal, 5).padding(.vertical, 2)
                .background(Color.gray.opacity(0.20))
                .foregroundColor(Color.gray)
                .clipShape(RoundedRectangle(cornerRadius: 3))
        }
    }
    private func statusColor(_ s: Int) -> Color {
        switch s {
        case 200..<300: return Color(red: 0.40, green: 0.85, blue: 0.55)
        case 300..<400: return Color(red: 0.95, green: 0.80, blue: 0.40)
        case 400..<500: return Color(red: 0.95, green: 0.55, blue: 0.35)
        case 500..<600: return Color(red: 1.00, green: 0.40, blue: 0.40)
        default:        return Color.gray
        }
    }
}

struct NetworkDetail: View {
    let entry: NetworkEntry
    var mockStore: MockStore?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let store = mockStore {
                MockControlsView(entry: entry, store: store)
            }

            SectionLabel(text: "URL")
            Text(entry.url)
                .font(Theme.mono)
                .foregroundColor(Theme.textPrimary)
                .textSelection(.enabled)

            if !entry.requestHeaders.isEmpty {
                SectionLabel(text: "Request headers")
                HeaderGrid(headers: entry.requestHeaders)
            }
            if let body = entry.requestBody, !body.isEmpty {
                SectionLabel(text: "Request body")
                BodyBlock(text: body)
            }
            if !entry.responseHeaders.isEmpty {
                SectionLabel(text: "Response headers")
                HeaderGrid(headers: entry.responseHeaders)
            }
            if let body = entry.responseBody, !body.isEmpty {
                SectionLabel(text: "Response body")
                BodyBlock(text: body)
            }
            if let err = entry.error {
                SectionLabel(text: "Error")
                Text(err)
                    .font(Theme.mono)
                    .foregroundColor(Color(red: 1.0, green: 0.45, blue: 0.45))
                    .textSelection(.enabled)
            }
        }
        .padding(.top, 6)
    }
}

/// Mock controls — pulled out into its own view so the `@ObservedObject`
/// requirement on `store` doesn't force every NetworkDetail to be tied to
/// a MockStore (some sessions launch without `--bundle-id` and don't expose
/// mocking at all).
struct MockControlsView: View {
    let entry: NetworkEntry
    @ObservedObject var store: MockStore
    @State private var sheetPresented: Bool = false

    var existingMock: Mock? {
        store.mock(matchingMethod: entry.method, url: entry.url)
    }

    var body: some View {
        HStack(spacing: 6) {
            if let mock = existingMock {
                Text("MOCKED")
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .padding(.horizontal, 5).padding(.vertical, 2)
                    .background(Color(red: 0.95, green: 0.70, blue: 0.30).opacity(0.20))
                    .foregroundColor(Color(red: 0.95, green: 0.70, blue: 0.30))
                    .clipShape(RoundedRectangle(cornerRadius: 3))
                Button("Edit") { sheetPresented = true }
                    .font(.system(size: 11))
                Button("Remove") { store.remove(id: mock.id) }
                    .font(.system(size: 11))
                    .foregroundColor(Color(red: 1.0, green: 0.45, blue: 0.45))
            } else {
                Button("Mock") { sheetPresented = true }
                    .font(.system(size: 11))
            }
            Spacer()
        }
        .padding(.bottom, 4)
        .sheet(isPresented: $sheetPresented) {
            MockEditorView(
                store: store,
                presented: $sheetPresented,
                method: entry.method,
                url: entry.url,
                prefill: existingMock ?? Mock(
                    match: MockMatch(method: entry.method, url: entry.url),
                    response: MockResponse(
                        status: entry.status ?? 200,
                        headers: entry.responseHeaders.isEmpty
                            ? ["Content-Type": "application/json"]
                            : entry.responseHeaders,
                        body: entry.responseBody
                    )
                )
            )
        }
    }
}

struct SectionLabel: View {
    let text: String
    var body: some View {
        Text(text.uppercased())
            .font(.system(size: 9, weight: .semibold))
            .foregroundColor(Theme.textDim)
            .padding(.top, 2)
    }
}

struct HeaderGrid: View {
    let headers: [String: String]
    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            ForEach(headers.keys.sorted(), id: \.self) { k in
                HStack(alignment: .top, spacing: 6) {
                    Text(k)
                        .font(Theme.monoBold)
                        .foregroundColor(Theme.textSecondary)
                        .frame(minWidth: 110, alignment: .leading)
                    Text(headers[k] ?? "")
                        .font(Theme.mono)
                        .foregroundColor(Theme.textPrimary)
                        .textSelection(.enabled)
                }
            }
        }
    }
}

struct BodyBlock: View {
    let text: String
    var body: some View {
        Text(prettyPrint(text))
            .font(Theme.mono)
            .foregroundColor(Theme.textPrimary)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(6)
            .background(Theme.bg)
            .clipShape(RoundedRectangle(cornerRadius: 3))
    }
    private func prettyPrint(_ raw: String) -> String {
        guard let data = raw.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data, options: [.allowFragments]),
              JSONSerialization.isValidJSONObject(obj),
              let pretty = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys]),
              let s = String(data: pretty, encoding: .utf8)
        else { return raw }
        return s
    }
}

// ---------------------------------------------------------------------------
// MARK: - Analytics list

struct AnalyticsList: View {
    @ObservedObject var model: TabViewModel
    @State private var expanded: Set<String> = []

    var filtered: [AnalyticsEntry] {
        let q = model.filterQuery.trimmingCharacters(in: .whitespaces).lowercased()
        return model.entries.compactMap { entry -> AnalyticsEntry? in
            guard case .analytics(let e) = entry else { return nil }
            if q.isEmpty { return e }
            if e.event.lowercased().contains(q) { return e }
            for (k, v) in e.params {
                if k.lowercased().contains(q) || v.display.lowercased().contains(q) { return e }
            }
            return nil
        }
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 1) {
                    ForEach(filtered) { e in
                        AnalyticsRow(entry: e, expanded: expanded.contains(e.id.uuidString))
                            .id(e.id)
                            .onTapGesture {
                                let key = e.id.uuidString
                                if expanded.contains(key) { expanded.remove(key) }
                                else { expanded.insert(key) }
                            }
                    }
                    Color.clear.frame(height: 1).id("BOTTOM")
                }
            }
            .onChange(of: filtered.count) { _ in
                withAnimation(.linear(duration: 0.05)) { proxy.scrollTo("BOTTOM", anchor: .bottom) }
            }
        }
    }
}

struct AnalyticsRow: View {
    let entry: AnalyticsEntry
    let expanded: Bool

    var kindColor: Color {
        entry.kind == "screen"
            ? Color(red: 0.65, green: 0.50, blue: 1.0)
            : Color(red: 0.40, green: 0.85, blue: 0.55)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center, spacing: 8) {
                Text(entry.kind == "screen" ? "SCR" : "EVT")
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .padding(.horizontal, 5).padding(.vertical, 2)
                    .background(kindColor.opacity(0.20))
                    .foregroundColor(kindColor)
                    .clipShape(RoundedRectangle(cornerRadius: 3))
                Text(entry.event)
                    .font(Theme.monoBold)
                    .foregroundColor(Theme.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 4)
                if !entry.params.isEmpty {
                    Text("\(entry.params.count)")
                        .font(.system(size: 9, weight: .semibold, design: .monospaced))
                        .padding(.horizontal, 5).padding(.vertical, 2)
                        .background(Color.white.opacity(0.10))
                        .foregroundColor(Theme.textSecondary)
                        .clipShape(Capsule())
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            if expanded && !entry.params.isEmpty {
                VStack(alignment: .leading, spacing: 1) {
                    ForEach(entry.params.keys.sorted(), id: \.self) { k in
                        HStack(alignment: .top, spacing: 6) {
                            Text(k)
                                .font(Theme.monoBold)
                                .foregroundColor(Theme.textSecondary)
                                .frame(minWidth: 110, alignment: .leading)
                            Text(entry.params[k]?.display ?? "")
                                .font(Theme.mono)
                                .foregroundColor(Theme.textPrimary)
                                .textSelection(.enabled)
                        }
                    }
                }
                .padding(.horizontal, 8)
                .padding(.bottom, 8)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.rowBg)
        .contentShape(Rectangle())
    }
}

// ---------------------------------------------------------------------------
// MARK: - Text list (App / Errors / All)

struct TextList: View {
    @ObservedObject var model: TabViewModel

    var filtered: [TextEntry] {
        let q = model.filterQuery.trimmingCharacters(in: .whitespaces).lowercased()
        return model.entries.compactMap { entry -> TextEntry? in
            guard case .text(let e) = entry else { return nil }
            if q.isEmpty { return e }
            if e.line.lowercased().contains(q) { return e }
            return nil
        }
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(filtered) { e in
                        Text(e.line)
                            .font(Theme.mono)
                            .foregroundColor(colorFor(e.messageType))
                            .lineLimit(nil)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 1)
                            .textSelection(.enabled)
                            .id(e.id)
                    }
                    Color.clear.frame(height: 1).id("BOTTOM")
                }
            }
            .onChange(of: filtered.count) { _ in
                withAnimation(.linear(duration: 0.05)) { proxy.scrollTo("BOTTOM", anchor: .bottom) }
            }
        }
    }

    private func colorFor(_ mt: TextEntry.MessageType) -> Color {
        switch mt {
        case .error: return Color(red: 1.0, green: 0.45, blue: 0.45)
        case .fault: return Color(red: 1.0, green: 0.30, blue: 0.30)
        case .info: return Theme.textPrimary
        case .debug: return Theme.textDim
        case .default: return Theme.textPrimary
        }
    }
}

// ---------------------------------------------------------------------------
// MARK: - Perf tab (system samples + milestones + signposts + gauges)

/// Live performance dashboard. System samples drive sparklines + latest-value
/// rows; launch milestones render as a vertical timeline; signposts +
/// gauges + counters get tabular lists below.
struct MetricsList: View {
    @ObservedObject var model: TabViewModel

    private var systemSamples: [String: [MetricSample]] {
        var by: [String: [MetricSample]] = [:]
        for e in model.entries {
            if case .metric(.sample(let s)) = e {
                by[s.name, default: []].append(s)
            }
        }
        // Keep last 60 per series (1 Hz → 60s window).
        return by.mapValues { Array($0.suffix(60)) }
    }

    private var milestones: [MetricMilestone] {
        model.entries.compactMap {
            if case .metric(.milestone(let m)) = $0 { return m } else { return nil }
        }
    }

    /// First captured `metric.launch` event. The SDK guarantees exactly one
    /// per process; the panel only displays this one and never updates it,
    /// so revisiting a screen doesn't move the launch-time number.
    private var firstLaunch: MetricLaunch? {
        for e in model.entries {
            if case .metric(.launch(let l)) = e { return l }
        }
        return nil
    }

    private var signposts: [MetricSignpost] {
        model.entries.compactMap {
            if case .metric(.signpost(let s)) = $0 { return s } else { return nil }
        }
    }

    private var gauges: [String: MetricGauge] {
        var latest: [String: MetricGauge] = [:]
        for e in model.entries {
            if case .metric(.gauge(let g)) = e { latest[g.name] = g }
        }
        return latest
    }

    private var counters: [String: MetricCounter] {
        var latest: [String: MetricCounter] = [:]
        for e in model.entries {
            if case .metric(.counter(let c)) = e { latest[c.name] = c }
        }
        return latest
    }

    private var hangs: [MetricHang] {
        model.entries.compactMap {
            if case .metric(.hang(let h)) = $0 { return h } else { return nil }
        }
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 8) {
                LaunchSummaryView(launch: firstLaunch, milestoneCount: milestones.count)

                Divider().background(Theme.stroke).padding(.vertical, 4)
                SectionLabel(text: "System")
                ForEach(["memory.resident_mb", "memory.peak_mb",
                         "cpu.process_pct",
                         "fps.avg_1s", "fps.hitches_1s",
                         "thermal",
                         "battery.level", "battery.charging"], id: \.self) { name in
                    if let series = systemSamples[name] {
                        MetricSampleRow(name: name, series: series)
                    }
                }

                if !hangs.isEmpty {
                    Divider().background(Theme.stroke).padding(.vertical, 4)
                    SectionLabel(text: "Hangs (\(hangs.count))")
                    ForEach(hangs.suffix(10)) { h in
                        HangRow(hang: h)
                    }
                }

                if !milestones.isEmpty {
                    Divider().background(Theme.stroke).padding(.vertical, 4)
                    SectionLabel(text: "Launch timeline")
                    LaunchTimelineView(milestones: milestones)
                }

                if !signposts.isEmpty {
                    Divider().background(Theme.stroke).padding(.vertical, 4)
                    SectionLabel(text: "Signposts (\(signposts.count))")
                    ForEach(signposts.suffix(40)) { s in
                        SignpostRow(signpost: s)
                    }
                }

                if !gauges.isEmpty {
                    Divider().background(Theme.stroke).padding(.vertical, 4)
                    SectionLabel(text: "Gauges")
                    ForEach(gauges.keys.sorted(), id: \.self) { k in
                        if let g = gauges[k] { KVRow(key: g.name, value: formatGauge(g.value)) }
                    }
                }

                if !counters.isEmpty {
                    Divider().background(Theme.stroke).padding(.vertical, 4)
                    SectionLabel(text: "Counters")
                    ForEach(counters.keys.sorted(), id: \.self) { k in
                        if let c = counters[k] {
                            KVRow(key: c.name, value: formatGauge(c.total) + "  (Δ \(formatGauge(c.delta)))")
                        }
                    }
                }
                Color.clear.frame(height: 20)
            }
            .padding(.horizontal, 8).padding(.top, 6)
        }
    }

    private func formatGauge(_ v: Double) -> String {
        if abs(v - v.rounded()) < 0.001 { return String(Int(v.rounded())) }
        return String(format: "%.2f", v)
    }
}

struct MetricSampleRow: View {
    let name: String
    let series: [MetricSample]

    private var latest: Double { series.last?.value ?? 0 }
    private var peak: Double { series.map(\.value).max() ?? 0 }

    var body: some View {
        HStack(spacing: 8) {
            Text(displayName)
                .font(Theme.mono)
                .foregroundColor(Theme.textSecondary)
                .frame(width: 140, alignment: .leading)
            Sparkline(values: series.map(\.value))
                .stroke(Color(red: 0.49, green: 0.61, blue: 1.0), lineWidth: 1)
                .frame(height: 18)
                .background(Theme.bg)
            Text(formatLatest)
                .font(Theme.monoBold)
                .foregroundColor(Theme.textPrimary)
                .frame(width: 80, alignment: .trailing)
        }
        .padding(.vertical, 1)
    }

    /// Friendly labels that fit in the panel.
    private var displayName: String {
        switch name {
        case "memory.resident_mb": return "Memory (MB)"
        case "memory.peak_mb":     return "Peak (MB)"
        case "cpu.process_pct":    return "CPU (%)"
        case "fps.avg_1s":         return "FPS"
        case "fps.hitches_1s":     return "Hitches/s"
        case "thermal":            return "Thermal"
        case "battery.level":      return "Battery"
        case "battery.charging":   return "Charging"
        default:                   return name
        }
    }

    private var formatLatest: String {
        switch name {
        case "thermal":
            // Latest sample carries the state name in fields["state"].
            if let s = series.last,
               let state = s.fields["state"]?.value as? String { return state }
            return "?"
        case "battery.charging":
            return latest > 0.5 ? "yes" : "no"
        case "battery.level":
            return String(format: "%.0f%%", latest * 100)
        case "fps.avg_1s":
            return String(format: "%.0f", latest)
        case "fps.hitches_1s":
            return String(format: "%.0f", latest)
        case "cpu.process_pct":
            return String(format: "%.1f%%", latest)
        case "memory.resident_mb", "memory.peak_mb":
            return String(format: "%.0f", latest)
        default:
            return String(format: "%.2f", latest)
        }
    }
}

/// Quick-and-dirty Path-based sparkline. Renders the last N values
/// normalized to the row's height. Cheap; no animation.
struct Sparkline: Shape {
    let values: [Double]

    func path(in rect: CGRect) -> Path {
        guard values.count > 1 else { return Path() }
        let minV = values.min() ?? 0
        let maxV = values.max() ?? 1
        let range = max(maxV - minV, 0.001)
        var p = Path()
        let step = rect.width / CGFloat(values.count - 1)
        for (i, v) in values.enumerated() {
            let x = CGFloat(i) * step
            let norm = (v - minV) / range
            let y = rect.height - CGFloat(norm) * rect.height
            if i == 0 { p.move(to: CGPoint(x: x, y: y)) }
            else      { p.addLine(to: CGPoint(x: x, y: y)) }
        }
        return p
    }
}

/// Prominent "how long did the app take to launch?" header on the Metrics
/// tab. Reads the SDK's canonical `metric.launch` event, which fires exactly
/// once per process (`SimConsole.metric.appFinishLaunching()` is idempotent).
/// Once captured, the number never moves — revisiting a view doesn't update
/// it.
struct LaunchSummaryView: View {
    let launch: MetricLaunch?
    let milestoneCount: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("LAUNCH")
                .font(.system(size: 9, weight: .semibold))
                .foregroundColor(Theme.textDim)
            if let l = launch {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("\(l.ms)")
                        .font(.system(size: 28, weight: .bold, design: .monospaced))
                        .foregroundColor(launchColor(l.ms))
                    Text("ms")
                        .font(.system(size: 14, weight: .semibold, design: .monospaced))
                        .foregroundColor(Theme.textSecondary)
                    Spacer()
                    if milestoneCount > 0 {
                        Text("\(milestoneCount) milestone\(milestoneCount == 1 ? "" : "s")")
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundColor(Theme.textDim)
                    }
                }
            } else {
                Text("Waiting for launch event…")
                    .font(Theme.mono)
                    .foregroundColor(Theme.textSecondary)
                Text("Bracket your startup with SimConsole.metric.appStartLaunch() and .appFinishLaunching(). Make sure sim-console is running before the app launches.")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(Theme.textDim)
            }
        }
    }

    /// Apple's published target: <400ms post-main. Industry "good" is <2s.
    /// Color-coded so it's obvious at a glance whether you're in spec.
    private func launchColor(_ ms: Int) -> Color {
        switch ms {
        case 0..<400:   return Color(red: 0.40, green: 0.85, blue: 0.55)
        case 400..<2000: return Color(red: 0.95, green: 0.70, blue: 0.30)
        default:        return Color(red: 1.0, green: 0.45, blue: 0.45)
        }
    }
}

struct LaunchTimelineView: View {
    let milestones: [MetricMilestone]
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text("0ms").font(Theme.mono).foregroundColor(Theme.textDim).frame(width: 70, alignment: .leading)
                Text("process_start").font(Theme.mono).foregroundColor(Theme.textPrimary)
            }
            ForEach(milestones.sorted(by: { $0.msSinceLaunch < $1.msSinceLaunch })) { m in
                HStack {
                    Text("\(m.msSinceLaunch)ms")
                        .font(Theme.mono).foregroundColor(Theme.textDim)
                        .frame(width: 70, alignment: .leading)
                    Text(m.name).font(Theme.mono).foregroundColor(Theme.textPrimary)
                }
            }
        }
    }
}

struct SignpostRow: View {
    let signpost: MetricSignpost
    var body: some View {
        HStack(spacing: 8) {
            Text(signpost.name)
                .font(Theme.mono)
                .foregroundColor(Theme.textPrimary)
                .lineLimit(1)
            Spacer()
            Text("\(signpost.durationMs)ms")
                .font(Theme.monoBold)
                .foregroundColor(durationColor(signpost.durationMs))
        }
    }
    private func durationColor(_ ms: Int) -> Color {
        switch ms {
        case 0..<50:    return Color(red: 0.40, green: 0.85, blue: 0.55)
        case 50..<200:  return Theme.textPrimary
        case 200..<500: return Color(red: 0.95, green: 0.70, blue: 0.30)
        default:        return Color(red: 1.0, green: 0.45, blue: 0.45)
        }
    }
}

struct HangRow: View {
    let hang: MetricHang
    static let timeFmt: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "HH:mm:ss"; return f
    }()
    var body: some View {
        HStack {
            Text(Self.timeFmt.string(from: hang.timestamp))
                .font(Theme.mono).foregroundColor(Theme.textDim)
                .frame(width: 70, alignment: .leading)
            Text("hang")
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .padding(.horizontal, 5).padding(.vertical, 2)
                .background(Color(red: 1.0, green: 0.45, blue: 0.45).opacity(0.20))
                .foregroundColor(Color(red: 1.0, green: 0.45, blue: 0.45))
                .clipShape(RoundedRectangle(cornerRadius: 3))
            Spacer()
            Text("\(hang.durationMs)ms")
                .font(Theme.monoBold).foregroundColor(Color(red: 1.0, green: 0.45, blue: 0.45))
        }
    }
}

struct KVRow: View {
    let key: String
    let value: String
    var body: some View {
        HStack {
            Text(key).font(Theme.mono).foregroundColor(Theme.textSecondary)
            Spacer()
            Text(value).font(Theme.monoBold).foregroundColor(Theme.textPrimary)
        }
    }
}

// ---------------------------------------------------------------------------
// MARK: - Mocks (model + store + editor sheet + templates)

/// Mirrors the schema written by/read by the iOS-side SimConsole SDK at
/// `~/.sim-console/mocks-<bundle-id>.json`. Three writers — this macOS app,
/// the Python MCP server, and manual file edits — converge on this file.
/// The iOS app stat-polls it (no watcher) and reloads on mtime change.
struct Mock: Codable, Identifiable, Equatable {
    var id: String
    var match: MockMatch
    var response: MockResponse
    var delayMs: Int
    var enabled: Bool
    var createdAt: String

    enum CodingKeys: String, CodingKey {
        case id, match, response, enabled
        case delayMs = "delay_ms"
        case createdAt = "created_at"
    }

    init(
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

struct MockMatch: Codable, Equatable {
    var method: String
    var url: String
    var bodyContains: String?

    enum CodingKeys: String, CodingKey {
        case method, url
        case bodyContains = "body_contains"
    }
}

struct MockResponse: Codable, Equatable {
    var status: Int
    var headers: [String: String]
    var body: String?
}

struct MockFile: Codable {
    var version: Int
    var mocks: [Mock]
}

/// Pushes the panel-managed mock file from `~/.sim-console/mocks-<pkg>.json`
/// to the Android device/emulator's `/data/local/tmp/sim-console-mocks-<pkg>.json`
/// every time the panel re-writes it. The SDK's `MockStore` watches the
/// destination via `mtime` polling and reloads.
///
/// We chose `/data/local/tmp` because (a) `adb push` can write there without
/// root, (b) it's world-readable so the app sandbox can `File.readText()` it,
/// and (c) it survives across debug reinstalls (unlike `app.cacheDir`).
final class MockSync {
    private let adbPath: String
    private let serial: String
    private let bundleId: String
    private let localPath: String
    private let queue = DispatchQueue(label: "sim-console.mock-sync", qos: .utility)
    private var cancellable: Any?  // AnyCancellable; storing as Any avoids the import dance

    init(store: MockStore, adbPath: String, serial: String) {
        self.adbPath = adbPath
        self.serial = serial
        self.bundleId = store.bundleId
        self.localPath = store.path

        // Push once on startup so the device picks up whatever the panel
        // already had on disk before we attached.
        pushNow()

        // Subscribe to mock-set changes. Debounce-ish: we only schedule one
        // push per change tick — duplicate fast edits collapse.
        self.cancellable = store.$mocks
            .receive(on: queue)
            .sink { [weak self] _ in self?.pushNow() }
    }

    private var devicePath: String { "/data/local/tmp/sim-console-mocks-\(bundleId).json" }

    private func pushNow() {
        guard FileManager.default.fileExists(atPath: localPath) else { return }
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: adbPath.hasPrefix("/") ? adbPath : "/usr/bin/env")
        var argv: [String] = []
        if !adbPath.hasPrefix("/") { argv.append(adbPath) }
        if !serial.isEmpty { argv.append(contentsOf: ["-s", serial]) }
        argv.append(contentsOf: ["push", localPath, devicePath])
        proc.arguments = argv
        // Discard adb's "<N> KB/s (X bytes in Ys)" output — we only care about
        // success/failure. Errors land in our diag log.
        let nullPipe = Pipe()
        proc.standardOutput = nullPipe
        proc.standardError = nullPipe
        do {
            try proc.run()
            proc.waitUntilExit()
            if proc.terminationStatus != 0 {
                diag("MockSync: adb push failed (exit \(proc.terminationStatus)) for \(devicePath)")
            }
        } catch {
            diag("MockSync: adb push spawn failed: \(error)")
        }
    }
}

/// iOS counterpart of [MockSync] — pushes the panel-managed mock file into a
/// USB-connected iPhone's app sandbox via
/// `xcrun devicectl device copy to --domain-type appDataContainer`. The
/// destination lands at `Documents/sim-console/mocks.json` inside the app,
/// which the iOS SDK's [MockStore] reads via stat-poll.
///
/// On a simulator the panel doesn't need this — the simulator can read the
/// host file directly through `SIMULATOR_HOST_HOME`.
final class IOSMockSync {
    private let bundleId: String
    private let udid: String
    private let localPath: String
    private let queue = DispatchQueue(label: "sim-console.ios-mock-sync", qos: .utility)
    private var cancellable: Any?

    init(store: MockStore, udid: String) {
        self.bundleId = store.bundleId
        self.udid = udid
        self.localPath = store.path

        // Initial push so the device picks up whatever's already on disk.
        pushNow()

        // Subscribe to mock changes. `devicectl copy` is heavier than `adb
        // push` (the Core Device tunnel adds 200-500ms) so we explicitly use
        // a background queue and serialize updates.
        self.cancellable = store.$mocks
            .receive(on: queue)
            .sink { [weak self] _ in self?.pushNow() }
    }

    private func pushNow() {
        guard FileManager.default.fileExists(atPath: localPath) else { return }
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        var argv: [String] = [
            "devicectl", "device", "copy", "to",
            "--domain-type", "appDataContainer",
            "--domain-identifier", bundleId,
            "--source", localPath,
            "--destination", "Documents/sim-console/mocks.json",
        ]
        if !udid.isEmpty { argv.append(contentsOf: ["--device", udid]) }
        proc.arguments = argv
        proc.standardOutput = Pipe()
        proc.standardError = Pipe()
        do {
            try proc.run()
            proc.waitUntilExit()
            if proc.terminationStatus != 0 {
                diag("IOSMockSync: devicectl copy failed (exit \(proc.terminationStatus)) for \(bundleId)")
            }
        } catch {
            diag("IOSMockSync: devicectl spawn failed: \(error)")
        }
    }
}

final class MockStore: ObservableObject {
    @Published private(set) var mocks: [Mock] = []
    let bundleId: String
    let path: String

    init(bundleId: String) {
        self.bundleId = bundleId
        let dir = (NSHomeDirectory() as NSString).appendingPathComponent(".sim-console")
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        self.path = (dir as NSString).appendingPathComponent("mocks-\(bundleId).json")
        reload()
    }

    func reload() {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let file = try? JSONDecoder().decode(MockFile.self, from: data)
        else {
            self.mocks = []
            return
        }
        self.mocks = file.mocks
    }

    func mock(forId id: String) -> Mock? { mocks.first { $0.id == id } }

    func mock(matchingMethod method: String, url: String) -> Mock? {
        mocks.first { $0.match.method.uppercased() == method.uppercased() && $0.match.url == url }
    }

    func upsert(_ mock: Mock) {
        var current = mocks
        if let idx = current.firstIndex(where: { $0.id == mock.id }) {
            current[idx] = mock
        } else {
            current.append(mock)
        }
        write(current)
    }

    func remove(id: String) {
        write(mocks.filter { $0.id != id })
    }

    private func write(_ newMocks: [Mock]) {
        let file = MockFile(version: 1, mocks: newMocks)
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        guard let data = try? enc.encode(file) else { return }
        // Atomic write: temp file + replace, so the iOS reader never sees half a file.
        let tmp = path + ".tmp"
        do {
            try data.write(to: URL(fileURLWithPath: tmp), options: [.atomic])
            try? FileManager.default.removeItem(atPath: path)
            try FileManager.default.moveItem(atPath: tmp, toPath: path)
            DispatchQueue.main.async { self.mocks = newMocks }
        } catch {
            diag("mock write failed: \(error)")
        }
    }
}

/// Suggested response bodies for common status codes — pre-fills the
/// editor when the user picks a template. Inspired by Proxyman.
enum MockTemplates {
    static let codes: [(Int, String, String)] = [
        (200, "OK",                  "{}"),
        (201, "Created",             "{\"id\":\"new-id\",\"created\":true}"),
        (204, "No Content",          ""),
        (400, "Bad Request",         "{\"error\":\"bad_request\",\"code\":400,\"message\":\"Invalid request\"}"),
        (401, "Unauthorized",        "{\"error\":\"unauthorized\",\"code\":401,\"message\":\"Authentication required\"}"),
        (403, "Forbidden",           "{\"error\":\"forbidden\",\"code\":403,\"message\":\"Access denied\"}"),
        (404, "Not Found",           "{\"error\":\"not_found\",\"code\":404,\"message\":\"Resource not found\"}"),
        (409, "Conflict",            "{\"error\":\"conflict\",\"code\":409,\"message\":\"Resource conflict\"}"),
        (422, "Unprocessable",       "{\"error\":\"validation_failed\",\"errors\":[{\"field\":\"name\",\"message\":\"is required\"}]}"),
        (500, "Internal Server Err.","{\"error\":\"internal_server_error\",\"code\":500,\"message\":\"An unexpected error occurred\"}"),
        (502, "Bad Gateway",         "{\"error\":\"bad_gateway\",\"code\":502}"),
        (503, "Service Unavailable", "{\"error\":\"service_unavailable\",\"code\":503,\"message\":\"Try again later\"}"),
        (504, "Gateway Timeout",     "{\"error\":\"gateway_timeout\",\"code\":504}"),
    ]
}

/// Modal sheet for creating / editing one Mock. Pre-fills from the captured
/// request + response when the user mocks an existing row; can also be opened
/// blank from "+" (future).
struct MockEditorView: View {
    @ObservedObject var store: MockStore
    @Binding var presented: Bool

    let method: String
    let url: String
    let existingMockId: String?

    @State private var status: String
    @State private var headersText: String
    @State private var bodyText: String
    @State private var delayMs: String
    @State private var enabled: Bool
    @State private var validationWarning: String?

    init(
        store: MockStore,
        presented: Binding<Bool>,
        method: String,
        url: String,
        prefill: Mock?
    ) {
        self.store = store
        self._presented = presented
        self.method = method
        self.url = url
        self.existingMockId = prefill?.id

        let r = prefill?.response
        _status = State(initialValue: r.map { String($0.status) } ?? "200")
        let hdrs = r?.headers ?? ["Content-Type": "application/json"]
        let headersJson = (try? JSONSerialization.data(
            withJSONObject: hdrs, options: [.prettyPrinted, .sortedKeys]
        )).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        _headersText = State(initialValue: headersJson)
        _bodyText = State(initialValue: r?.body ?? "{}")
        _delayMs = State(initialValue: String(prefill?.delayMs ?? 0))
        _enabled = State(initialValue: prefill?.enabled ?? true)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                MethodPill(method: method)
                Text(url)
                    .font(Theme.mono)
                    .foregroundColor(Theme.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
            }

            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    SectionLabel(text: "Status")
                    TextField("200", text: $status)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 70)
                }
                VStack(alignment: .leading, spacing: 2) {
                    SectionLabel(text: "Suggest template")
                    Menu {
                        ForEach(MockTemplates.codes, id: \.0) { item in
                            Button("\(item.0) — \(item.1)") {
                                status = String(item.0)
                                bodyText = item.2
                            }
                        }
                    } label: {
                        Text("Pick a template…")
                            .font(.system(size: 11))
                            .frame(maxWidth: 160, alignment: .leading)
                    }
                    .menuStyle(.borderlessButton)
                }
                Spacer()
                VStack(alignment: .leading, spacing: 2) {
                    SectionLabel(text: "Delay (ms)")
                    TextField("0", text: $delayMs)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 70)
                }
                Toggle("Enabled", isOn: $enabled)
                    .toggleStyle(.checkbox)
            }

            SectionLabel(text: "Headers (JSON object)")
            TextEditor(text: $headersText)
                .font(Theme.mono)
                .frame(minHeight: 70, maxHeight: 110)
                .border(Theme.stroke)

            HStack {
                SectionLabel(text: "Body")
                Spacer()
                Button("Pretty-print JSON") {
                    bodyText = prettyPrint(bodyText)
                }
                .font(.system(size: 10))
            }
            TextEditor(text: $bodyText)
                .font(Theme.mono)
                .frame(minHeight: 140)
                .border(Theme.stroke)

            if let warn = validationWarning {
                Text(warn)
                    .font(.system(size: 11))
                    .foregroundColor(Color(red: 0.95, green: 0.70, blue: 0.30))
            }

            HStack {
                if existingMockId != nil {
                    Button("Remove mock") {
                        if let id = existingMockId { store.remove(id: id) }
                        presented = false
                    }
                    .foregroundColor(Color(red: 1.0, green: 0.45, blue: 0.45))
                }
                Spacer()
                Button("Cancel") { presented = false }
                Button("Save") { save() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .frame(width: 520, height: 540)
        .background(Theme.bg)
    }

    private func save() {
        guard let s = Int(status), (100...599).contains(s) else {
            validationWarning = "Status must be a number between 100 and 599."
            return
        }
        guard let headersData = headersText.data(using: .utf8),
              let headers = (try? JSONSerialization.jsonObject(with: headersData)) as? [String: String]
        else {
            validationWarning = "Headers must be a JSON object of string values."
            return
        }
        // Body must parse as JSON when Content-Type indicates JSON. Blocks
        // save on failure so we never persist a malformed mock that would
        // later confuse the consuming app. To mock a non-JSON body (HTML,
        // plain text), set a non-JSON Content-Type header.
        let contentType = (headers.first { $0.key.lowercased() == "content-type" }?.value ?? "").lowercased()
        if contentType.contains("json") && !bodyText.isEmpty {
            guard let data = bodyText.data(using: .utf8),
                  (try? JSONSerialization.jsonObject(with: data, options: [.allowFragments])) != nil
            else {
                validationWarning = "Body is not valid JSON. Fix it (or change Content-Type) to save."
                return
            }
        }
        validationWarning = nil
        let delay = Int(delayMs) ?? 0
        let mock = Mock(
            id: existingMockId ?? UUID().uuidString,
            match: MockMatch(method: method, url: url, bodyContains: nil),
            response: MockResponse(status: s, headers: headers, body: bodyText.isEmpty ? nil : bodyText),
            delayMs: delay,
            enabled: enabled
        )
        store.upsert(mock)
        presented = false
    }

    private func prettyPrint(_ raw: String) -> String {
        guard let data = raw.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data, options: [.allowFragments]),
              JSONSerialization.isValidJSONObject(obj),
              let pretty = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys]),
              let s = String(data: pretty, encoding: .utf8)
        else { return raw }
        return s
    }
}

// ---------------------------------------------------------------------------
// MARK: - Keyable panel

/// The panel uses [.titled, .closable, .miniaturizable, .resizable] now that
/// SimConsole ships as a real `.app` bundle. We still let it become key so
/// the search field can accept focus, and become main so it shows up in
/// `Cmd+Tab` / Dock context menu like a normal app window.
final class KeyablePanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

// ---------------------------------------------------------------------------
// MARK: - Controller

final class Controller {
    let panel: KeyablePanel
    let state: ConsoleState
    let args: Args
    let exporter: Exporter?
    var lastFrame: NSRect = .zero
    var refreshTimer: Timer?
    var mockSync: MockSync?
    var iosMockSync: IOSMockSync?
    let frameStore: PanelFrameStore?
    private var frameObserver: NSObjectProtocol?
    private var attachSubscription: Any?

    init(args: Args) {
        self.args = args
        self.exporter = Exporter(path: args.exportTo)
        let tabs = args.tabs.map { TabViewModel(spec: $0) }
        for t in tabs { t.exporter = self.exporter }
        let appLabel = args.appLabel.isEmpty ? "sim-console" : args.appLabel
        let mockStore: MockStore? = args.bundleId.isEmpty ? nil : MockStore(bundleId: args.bundleId)
        let state = ConsoleState(tabs: tabs, appLabel: appLabel, accent: args.accent, mockStore: mockStore)
        self.state = state

        // Cross-process mock sync: panel writes ~/.sim-console/mocks-<pkg>.json
        // on the host; we `adb push` to /data/local/tmp/ where the SDK reads it.
        // iOS doesn't need this — the simulator can read the host file directly
        // via SIMULATOR_HOST_HOME.
        if args.platform == .android, let store = mockStore {
            self.mockSync = MockSync(store: store, adbPath: args.adbPath, serial: args.device)
        }
        // USB-iPhone path: push via `xcrun devicectl device copy to`. Simulator
        // builds skip this — they read the host file directly via SIMULATOR_HOST_HOME.
        if args.platform == .ios, args.detached, let store = mockStore {
            self.iosMockSync = IOSMockSync(store: store, udid: args.device)
        }

        // Frame store is detached-only — docked mode computes its rect from the
        // sim/emulator's window every tick and ignores saved frames.
        self.frameStore = args.detached && !args.bundleId.isEmpty
            ? PanelFrameStore(bundleId: args.bundleId)
            : nil

        // Now that SimConsole is a real .app bundle, the panel is a normal
        // titled / resizable / closable window. Attach/Detach state controls
        // *whether* it tracks the sim/emulator window (set on .level + the
        // re-dock logic in tick()), not the window chrome.
        //
        // Default behavior: panel launches *detached* (user can drag) but
        // positioned next to the sim/emulator on first paint so the user
        // doesn't have to. Clicking "Attach" later makes it follow the sim's
        // window as it moves.
        let snapFrame: NSRect? = args.detached ? nil : Controller.snapBesideDevice(args: args)
        let savedFrame = frameStore?.load()
        let initialFrame = snapFrame
            ?? savedFrame
            ?? NSRect(x: 100, y: 100, width: args.width, height: 700)

        let panel = KeyablePanel(
            contentRect: initialFrame,
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        // Surface "which app is this panel attached to?" in the title bar
        // so we can drop the secondary header label entirely. Precedence:
        //   1. --app-label if the caller passed one
        //   2. --bundle-id (the subsystem) — what most users actually care about
        //   3. plain "SimConsole" fallback
        let titleSuffix = args.appLabel.isEmpty
            ? (args.bundleId.isEmpty ? "" : args.bundleId)
            : args.appLabel
        panel.title = titleSuffix.isEmpty ? "SimConsole" : "SimConsole — \(titleSuffix)"
        panel.isOpaque = true
        panel.backgroundColor = NSColor(calibratedWhite: 0.08, alpha: 1.0)
        panel.hasShadow = true
        // Panel behaviors that keep it visible across app activations.
        // Without these, clicking on the Simulator window deactivates our app
        // and NSPanel hides itself; the next tick then re-shows it, producing
        // a flash. Setting hidesOnDeactivate = false + isFloatingPanel = true
        // keeps it on screen at .floating level even when we're not the active app.
        panel.hidesOnDeactivate = false
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.minSize = NSSize(width: 360, height: 320)
        panel.isReleasedWhenClosed = false
        // Hide the green zoom button. Without this, double-clicking the title
        // bar or clicking the green button puts the window in `isZoomed` state,
        // and AppKit re-applies that target size after every setFrame — which
        // fights our 200ms re-snap in attached mode and produces a fullscreen
        // ↔ snapped oscillation. We don't need zoom on either path: attached
        // mode wants the panel anchored to the device window; detached mode
        // lets the user drag and resize manually.
        panel.standardWindowButton(.zoomButton)?.isHidden = true
        // Always launch detached so the user can immediately reposition.
        // attachAvailable depends on whether a device window exists to dock
        // against — USB-device launches hide the toggle entirely. Android is
        // also hidden: qemu emits multiple separate windows (device screen +
        // sidebar + transient popups) and our union-bounds heuristic can't
        // reliably produce a stable docking edge across emulator skins, so
        // the panel runs as a freely-movable window beside the emulator on
        // Android instead.
        state.attached = false
        state.attachAvailable = !args.detached && args.platform != .android
        panel.level = .floating
        panel.isMovable = true
        panel.isMovableByWindowBackground = true

        let hosting = NSHostingView(rootView: RootView(state: state))
        hosting.frame = NSRect(origin: .zero, size: panel.frame.size)
        hosting.autoresizingMask = [.width, .height]
        panel.contentView = hosting

        self.panel = panel

        // When the user closes the window, treat it as quitting the app —
        // there's no other window to keep us alive.
        NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: panel,
            queue: .main,
        ) { _ in
            NSApp.terminate(nil)
        }

        // Persist the panel position whenever the user drags it. We only react
        // when state.attached is false — attached mode rewrites the frame
        // every tick, so didMove notifications are us, not the user.
        frameObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didMoveNotification,
            object: panel,
            queue: .main,
        ) { [weak self] _ in
            guard let self else { return }
            if !self.state.attached, let store = self.frameStore {
                store.save(panel.frame)
            }
        }

        // React immediately when the user toggles Attach/Detach. Waiting for
        // the next 200ms tick is technically fine but feels laggy, and we
        // also need to flip `isMovable` exactly when the state changes so
        // the user can drag in detached mode and can't fight the docking
        // logic in attached mode.
        attachSubscription = state.$attached.dropFirst().sink { [weak self] attached in
            DispatchQueue.main.async {
                self?.applyAttachChange(attached: attached)
            }
        }
    }

    /// Apply side-effects of an attach/detach transition. Called from the
    /// state.$attached subscription so the UI feels instant.
    private func applyAttachChange(attached: Bool) {
        diag("attach change → \(attached ? "attached" : "detached")")
        panel.isMovable = !attached
        panel.isMovableByWindowBackground = !attached
        if attached {
            // Snap to the sim/emulator right now rather than waiting for the
            // next tick. tick() reads state.attached and will re-dock.
            tick()
        } else {
            // Detached: leave the panel where it is. The didMove observer
            // will start persisting any subsequent drags to PanelFrameStore.
            if let store = frameStore { store.save(panel.frame) }
        }
    }

    func start() {
        for tab in state.tabs { tab.start(args: args) }
        let timer = Timer(timeInterval: 0.2, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(timer, forMode: .common)
        self.refreshTimer = timer
        tick()
    }

    private func tick() {
        // USB-device targets (Android USB or iOS USB) have no on-screen
        // device window. attachAvailable was already set false at startup;
        // we just need the device-lifecycle probe.
        if args.detached {
            tickDetached(); return
        }

        let hostRunning: Bool
        let axRect: CGRect?
        switch args.platform {
        case .ios:
            hostRunning = simulatorAppRunning()
            if hostRunning,
               let window = findSimulatorWindow(matching: args.tag, fallback: args.altTag) {
                axRect = windowFrame(window)
            } else {
                axRect = nil
            }
        case .android:
            hostRunning = emulatorAppRunning()
            axRect = hostRunning ? findEmulatorWindowFrame(matching: args.tag) : nil
        case .web:
            // Web is always detached (set in parseArgs), so this branch of
            // tick() is unreachable. Defensive defaults keep the compiler
            // happy without forcing a `fatalError` we'd hate to hit.
            hostRunning = true
            axRect = nil
        }
        if !hostRunning {
            diag("host (\(args.platform.rawValue)) no longer running; exiting")
            for tab in state.tabs { tab.stop() }
            exit(0)
        }

        // Toggle the attach-button visibility based on whether we can locate
        // a window to dock to right now (sim may have moved off-screen, etc.).
        let canAttach = axRect != nil
        if state.attachAvailable != canAttach {
            state.attachAvailable = canAttach
        }

        // Detached *via the UI toggle*: leave the user's frame alone. Window
        // stays visible — we just don't re-dock. Level stays .floating so the
        // window doesn't vanish behind Simulator when the user clicks the device.
        if !state.attached {
            if !panel.isVisible { panel.orderFrontRegardless() }
            return
        }

        // Attached: snap beside the sim/emulator window. If we can't locate
        // the device window this tick (e.g., the sim was momentarily hidden
        // or focus shifted), DON'T hide the panel — that was the
        // overlay-era behavior and produces a flash whenever the user clicks
        // Simulator.app. Just leave the last frame in place until the next tick.
        if panel.level != .floating { panel.level = .floating }
        guard let axRect else {
            if !panel.isVisible { panel.orderFrontRegardless() }
            return
        }
        let cocoaRect = axToCocoa(axRect)

        let overlayRect: NSRect
        if args.side == "left" {
            overlayRect = NSRect(
                x: cocoaRect.minX - args.width - args.gap,
                y: cocoaRect.minY,
                width: args.width,
                height: cocoaRect.height
            )
        } else {
            overlayRect = NSRect(
                x: cocoaRect.maxX + args.gap,
                y: cocoaRect.minY,
                width: args.width,
                height: cocoaRect.height
            )
        }

        // Compare against the panel's *actual* frame, not a cached value, so
        // re-attach after the user dragged the panel in detached mode also
        // snaps it back. If AppKit somehow ended up zoomed (despite the hidden
        // zoom button — e.g. menu-bar Window > Zoom), un-zoom first so the
        // next setFrame sticks instead of triggering a re-zoom on the next pass.
        if overlayRect != panel.frame {
            if panel.isZoomed { panel.zoom(nil) }
            diag(String(format:
                "frame: device(cg)=%d,%d %dx%d → device(cocoa)=%d,%d %dx%d → panel=%d,%d %dx%d (was %d,%d %dx%d)",
                Int(axRect.minX), Int(axRect.minY), Int(axRect.width), Int(axRect.height),
                Int(cocoaRect.minX), Int(cocoaRect.minY), Int(cocoaRect.width), Int(cocoaRect.height),
                Int(overlayRect.minX), Int(overlayRect.minY), Int(overlayRect.width), Int(overlayRect.height),
                Int(panel.frame.minX), Int(panel.frame.minY), Int(panel.frame.width), Int(panel.frame.height)
            ))
            panel.setFrame(overlayRect, display: true)
            lastFrame = overlayRect
        }
        if !panel.isVisible {
            panel.orderFrontRegardless()
        }
    }

    /// Detached-mode tick: don't recompute the panel frame (the user controls
    /// it), and use the platform's "is the target still attached?" probe
    /// instead of looking for a sim/emulator window.
    private func tickDetached() {
        let attached: Bool
        switch args.platform {
        case .ios:
            attached = iosDeviceAttached(udid: args.device)
        case .android:
            attached = androidDeviceAttached(serial: args.device, adbPath: args.adbPath)
        case .web:
            // Web is bridge-driven — there's nothing physical to detach.
            // The panel stays up until the user closes it, or the user
            // shuts down the bridge process (in which case the tail
            // subprocess will just wait quietly for the file to come back).
            attached = true
        }
        if !attached {
            diag("detached target (\(args.platform.rawValue) \(args.device)) disconnected; exiting")
            for tab in state.tabs { tab.stop() }
            exit(0)
        }
        if !panel.isVisible {
            panel.orderFrontRegardless()
        }
    }

    /// Compute the one-shot "open beside the sim/emulator" frame used at
    /// startup so the panel lands next to the device window before the user
    /// ever sees it. Returns nil for USB-device launches or when the device
    /// window can't be located (in which case the caller falls back to
    /// `PanelFrameStore` or a default rect).
    static func snapBesideDevice(args: Args) -> NSRect? {
        let axRect: CGRect?
        switch args.platform {
        case .ios:
            guard simulatorAppRunning(),
                  let window = findSimulatorWindow(matching: args.tag, fallback: args.altTag)
            else { return nil }
            axRect = windowFrame(window)
        case .android:
            guard emulatorAppRunning() else { return nil }
            axRect = findEmulatorWindowFrame(matching: args.tag)
        case .web:
            // No on-screen device window for web; caller falls back to the
            // saved frame / default rect.
            return nil
        }
        guard let axRect else { return nil }
        let cocoaRect = axToCocoa(axRect)
        if args.side == "left" {
            return NSRect(
                x: cocoaRect.minX - args.width - args.gap,
                y: cocoaRect.minY,
                width: args.width,
                height: cocoaRect.height,
            )
        }
        return NSRect(
            x: cocoaRect.maxX + args.gap,
            y: cocoaRect.minY,
            width: args.width,
            height: cocoaRect.height,
        )
    }

    /// Returns true if the device is reachable by either Apple's Core Device
    /// stack (devicectl) OR libimobiledevice's usbmuxd. We need both because
    /// the two transports drop independently — locking/unlocking the phone
    /// often kills the Core Device tunnel for a few seconds while the usbmux
    /// connection survives, and we don't want to tear down the panel and its
    /// idevicesyslog subprocesses every time that happens.
    private func iosDeviceAttached(udid: String) -> Bool {
        if iosDeviceAttachedViaDevicectl(udid: udid) { return true }
        if iosDeviceAttachedViaUsbmux(udid: udid) { return true }
        return false
    }

    /// Same as the legacy single-channel check, just renamed to make the
    /// fallback structure in `iosDeviceAttached` obvious.
    private func iosDeviceAttachedViaDevicectl(udid: String) -> Bool {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("sim-console-devicectl-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: tmp) }
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        proc.arguments = [
            "devicectl", "list", "devices",
            "--json-output", tmp.path,
            "--quiet",
        ]
        proc.standardOutput = Pipe()
        proc.standardError = Pipe()
        do {
            try proc.run()
            proc.waitUntilExit()
        } catch {
            return false
        }
        guard proc.terminationStatus == 0,
              let data = try? Data(contentsOf: tmp),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let result = obj["result"] as? [String: Any],
              let devices = result["devices"] as? [[String: Any]]
        else { return false }
        for dev in devices {
            guard let id = dev["identifier"] as? String,
                  let conn = dev["connectionProperties"] as? [String: Any]
            else { continue }
            // Apple ships two UDIDs per device. `identifier` is the modern
            // devicectl/Core-Device UUID (e.g. 34184143-A2AB-57B8-BD74-...);
            // `hardwareProperties.udid` is the older ECID-derived form (e.g.
            // 00008150-001A0C423488401C) that libimobiledevice tools require.
            // The skill's discovery script returns whichever one Apple's
            // tooling surfaces first, and idevicesyslog -u downstream wants
            // the second form, so accept matches on either.
            let hwUdid = (dev["hardwareProperties"] as? [String: Any])?["udid"] as? String
            let isMatch = udid.isEmpty || id == udid || hwUdid == udid
            if !isMatch { continue }
            // Apple's devicectl reports tunnelState=connected when the device
            // is plugged in and the Core Device tunnel is up. Devices we've
            // paired with but aren't physically present are tunnelState=disconnected.
            if let tunnelState = conn["tunnelState"] as? String,
               tunnelState == "connected" { return true }
        }
        return false
    }

    /// Returns true if `idevice_id -l` lists any device matching the UDID
    /// (or any device at all when UDID is empty). Faster than devicectl and
    /// uses the usbmuxd transport — survives Core Device tunnel hiccups that
    /// happen e.g. when the phone is locked/unlocked. Path discovery falls
    /// back to the same Homebrew locations as idevicesyslog.
    private func iosDeviceAttachedViaUsbmux(udid: String) -> Bool {
        let candidates = [
            "/opt/homebrew/bin/idevice_id",
            "/usr/local/bin/idevice_id",
        ]
        let path = candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
            ?? "idevice_id"
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: path.hasPrefix("/") ? path : "/usr/bin/env")
        var argv: [String] = []
        if !path.hasPrefix("/") { argv.append(path) }
        argv.append("-l")
        proc.arguments = argv
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = Pipe()
        do { try proc.run() } catch { return false }
        proc.waitUntilExit()
        guard proc.terminationStatus == 0 else { return false }
        let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let ids = output.split(separator: "\n").map { String($0).trimmingCharacters(in: .whitespaces) }
        if udid.isEmpty { return !ids.isEmpty }
        return ids.contains(udid)
    }

    /// Returns true if `adb -s <serial> get-state` reports "device". Faster
    /// than parsing `adb devices` and doesn't race when multiple emulators
    /// boot/quit around the same time.
    private func androidDeviceAttached(serial: String, adbPath: String) -> Bool {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: adbPath.hasPrefix("/") ? adbPath : "/usr/bin/env")
        var argv: [String] = []
        if !adbPath.hasPrefix("/") { argv.append(adbPath) }
        if !serial.isEmpty { argv.append(contentsOf: ["-s", serial]) }
        argv.append("get-state")
        proc.arguments = argv
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = Pipe()
        do {
            try proc.run()
            proc.waitUntilExit()
        } catch {
            return false
        }
        guard proc.terminationStatus == 0,
              let data = try? pipe.fileHandleForReading.readToEnd(),
              let text = String(data: data, encoding: .utf8) else { return false }
        return text.trimmingCharacters(in: .whitespacesAndNewlines) == "device"
    }
}

// ---------------------------------------------------------------------------
// MARK: - Main

let args = parseArgs()
guard !args.device.isEmpty || args.platform == .web else {
    FileHandle.standardError.write(Data("sim-console: --device required\n".utf8))
    exit(2)
}
guard !args.tag.isEmpty || args.detached else {
    FileHandle.standardError.write(Data("sim-console: --tag required (or pass --detached for USB devices)\n".utf8))
    exit(2)
}
guard !args.tabs.isEmpty else {
    FileHandle.standardError.write(Data("sim-console: at least one --tab \"<kind>|Name|<predicate>\" required\n".utf8))
    exit(2)
}

_ = nudgeAXPrompt()

let app = NSApplication.shared
// .regular = standard macOS app: shows in Dock, owns a menu bar, indexable
// by Spotlight. We used to run as .accessory (no Dock icon) for the
// borderless-overlay era; now SimConsole is a real .app bundle.
app.setActivationPolicy(.regular)

let controller = Controller(args: args)
controller.start()

app.activate(ignoringOtherApps: true)
app.run()
