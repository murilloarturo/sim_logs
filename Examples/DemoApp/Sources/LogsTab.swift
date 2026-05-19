import SwiftUI
import SimConsole

struct LogsTab: View {
    @State private var counter: Int = 0

    var body: some View {
        NavigationStack {
            List {
                Section("Levels") {
                    Button("Log .debug") {
                        counter += 1
                        SimConsole.log("Debug log line #\(counter)", level: .debug, fields: ["counter": counter])
                    }
                    Button("Log .info") {
                        counter += 1
                        SimConsole.log("Info log line #\(counter)", level: .info, fields: ["counter": counter])
                    }
                    Button("Log .warn") {
                        counter += 1
                        SimConsole.log("Warning log line #\(counter)", level: .warn, fields: ["counter": counter])
                    }
                    Button("Log .error") {
                        counter += 1
                        SimConsole.log("Error log line #\(counter)", level: .error, fields: [
                            "counter": counter,
                            "stack_trace": "DemoApp.LogsTab.body:42 → SimConsole.log",
                            "user_action": "tap"
                        ])
                    }
                }

                Section("Rich payloads") {
                    Button("Log nested object (typed model)") {
                        SimConsole.track(SimConsole.LogEvent(
                            message: "Cart contents updated",
                            level: .info,
                            fields: [
                                "items": [
                                    ["sku": "A1", "qty": 2, "price": 19.99],
                                    ["sku": "B7", "qty": 1, "price": 4.50]
                                ],
                                "total": 44.48,
                                "currency": "USD"
                            ]
                        ))
                    }
                    Button("Log generic dict form") {
                        SimConsole.log("Quick log via dict form", level: .info, fields: [
                            "items": [
                                ["sku": "C3", "qty": 1, "price": 12.00]
                            ],
                            "total": 12.00,
                            "currency": "USD"
                        ])
                    }
                    Button("Log database query") {
                        SimConsole.log("SQL query executed", level: .debug, fields: [
                            "query": "SELECT id, name FROM users WHERE active = 1 LIMIT 50",
                            "duration_ms": Int.random(in: 1...80),
                            "rows": Int.random(in: 1...50)
                        ])
                    }
                    Button("Log cache miss") {
                        SimConsole.log("Cache miss", level: .info, fields: [
                            "key": "user:profile:\(UUID().uuidString.prefix(8))",
                            "fallback": "remote",
                            "ttl_seconds": 300
                        ])
                    }
                }

                Section("Errors") {
                    Button("Log decoded API error") {
                        SimConsole.log("Decode failed", level: .error, fields: [
                            "endpoint": "/api/v1/profile",
                            "expected": "User",
                            "received_keys": ["id", "username"],
                            "missing_keys": ["email", "createdAt"]
                        ])
                    }
                    Button("Log unhandled exception") {
                        SimConsole.log("Unhandled exception caught", level: .error, fields: [
                            "kind": "NSInvalidArgumentException",
                            "reason": "-[NSNull length]: unrecognized selector sent to instance",
                            "context": "ContentView.body"
                        ])
                    }
                }
            }
            .navigationTitle("Logs")
            .onAppear { SimConsole.screen("LogsTab") }
        }
    }
}
