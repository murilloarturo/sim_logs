import Foundation

/// Main-thread watchdog. A background queue pings the main thread every
/// `pingInterval` seconds; if the main thread doesn't respond within
/// `hangThreshold`, we record a hang event with the actual blocked duration.
///
/// This is iOS's equivalent of "ANR detection" and the highest-signal metric
/// per Apple's own guidance — top apps target <0.1% session hang rate.
///
/// Debug builds only. The watchdog runs forever once started; cost is a
/// timer + a dispatch_after, negligible overhead.
final class HangDetector {
    static let shared = HangDetector()

    private let pingInterval: TimeInterval = 0.05  // 50ms ping rate
    private let hangThreshold: TimeInterval = 0.25 // 250ms = Apple's hang threshold
    private let queue = DispatchQueue(label: "com.simconsole.hangdetector", qos: .userInteractive)
    private var lastPing: Date = Date()
    private var running = false

    private init() {}

    func start() {
        guard !running else { return }
        running = true
        lastPing = Date()
        schedulePing()
    }

    func stop() {
        running = false
    }

    private func schedulePing() {
        queue.asyncAfter(deadline: .now() + pingInterval) { [weak self] in
            guard let self, self.running else { return }
            let sentAt = Date()
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                // The main thread picked up our message — measure the gap
                // since the previous ping. If it was longer than threshold,
                // the main thread was blocked.
                let now = Date()
                let mainThreadDelay = now.timeIntervalSince(sentAt)
                if mainThreadDelay > self.hangThreshold {
                    Metric.hang(durationMs: Int(mainThreadDelay * 1000))
                }
                self.lastPing = now
                self.schedulePing()
            }
        }
    }
}
