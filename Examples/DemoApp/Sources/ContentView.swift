import SwiftUI
import SimConsole

/// Demo app root. Pre-tab-bar redesign: a single home screen organized
/// into thematic sections that push to the existing detail views via
/// NavigationStack. Each detail view exercises one slice of the SDK
/// (analytics, network, metrics, logs, auto-fire, embedded WebView).
struct ContentView: View {
    var body: some View {
        NavigationStack {
            List {
                Section("Events") {
                    NavigationLink {
                        AnalyticsTab()
                    } label: {
                        Row(icon: "chart.bar.fill", title: "Analytics",
                            subtitle: "screen views, typed events, user properties")
                    }
                    NavigationLink {
                        LogsTab()
                    } label: {
                        Row(icon: "doc.text", title: "Logs",
                            subtitle: ".debug .info .warn .error with rich field payloads")
                    }
                }

                Section("Telemetry") {
                    NavigationLink {
                        MetricsTab()
                    } label: {
                        Row(icon: "speedometer", title: "Metrics",
                            subtitle: "gauges, counters, signposts, hang triggers")
                    }
                    NavigationLink {
                        NetworkTab()
                    } label: {
                        Row(icon: "network", title: "Network",
                            subtitle: "real endpoints, mocking target, edge cases")
                    }
                }

                Section("Integrations") {
                    NavigationLink {
                        WebViewTab()
                    } label: {
                        Row(icon: "safari", title: "WebView",
                            subtitle: "JS in an embedded WKWebView flows through native SimConsole")
                    }
                }

                Section("Stress test") {
                    NavigationLink {
                        ActivityTab()
                    } label: {
                        Row(icon: "play.circle", title: "Auto activity",
                            subtitle: "fire mixed analytics + network + logs on an interval")
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("SimConsole demo")
        }
        .onAppear {
            SimConsole.screen("HomeScreen")
            // appFinishLaunching is idempotent — only the FIRST call (when the
            // root view first appears after cold start) emits metric.launch.
            // Subsequent .onAppear invocations on tab/section transitions are
            // no-ops, so the panel's launch number doesn't drift.
            SimConsole.metric.appFinishLaunching()
        }
    }
}

/// One row in the home list. Two-line layout (title + sub) plus an SF
/// Symbol icon so the home reads like Apple's own Settings / Shortcuts
/// without any custom artwork.
private struct Row: View {
    let icon: String
    let title: String
    let subtitle: String

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 18, weight: .regular))
                .foregroundColor(.accentColor)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 16, weight: .medium))
                Text(subtitle)
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
                    .lineLimit(2)
            }
        }
        .padding(.vertical, 4)
    }
}

#Preview {
    ContentView()
}
