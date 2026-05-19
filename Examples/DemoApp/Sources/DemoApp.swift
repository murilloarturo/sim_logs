import SwiftUI
import SimConsole

@main
struct DemoApp: App {
    @StateObject private var client = DemoNetworkClient()

    init() {
        SimConsole.bootstrap(.init(
            subsystem: Bundle.main.bundleIdentifier ?? "com.simconsole.demoapp"
        ))
        SimConsole.log("DemoApp launched", level: .info, fields: [
            "build": "debug",
            "version": "1.0.0"
        ])
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(client)
                .task {
                    // First-launch demo: fires one GET so a freshly-opened
                    // sim-console viewer immediately sees a paired
                    // net.request/net.response with body, headers, and timing.
                    await client.fetch(URL(string: "https://jsonplaceholder.typicode.com/posts/1")!)
                }
        }
    }
}
