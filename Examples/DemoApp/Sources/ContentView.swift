import SwiftUI
import SimConsole

struct ContentView: View {
    var body: some View {
        TabView {
            MetricsTab()
                .tabItem {
                    Label("Metrics", systemImage: "speedometer")
                }
            NetworkTab()
                .tabItem {
                    Label("Network", systemImage: "network")
                }
            AnalyticsTab()
                .tabItem {
                    Label("Analytics", systemImage: "chart.bar.fill")
                }
            LogsTab()
                .tabItem {
                    Label("Logs", systemImage: "doc.text")
                }
            ActivityTab()
                .tabItem {
                    Label("Auto", systemImage: "play.circle")
                }
        }
        .onAppear {
            SimConsole.screen("RootView")
            // appFinishLaunching is idempotent — only the FIRST call (when the
            // root view first appears after cold start) emits metric.launch.
            // Subsequent .onAppear invocations on tab switches are no-ops, so
            // the panel's launch-time number doesn't drift.
            SimConsole.metric.appFinishLaunching()
        }
    }
}

#Preview {
    ContentView()
}
