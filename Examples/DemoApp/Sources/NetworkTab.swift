import SwiftUI
import SimConsole

struct NetworkTab: View {
    @EnvironmentObject var client: DemoNetworkClient

    var body: some View {
        NavigationStack {
            List {
                Section("Real endpoints") {
                    Button("GET /posts/1 — jsonplaceholder") {
                        Task {
                            SimConsole.analytics(event: "tap_network", params: ["scenario": "get_post"])
                            await client.fetch(URL(string: "https://jsonplaceholder.typicode.com/posts/1")!)
                        }
                    }
                    Button("POST /posts — with JSON body") {
                        Task {
                            SimConsole.analytics(event: "tap_network", params: ["scenario": "post_with_body"])
                            let body = try? JSONSerialization.data(withJSONObject: [
                                "title": "SimConsole",
                                "body": "Hello from the demo app",
                                "userId": 1
                            ])
                            await client.fetch(
                                URL(string: "https://jsonplaceholder.typicode.com/posts")!,
                                method: "POST",
                                body: body,
                                contentType: "application/json"
                            )
                        }
                    }
                    Button("GET /users — large list response") {
                        Task {
                            SimConsole.analytics(event: "tap_network", params: ["scenario": "large_response"])
                            await client.fetch(URL(string: "https://jsonplaceholder.typicode.com/users")!)
                        }
                    }
                }

                Section("Mocking target") {
                    Button("GET /flaky — mock me!") {
                        Task {
                            SimConsole.analytics(event: "tap_network", params: ["scenario": "flaky"])
                            // Mock this URL from the sim-console panel (or via the MCP)
                            // to make the request return whatever you want without
                            // touching the network.
                            await client.fetch(URL(string: "https://httpbin.org/uuid")!)
                        }
                    }
                }

                Section("Edge cases") {
                    Button("GET /status/404 — error status") {
                        Task {
                            SimConsole.analytics(event: "tap_network", params: ["scenario": "error_404"])
                            await client.fetch(URL(string: "https://httpbin.org/status/404")!)
                        }
                    }
                    Button("GET /status/500 — server error") {
                        Task {
                            SimConsole.analytics(event: "tap_network", params: ["scenario": "error_500"])
                            await client.fetch(URL(string: "https://httpbin.org/status/500")!)
                        }
                    }
                    Button("GET /delay/3 — slow request") {
                        Task {
                            SimConsole.analytics(event: "tap_network", params: ["scenario": "slow"])
                            await client.fetch(URL(string: "https://httpbin.org/delay/3")!)
                        }
                    }
                    Button("GET unreachable host") {
                        Task {
                            SimConsole.analytics(event: "tap_network", params: ["scenario": "unreachable"])
                            await client.fetch(URL(string: "https://invalid-host-12345.example.com/x")!)
                        }
                    }
                }

                if !client.lastResponse.isEmpty {
                    Section("Last response") {
                        Text(client.lastResponse)
                            .font(.system(size: 11, design: .monospaced))
                            .textSelection(.enabled)
                    }
                }
            }
            .navigationTitle("Network")
            .onAppear { SimConsole.screen("NetworkTab") }
            .overlay {
                if client.isBusy {
                    ProgressView().scaleEffect(1.5)
                }
            }
        }
    }
}
