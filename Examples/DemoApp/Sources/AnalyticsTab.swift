import SwiftUI
import SimConsole

struct AnalyticsTab: View {
    @State private var counter: Int = 0
    @State private var lastEvent: String = ""

    var body: some View {
        NavigationStack {
            List {
                Section("Events") {
                    Button("Fire tap event") {
                        counter += 1
                        SimConsole.analytics(event: "demo_button_tapped", params: [
                            "counter": counter,
                            "section": "events"
                        ])
                        lastEvent = "demo_button_tapped #\(counter)"
                    }
                    Button("Fire purchase event (typed model)") {
                        // Typed model — self-documenting alternative to the dict form.
                        SimConsole.track(SimConsole.AnalyticsEvent(
                            name: "purchase",
                            params: [
                                "sku": "premium_monthly",
                                "currency": "USD",
                                "price": 9.99,
                                "trial": false
                            ]
                        ))
                        lastEvent = "purchase (premium_monthly)"
                    }
                    Button("Fire signup event") {
                        SimConsole.analytics(event: "user_signup", params: [
                            "method": "email",
                            "campaign": "fall_2026",
                            "referrer": "twitter"
                        ])
                        lastEvent = "user_signup (email)"
                    }
                    Button("Fire share event") {
                        SimConsole.analytics(event: "share", params: [
                            "platform": ["twitter", "instagram", "whatsapp"].randomElement()!,
                            "content_type": "article",
                            "content_id": UUID().uuidString
                        ])
                        lastEvent = "share"
                    }
                }

                Section("Screen views") {
                    Button("Screen: Home") {
                        SimConsole.screen("Home", params: ["source": "demo"])
                        lastEvent = "screen: Home"
                    }
                    Button("Screen: Settings") {
                        SimConsole.screen("Settings", params: ["source": "demo"])
                        lastEvent = "screen: Settings"
                    }
                    Button("Screen: Profile (typed model)") {
                        SimConsole.track(SimConsole.ScreenView(
                            name: "Profile",
                            params: [
                                "source": "demo",
                                "user_id": "demo-user-123"
                            ]
                        ))
                        lastEvent = "screen: Profile"
                    }
                }

                Section("User properties") {
                    Button("Set user properties") {
                        SimConsole.log("setUserProperties", level: .info, fields: [
                            "country": "ES",
                            "language": "en-US",
                            "premium": false,
                            "ab_variant": "B"
                        ])
                        lastEvent = "user properties updated"
                    }
                }

                if !lastEvent.isEmpty {
                    Section("Last fired") {
                        Text(lastEvent)
                            .font(.system(size: 12, design: .monospaced))
                    }
                }
            }
            .navigationTitle("Analytics")
            .onAppear { SimConsole.screen("AnalyticsTab") }
        }
    }
}
