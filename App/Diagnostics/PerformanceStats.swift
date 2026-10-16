import Foundation

struct PerformanceStats {
    struct Summary: Equatable {
        let speedPercent: Double
        let averageRunMilliseconds: Double
        let maximumRunMilliseconds: Double
        let averagePresentMilliseconds: Double
        let lateTicks: Int
        let audioUnderrunMilliseconds: Double
        let audioOverflowMilliseconds: Double
        let bufferedAudioMilliseconds: Double

        func performanceLine(thermalState: String) -> String {
            String(
                format: "perf speed=%.0f%% run=%.1f/%.1fms present=%.1fms late=%d underrun=%.0fms overflow=%.0fms buffered=%.0fms thermal=%@",
                locale: Locale(identifier: "en_US_POSIX"),
                speedPercent,
                averageRunMilliseconds,
                maximumRunMilliseconds,
                averagePresentMilliseconds,
                lateTicks,
                audioUnderrunMilliseconds,
                audioOverflowMilliseconds,
                bufferedAudioMilliseconds,
                thermalState)
        }
    }

    private struct Tick {
        let timestamp: TimeInterval
        let runSeconds: TimeInterval
        let presentSeconds: TimeInterval
        let wasLate: Bool
        let underrunDelta: UInt64
        let overflowDelta: UInt64
        let bufferedFrames: Int
    }

    private let windowDuration: TimeInterval
    private var ticks: [Tick] = []
    private var previousTimestamp: TimeInterval?
    private var previousUnderrunFrames: UInt64?
    private var previousOverflowFrames: UInt64?

    init(windowDuration: TimeInterval = 5) {
        self.windowDuration = max(windowDuration, 0.01)
    }

    mutating func record(
        runDuration: TimeInterval,
        presentDuration: TimeInterval,
        timestamp: TimeInterval,
        framesPerSecond: Double,
        sampleRate: Double,
        audioUnderrunFrames: UInt64,
        audioOverflowFrames: UInt64,
        bufferedAudioFrames: Int
    ) {
        let targetInterval = framesPerSecond > 0 ? 1 / framesPerSecond : 0
        let interval = previousTimestamp.map { timestamp - $0 }
        let underrunDelta = previousUnderrunFrames.map { audioUnderrunFrames >= $0 ? audioUnderrunFrames - $0 : 0 } ?? 0
        let overflowDelta = previousOverflowFrames.map { audioOverflowFrames >= $0 ? audioOverflowFrames - $0 : 0 } ?? 0
        ticks.append(Tick(
            timestamp: timestamp,
            runSeconds: max(runDuration, 0),
            presentSeconds: max(presentDuration, 0),
            wasLate: interval.map { $0 > targetInterval * 1.5 } ?? false,
            underrunDelta: underrunDelta,
            overflowDelta: overflowDelta,
            bufferedFrames: max(bufferedAudioFrames, 0)))
        ticks.removeAll { $0.timestamp < timestamp - windowDuration }
        previousTimestamp = timestamp
        previousUnderrunFrames = audioUnderrunFrames
        previousOverflowFrames = audioOverflowFrames
    }

    mutating func resetBaseline() {
        ticks.removeAll(keepingCapacity: true)
        previousTimestamp = nil
        previousUnderrunFrames = nil
        previousOverflowFrames = nil
    }

    func summary(framesPerSecond: Double, sampleRate: Double) -> Summary {
        guard !ticks.isEmpty else {
            return Summary(
                speedPercent: 0,
                averageRunMilliseconds: 0,
                maximumRunMilliseconds: 0,
                averagePresentMilliseconds: 0,
                lateTicks: 0,
                audioUnderrunMilliseconds: 0,
                audioOverflowMilliseconds: 0,
                bufferedAudioMilliseconds: 0)
        }

        let runTotal = ticks.reduce(0) { $0 + $1.runSeconds }
        let presentTotal = ticks.reduce(0) { $0 + $1.presentSeconds }
        let targetInterval = framesPerSecond > 0 ? 1 / framesPerSecond : 0
        let elapsed = max(targetInterval, ticks[ticks.count - 1].timestamp - ticks[0].timestamp + targetInterval)
        let windowSeconds = min(windowDuration, elapsed)
        let speed = framesPerSecond > 0 && windowSeconds > 0
            ? Double(ticks.count) / (windowSeconds * framesPerSecond) * 100
            : 0
        let underrunFrames = ticks.reduce(UInt64(0)) { $0 &+ $1.underrunDelta }
        let overflowFrames = ticks.reduce(UInt64(0)) { $0 &+ $1.overflowDelta }
        let audioMillisecondsPerFrame = sampleRate > 0 ? 1000 / sampleRate : 0

        return Summary(
            speedPercent: speed,
            averageRunMilliseconds: runTotal * 1000 / Double(ticks.count),
            maximumRunMilliseconds: (ticks.map(\.runSeconds).max() ?? 0) * 1000,
            averagePresentMilliseconds: presentTotal * 1000 / Double(ticks.count),
            lateTicks: ticks.filter(\.wasLate).count,
            audioUnderrunMilliseconds: Double(underrunFrames) * audioMillisecondsPerFrame,
            audioOverflowMilliseconds: Double(overflowFrames) * audioMillisecondsPerFrame,
            bufferedAudioMilliseconds: Double(ticks[ticks.count - 1].bufferedFrames) * audioMillisecondsPerFrame)
    }
}
