import SwiftUI
import SimConsole

struct ContentView: View {
    var body: some View {
        TabView {
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
        }
    }
}

#Preview {
    ContentView()
}
