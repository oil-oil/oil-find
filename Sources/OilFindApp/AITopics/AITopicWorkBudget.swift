import Foundation
import Darwin

/// A cooperative CPU budget for historical imports; search runs on a separate queue.
/// Individual JSON/Compression calls may burst, so this controls sustained thread CPU time.
final class AITopicWorkBudget {
    private let fraction: Double
    private var wall = ProcessInfo.processInfo.systemUptime
    private var cpu: Double
    private var externalCPU: Double = 0
    private var nextCheck: Double = 0
    init(fraction: Double = 0.25) {
        self.fraction = min(1, max(0.05, fraction)); cpu = Self.threadCPU()
    }
    private static func threadCPU() -> Double {
        var time = timespec()
        guard clock_gettime(CLOCK_THREAD_CPUTIME_ID, &time) == 0 else { return 0 }
        return Double(time.tv_sec) + Double(time.tv_nsec) / 1_000_000_000
    }
    func chargeExternalCPU(_ seconds: Double) {
        if seconds.isFinite && seconds > 0 { externalCPU += seconds; nextCheck = 0 }
    }
    func checkpoint(isCancelled: () -> Bool) {
        var now = ProcessInfo.processInfo.systemUptime
        guard now >= nextCheck else { return }
        let used = Self.threadCPU() + externalCPU
        var delay = max(0, (used - cpu) / fraction - (now - wall))
        while delay > 0.001 && !isCancelled() {
            Thread.sleep(forTimeInterval: min(0.01, delay))
            now = ProcessInfo.processInfo.systemUptime
            delay = (used - cpu) / fraction - (now - wall)
        }
        if now - wall >= 1 { wall = now; cpu = Self.threadCPU(); externalCPU = 0 }
        nextCheck = now + 0.005
    }
}
