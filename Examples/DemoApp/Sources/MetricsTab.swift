import SwiftUI
import SimConsole

/// Demonstrates the SimConsole.metric API surface — launch milestones fire
/// from ContentView; this tab adds buttons to deliberately trigger hangs,
/// burn CPU, run signposts, and update gauges/counters.
struct MetricsTab: View {
    @State private var hangCount: Int = 0
    @State private var cpuBurnedMs: Int = 0
    @State private var cacheHitRate: Double = 0.92
    @State private var queueDepth: Int = 3

    var body: some View {
        NavigationStack {
            List {
                Section("Trigger hangs") {
                    Button("Hang main thread (400ms)") {
                        Thread.sleep(forTimeInterval: 0.4)
                        hangCount += 1
                    }
                    Button("Hang main thread (1.5s)") {
                        Thread.sleep(forTimeInterval: 1.5)
                        hangCount += 1
                    }
                    Text("Triggered \(hangCount) times — check Metrics → Hangs")
                        .font(.caption).foregroundColor(.secondary)
                }

                Section("Burn CPU") {
                    Button("Tight loop ~300ms") {
                        let start = Date()
                        var x = 0.0
                        while Date().timeIntervalSince(start) < 0.3 {
                            for _ in 0..<10_000 { x = x.squareRoot() + 1 }
                        }
                        cpuBurnedMs += 300
                    }
                    Text("Burned ~\(cpuBurnedMs) ms — watch CPU sparkline in Metrics").font(.caption).foregroundColor(.secondary)
                }

                Section("Signposts") {
                    Button("Run \"feed_decode\" (≈ 80ms)") {
                        SimConsole.metric.measure("feed_decode", fields: ["count": 50]) {
                            // Simulate work: spin briefly without blocking too long.
                            let start = Date()
                            var x = 0.0
                            while Date().timeIntervalSince(start) < 0.08 {
                                for _ in 0..<1000 { x = x.squareRoot() + 1 }
                            }
                        }
                    }
                    Button("Manual signpost: db.query 215ms") {
                        SimConsole.metric.signpost("db.query", durationMs: 215, fields: ["table": "messages"])
                    }
                }

                Section("Gauges + counters") {
                    HStack {
                        Text("cache.hit_rate")
                        Spacer()
                        Slider(value: $cacheHitRate, in: 0...1, step: 0.05)
                            .frame(width: 140)
                            .onChange(of: cacheHitRate) { newValue in
                                SimConsole.metric.gauge("cache.hit_rate", value: newValue)
                            }
                        Text(String(format: "%.0f%%", cacheHitRate * 100))
                            .font(.system(size: 11, design: .monospaced))
                    }
                    Stepper("queue.depth: \(queueDepth)", value: $queueDepth, in: 0...20)
                        .onChange(of: queueDepth) { newValue in
                            SimConsole.metric.gauge("queue.depth", value: Double(newValue))
                        }
                    Button("Increment network.retries") {
                        SimConsole.metric.counter("network.retries", increment: 1)
                    }
                    Button("Increment errors.caught (×3)") {
                        SimConsole.metric.counter("errors.caught", increment: 3)
                    }
                }
            }
            .navigationTitle("Metrics")
            .onAppear {
                SimConsole.screen("MetricsTab")
                // Seed the gauges so they show up in the Metrics panel immediately.
                SimConsole.metric.gauge("cache.hit_rate", value: cacheHitRate)
                SimConsole.metric.gauge("queue.depth", value: Double(queueDepth))
            }
        }
    }
}
