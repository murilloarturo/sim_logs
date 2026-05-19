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

struct TabSpec {
    enum Kind: String { case network, analytics, text }
    let kind: Kind
    let name: String
    let predicate: String
}

struct Args {
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
        default: i += 1
        }
    }
    return a
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

func axToCocoa(_ axRect: CGRect) -> CGRect {
    guard let primary = NSScreen.screens.first else { return axRect }
    let topY = primary.frame.maxY
    return CGRect(
        x: axRect.origin.x,
        y: topY - axRect.origin.y - axRect.size.height,
        width: axRect.size.width,
        height: axRect.size.height
    )
}

func simulatorAppRunning() -> Bool {
    NSWorkspace.shared.runningApplications.contains {
        $0.bundleIdentifier == "com.apple.iphonesimulator"
    }
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

enum TabEntry: Identifiable {
    case network(NetworkEntry)
    case analytics(AnalyticsEntry)
    case text(TextEntry)

    var id: String {
        switch self {
        case .network(let e): return "net-\(e.id)"
        case .analytics(let e): return "ana-\(e.id.uuidString)"
        case .text(let e): return "txt-\(e.id.uuidString)"
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
    weak var exporter: Exporter?

    init(spec: TabSpec) {
        self.id = "\(spec.kind.rawValue)-\(spec.name)"
        self.spec = spec
    }

    func start(device: String, level: String) {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        proc.arguments = [
            "simctl", "spawn", device, "log", "stream",
            "--predicate", spec.predicate,
            "--level", level,
            "--style", "compact"
        ]
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
            diag("tab '\(spec.name)' pid=\(proc.processIdentifier) predicate=\(spec.predicate)")
        } catch {
            diag("tab '\(spec.name)' stream failed: \(error)")
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
            ingest(String(line))
        }
    }

    private func ingest(_ rawLine: String) {
        if Self.isBoilerplate(rawLine) { return }
        switch spec.kind {
        case .network:   ingestNetwork(rawLine)
        case .analytics: ingestAnalytics(rawLine)
        case .text:      ingestText(rawLine)
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

    private static func parseMessageType(_ line: String) -> TextEntry.MessageType {
        // 3rd whitespace-separated token in compact style is the type letter.
        let parts = line.split(separator: " ", maxSplits: 4, omittingEmptySubsequences: true)
        guard parts.count >= 4 else { return .default }
        switch String(parts[2]) {
        case "E":  return .error
        case "F":  return .fault
        case "I":  return .info
        case "Db": return .debug
        default:   return .default
        }
    }

    // The `log stream` subprocess emits a few setup lines when it starts.
    private static func isBoilerplate(_ line: String) -> Bool {
        if line.hasPrefix("getpwuid_r ") { return true }
        if line.hasPrefix("Filtering the log data using ") { return true }
        if line.hasPrefix("Timestamp ") { return true }
        if line.hasPrefix("Skipping info and debug messages") { return true }
        return false
    }
}

// ---------------------------------------------------------------------------
// MARK: - SwiftUI

private enum Theme {
    static let bg = Color(red: 0.08, green: 0.08, blue: 0.08)
    static let rowBg = Color(red: 0.10, green: 0.10, blue: 0.10)
    static let rowAlt = Color(red: 0.12, green: 0.12, blue: 0.12)
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
            HeaderBar(state: state)
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
        HStack {
            Text(state.appLabel)
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(.black)
                .padding(.horizontal, 10)
        }
        .frame(maxWidth: .infinity, minHeight: 22, alignment: .leading)
        .background(state.accent)
    }
}

struct SegmentBar: View {
    @ObservedObject var state: ConsoleState
    var body: some View {
        HStack(spacing: 4) {
            ForEach(Array(state.tabs.enumerated()), id: \.element.id) { idx, tab in
                SegmentChip(
                    label: tab.spec.name,
                    badge: tab === state.activeTab ? 0 : tab.unread,
                    active: idx == state.activeIndex
                )
                .onTapGesture { state.select(idx) }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
    }
}

struct SegmentChip: View {
    let label: String
    let badge: Int
    let active: Bool
    var body: some View {
        HStack(spacing: 4) {
            Text(label)
                .font(.system(size: 11, weight: active ? .semibold : .regular))
                .foregroundColor(active ? Theme.textPrimary : Theme.textSecondary)
            if badge > 0 {
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
/// Uses the same warm accent as the `MOCKED` pill in the expanded detail
/// so the two states read as one consistent visual language.
struct MockedBadge: View {
    var body: some View {
        Text("MOCK")
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
// MARK: - Borderless keyable panel

final class KeyablePanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
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

    init(args: Args) {
        self.args = args
        self.exporter = Exporter(path: args.exportTo)
        let tabs = args.tabs.map { TabViewModel(spec: $0) }
        for t in tabs { t.exporter = self.exporter }
        let appLabel = args.appLabel.isEmpty ? "sim-console" : args.appLabel
        let mockStore: MockStore? = args.bundleId.isEmpty ? nil : MockStore(bundleId: args.bundleId)
        let state = ConsoleState(tabs: tabs, appLabel: appLabel, accent: args.accent, mockStore: mockStore)
        self.state = state

        let panel = KeyablePanel(
            contentRect: NSRect(x: 0, y: 0, width: args.width, height: 700),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = true
        panel.backgroundColor = NSColor(calibratedWhite: 0.08, alpha: 1.0)
        panel.hasShadow = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        panel.isMovable = false
        panel.hidesOnDeactivate = false
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = true

        let hosting = NSHostingView(rootView: RootView(state: state))
        hosting.frame = NSRect(origin: .zero, size: panel.frame.size)
        hosting.autoresizingMask = [.width, .height]
        panel.contentView = hosting

        self.panel = panel
    }

    func start() {
        for tab in state.tabs { tab.start(device: args.device, level: args.level) }
        let timer = Timer(timeInterval: 0.2, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(timer, forMode: .common)
        self.refreshTimer = timer
        tick()
    }

    private func tick() {
        if !simulatorAppRunning() {
            diag("Simulator.app no longer running; exiting")
            for tab in state.tabs { tab.stop() }
            exit(0)
        }
        guard let window = findSimulatorWindow(matching: args.tag, fallback: args.altTag) else {
            panel.orderOut(nil); return
        }
        guard let axRect = windowFrame(window) else { return }
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

        if overlayRect != lastFrame {
            diag("frame → \(Int(overlayRect.minX)),\(Int(overlayRect.minY)) \(Int(overlayRect.width))x\(Int(overlayRect.height))")
            panel.setFrame(overlayRect, display: true)
            lastFrame = overlayRect
        }
        if !panel.isVisible {
            panel.orderFrontRegardless()
        }
    }
}

// ---------------------------------------------------------------------------
// MARK: - Main

let args = parseArgs()
guard !args.device.isEmpty else {
    FileHandle.standardError.write(Data("sim-console: --device required\n".utf8))
    exit(2)
}
guard !args.tag.isEmpty else {
    FileHandle.standardError.write(Data("sim-console: --tag required\n".utf8))
    exit(2)
}
guard !args.tabs.isEmpty else {
    FileHandle.standardError.write(Data("sim-console: at least one --tab \"<kind>|Name|<predicate>\" required\n".utf8))
    exit(2)
}

_ = nudgeAXPrompt()

let app = NSApplication.shared
app.setActivationPolicy(.accessory)

let controller = Controller(args: args)
controller.start()

app.run()
