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
        }
        guard let d = try? JSONDecoder().decode(Decoded.self, from: data),
              let id = d.id, let kind = d.kind else {
            ingestText(rawLine)
            return
        }
        switch kind {
        case "net.request":
            let entry = NetworkEntry(
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
                entries[idx] = .network(existing)
            } else {
                // Response without matching request — synthesize a row anyway.
                let entry = NetworkEntry(
                    id: id, method: "?", url: "(unknown — response without request)",
                    requestHeaders: [:], requestBody: nil,
                    status: d.status, durationMs: d.duration_ms,
                    responseHeaders: d.headers ?? [:], responseBody: d.body,
                    byteSize: d.byte_size, error: nil,
                    createdAt: d.t.flatMap { Date(timeIntervalSince1970: $0) } ?? Date()
                )
                append(.network(entry))
            }
        case "net.error":
            if let idx = requestIndex[id],
               case .network(var existing) = entries[idx] {
                existing.error = d.error
                existing.durationMs = d.duration_ms
                entries[idx] = .network(existing)
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
            case .network:   NetworkList(model: active)
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

    init(tabs: [TabViewModel], appLabel: String, accent: Color) {
        self.tabs = tabs
        self.appLabel = appLabel
        self.accent = accent
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
                        NetworkRow(entry: e, expanded: expanded.contains(e.id))
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
                NetworkDetail(entry: entry)
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
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
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
    var lastFrame: NSRect = .zero
    var refreshTimer: Timer?

    init(args: Args) {
        self.args = args
        let tabs = args.tabs.map { TabViewModel(spec: $0) }
        let appLabel = args.appLabel.isEmpty ? "sim-console" : args.appLabel
        let state = ConsoleState(tabs: tabs, appLabel: appLabel, accent: args.accent)
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
