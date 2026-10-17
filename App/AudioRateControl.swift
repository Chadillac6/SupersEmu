import Foundation

enum AudioRateControl {
    static func rate(
        bufferedFrames: Int,
        capacityFrames: Int,
        engineRunning: Bool = true,
        maxDeviation: Double = 0.005
    ) -> Double {
        guard engineRunning, capacityFrames > 0 else { return 1.0 }
        let maxDeviation = max(maxDeviation, 0)
        let target = Double(capacityFrames) / 2
        let deviation = maxDeviation * (target - Double(bufferedFrames)) / target
        return min(1 + maxDeviation, max(1 - maxDeviation, 1 + deviation))
    }
}
