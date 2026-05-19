import SwiftUI
import SimConsole

/// Auto-generates activity across all three streams (analytics, network, logs)
/// at a configurable cadence so a first-time user can see the console light up
/// without manually tapping every button.
struct ActivityTab: View {
    @EnvironmentObject var client: DemoNetworkClient
    @State private var running: Bool = false
    @State private var tickCount: Int = 0
    @State private var task: Task<Void, Never>?
    @State private var intervalSeconds: Double = 1.5

    let endpoints: [(method: String, url: String, hasBody: Bool)] = [
        ("GET",  "https://jsonplaceholder.typicode.com/posts/1", false),
        ("GET",  "https://jsonplaceholder.typicode.com/users/2", false),
        ("GET",  "https://jsonplaceholder.typicode.com/comments?postId=1", false),
        ("GET",  "https://httpbin.org/status/200", false),
        ("GET",  "https://httpbin.org/status/404", false),
        ("POST", "https://jsonplaceholder.typicode.com/posts", true),
    ]
    let events = ["page_view", "button_tapped", "scroll", "swipe", "long_press"]

    var body: some View {
        NavigationStack {
            Form {
                Section("Activity generator") {
                    Toggle(isOn: $running) {
                        Text(running ? "Running" : "Stopped")
                            .font(.headline)
                    }
                    .onChange(of: running) { newValue in
                        if newValue { start() } else { stop() }
                    }

                    HStack {
                        Text("Cadence")
                        Slider(value: $intervalSeconds, in: 0.3...5.0, step: 0.1)
                        Text(String(format: "%.1fs", intervalSeconds))
                            .font(.system(size: 12, design: .monospaced))
                            .frame(width: 50, alignment: .trailing)
                    }

                    HStack {
                        Text("Ticks fired")
                        Spacer()
                        Text("\(tickCount)")
                            .font(.system(size: 14, design: .monospaced))
                            .foregroundColor(.secondary)
                    }
                }

                Section("What it does") {
                    Label("Fires one analytics event per tick", systemImage: "chart.bar")
                    Label("Hits one of \(endpoints.count) endpoints per tick", systemImage: "network")
                    Label("Logs one structured event per tick", systemImage: "doc.text")
                }
            }
            .navigationTitle("Auto")
            .onAppear { SimConsole.screen("ActivityTab") }
            .onDisappear { stop() }
        }
    }

    private func start() {
        stop()
        task = Task {
            while !Task.isCancelled {
                await tick()
                try? await Task.sleep(nanoseconds: UInt64(intervalSeconds * 1_000_000_000))
            }
        }
    }

    private func stop() {
        task?.cancel()
        task = nil
    }

    @MainActor
    private func tick() async {
        tickCount += 1
        let n = tickCount

        SimConsole.analytics(event: events.randomElement()!, params: [
            "tick": n,
            "session": "auto",
            "weight": Double.random(in: 0...1)
        ])

        SimConsole.log("Auto-tick", level: .info, fields: [
            "tick": n,
            "rss_mb": Int.random(in: 80...140)
        ])

        let endpoint = endpoints.randomElement()!
        if let url = URL(string: endpoint.url) {
            let body: Data? = endpoint.hasBody
                ? try? JSONSerialization.data(withJSONObject: ["tick": n, "src": "auto"])
                : nil
            await client.fetch(
                url, method: endpoint.method,
                body: body,
                contentType: endpoint.hasBody ? "application/json" : nil
            )
        }
    }
}
