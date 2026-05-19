import Foundation
#if canImport(UIKit)
import UIKit
import QuartzCore
#endif

/// Periodically samples system metrics (memory, CPU, FPS, thermal, battery)
/// and emits them via `Metric.sample(...)`. Started automatically by
/// `SimConsole.bootstrap` on iOS targets; no-op on macOS host so the SwiftPM
/// host build keeps compiling for tests.
final class MetricSampler {
    static let shared = MetricSampler()

    private var timer: Timer?
    private var peakResidentMB: Double = 0
    private var lastCPUTotalUsage: Double = 0
    private var lastCPUSampleTime: TimeInterval = 0

    #if canImport(UIKit)
    private var displayLink: CADisplayLink?
    private var frameCount: Int = 0
    private var hitchCount: Int = 0
    private var lastFrameTime: CFTimeInterval = 0
    private var lastFPSEmit: CFTimeInterval = 0
    #endif

    private init() {}

    func start(intervalSeconds: TimeInterval = 1.0) {
        #if canImport(UIKit)
        guard timer == nil else { return }

        // 1 Hz sampler (memory, CPU, thermal, battery).
        let t = Timer(timeInterval: intervalSeconds, repeats: true) { [weak self] _ in
            self?.tick()
        }
        RunLoop.main.add(t, forMode: .common)
        self.timer = t

        // Enable battery monitoring so .batteryLevel returns a real value.
        UIDevice.current.isBatteryMonitoringEnabled = true

        // CADisplayLink ticks every frame; we accumulate then emit at 1 Hz.
        let dl = CADisplayLink(target: self, selector: #selector(frameTick(_:)))
        dl.add(to: .main, forMode: .common)
        self.displayLink = dl
        #endif
    }

    func stop() {
        timer?.invalidate(); timer = nil
        #if canImport(UIKit)
        displayLink?.invalidate(); displayLink = nil
        #endif
    }

    // MARK: - 1 Hz tick

    private func tick() {
        if let mb = Self.residentMemoryMB() {
            Metric.sample(name: "memory.resident_mb", value: mb)
            if mb > peakResidentMB {
                peakResidentMB = mb
                Metric.sample(name: "memory.peak_mb", value: peakResidentMB)
            }
        }
        if let pct = Self.processCPUPercent() {
            Metric.sample(name: "cpu.process_pct", value: pct)
        }
        #if canImport(UIKit)
        emitThermal()
        emitBattery()
        #endif
    }

    // MARK: - Memory (mach_task_basic_info)

    private static func residentMemoryMB() -> Double? {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
        let kerr: kern_return_t = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        guard kerr == KERN_SUCCESS else { return nil }
        return Double(info.resident_size) / 1024.0 / 1024.0
    }

    // MARK: - CPU (sum of running thread usage)

    private static func processCPUPercent() -> Double? {
        var threadsList: thread_act_array_t?
        var threadsCount: mach_msg_type_number_t = 0
        guard task_threads(mach_task_self_, &threadsList, &threadsCount) == KERN_SUCCESS,
              let threads = threadsList else { return nil }
        defer {
            vm_deallocate(mach_task_self_,
                          vm_address_t(bitPattern: threads),
                          vm_size_t(Int(threadsCount) * MemoryLayout<thread_t>.size))
        }
        var totalUsage: Double = 0
        for i in 0..<Int(threadsCount) {
            var info = thread_basic_info()
            var size = mach_msg_type_number_t(MemoryLayout<thread_basic_info>.size / MemoryLayout<integer_t>.size)
            let kerr = withUnsafeMutablePointer(to: &info) {
                $0.withMemoryRebound(to: integer_t.self, capacity: Int(size)) {
                    thread_info(threads[i], thread_flavor_t(THREAD_BASIC_INFO), $0, &size)
                }
            }
            if kerr == KERN_SUCCESS, (info.flags & TH_FLAGS_IDLE) == 0 {
                totalUsage += Double(info.cpu_usage) / Double(TH_USAGE_SCALE) * 100.0
            }
        }
        return totalUsage
    }

    // MARK: - Thermal + battery (iOS)

    #if canImport(UIKit)
    private func emitThermal() {
        let state = ProcessInfo.processInfo.thermalState
        let name: String
        switch state {
        case .nominal:  name = "nominal"
        case .fair:     name = "fair"
        case .serious:  name = "serious"
        case .critical: name = "critical"
        @unknown default: name = "unknown"
        }
        Metric.sample(name: "thermal", value: Double(state.rawValue), fields: ["state": name])
    }

    private func emitBattery() {
        let level = UIDevice.current.batteryLevel
        let state = UIDevice.current.batteryState
        let charging: Bool = (state == .charging || state == .full)
        if level >= 0 {
            Metric.sample(name: "battery.level", value: Double(level))
        }
        Metric.sample(name: "battery.charging", value: charging ? 1 : 0)
    }
    #endif

    // MARK: - FPS via CADisplayLink

    #if canImport(UIKit)
    @objc private func frameTick(_ link: CADisplayLink) {
        let now = link.timestamp
        if lastFrameTime > 0 {
            let frameDelta = now - lastFrameTime
            // Hitch = a frame that took longer than ~16.7ms (60Hz nominal).
            // ProMotion 120Hz would target ~8.3ms; we use a single threshold
            // for simplicity. False positives on sim are OK — it's a relative metric.
            if frameDelta > 0.0167 * 1.5 { hitchCount += 1 }
        }
        lastFrameTime = now
        frameCount += 1

        // Emit once per second.
        if lastFPSEmit == 0 { lastFPSEmit = now }
        if now - lastFPSEmit >= 1.0 {
            let elapsed = now - lastFPSEmit
            let fps = Double(frameCount) / elapsed
            Metric.sample(name: "fps.avg_1s", value: fps)
            Metric.sample(name: "fps.hitches_1s", value: Double(hitchCount))
            frameCount = 0
            hitchCount = 0
            lastFPSEmit = now
        }
    }
    #endif
}
