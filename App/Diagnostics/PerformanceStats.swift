import Foundation

final class PerformanceStats: @unchecked Sendable {
    struct Summary: Equatable {
        let speedPercent: Double
        let averageRunMilliseconds: Double
        let maximumRunMilliseconds: Double
        let averagePresentMilliseconds: Double
        let lateTicks: Int
        let audioUnderrunMilliseconds: Double
        let audioOverflowMilliseconds: Double
        let bufferedAudioMilliseconds: Double
        let catchUpFrames: Int
        let droppedFrames: Int
        let rate: Double
        let audioRunning: Bool

        func performanceLine(thermalState: String) -> String {
            String(
                format: "perf speed=%.0f%% run=%.1f/%.1fms present=%.1fms late=%d underrun=%.0fms overflow=%.0fms buffered=%.0fms thermal=%@ catchup=%d drops=%d rate=%.3f audio=%@",
                locale: Locale(identifier: "en_US_POSIX"),
                speedPercent,
                averageRunMilliseconds,
                maximumRunMilliseconds,
                averagePresentMilliseconds,
                lateTicks,
                audioUnderrunMilliseconds,
                audioOverflowMilliseconds,
                bufferedAudioMilliseconds,
                thermalState,
                catchUpFrames,
                droppedFrames,
                rate,
                audioRunning ? "running" : "stopped")
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
        let catchUpFrames: Int
        let droppedFrames: Int
        let rate: Double
        let audioRunning: Bool
    }

    private let lock = NSLock()
    private let windowDuration: TimeInterval
    private var ticks: [Tick] = []
    private var baselineTimestamp: TimeInterval?
    private var previousTimestamp: TimeInterval?
    private var previousUnderrunFrames: UInt64?
    private var previousOverflowFrames: UInt64?

    init(windowDuration: TimeInterval = 5) {
        self.windowDuration = max(windowDuration, 0.01)
    }

    func record(
        runDuration: TimeInterval,
        presentDuration: TimeInterval,
        timestamp: TimeInterval,
        framesPerSecond: Double,
        sampleRate: Double,
        audioUnderrunFrames: UInt64,
        audioOverflowFrames: UInt64,
        bufferedAudioFrames: Int,
        catchUpFrames: Int = 0,
        droppedFrames: Int = 0,
        rate: Double = 1,
        audioRunning: Bool = false
    ) {
        lock.lock(); defer { lock.unlock() }
        let targetInterval = framesPerSecond > 0 ? 1 / framesPerSecond : 0
        if baselineTimestamp == nil {
            baselineTimestamp = timestamp
        }
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
            bufferedFrames: max(bufferedAudioFrames, 0),
            catchUpFrames: catchUpFrames,
            droppedFrames: droppedFrames,
            rate: rate,
            audioRunning: audioRunning))
        ticks.removeAll { $0.timestamp < timestamp - windowDuration }
        previousTimestamp = timestamp
        previousUnderrunFrames = audioUnderrunFrames
        previousOverflowFrames = audioOverflowFrames
    }

    func resetBaseline() {
        lock.lock(); defer { lock.unlock() }
        ticks.removeAll(keepingCapacity: true)
        baselineTimestamp = nil
        previousTimestamp = nil
        previousUnderrunFrames = nil
        previousOverflowFrames = nil
    }

    func summary(framesPerSecond: Double, sampleRate: Double) -> Summary {
        lock.lock(); defer { lock.unlock() }
        guard !ticks.isEmpty else {
            return Summary(
                speedPercent: 0,
                averageRunMilliseconds: 0,
                maximumRunMilliseconds: 0,
                averagePresentMilliseconds: 0,
                lateTicks: 0,
                audioUnderrunMilliseconds: 0,
                audioOverflowMilliseconds: 0,
                bufferedAudioMilliseconds: 0,
                catchUpFrames: 0,
                droppedFrames: 0,
                rate: 1,
                audioRunning: false)
        }

        let runTotal = ticks.reduce(0) { $0 + $1.runSeconds }
        let presentTotal = ticks.reduce(0) { $0 + $1.presentSeconds }
        let targetInterval = framesPerSecond > 0 ? 1 / framesPerSecond : 0
        let first = ticks[0]
        let last = ticks[ticks.count - 1]
        let elapsed = max(
            targetInterval,
            last.timestamp - max(baselineTimestamp ?? first.timestamp, last.timestamp - windowDuration) + targetInterval)
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
            bufferedAudioMilliseconds: Double(ticks[ticks.count - 1].bufferedFrames) * audioMillisecondsPerFrame,
            catchUpFrames: ticks.last?.catchUpFrames ?? 0,
            droppedFrames: ticks.last?.droppedFrames ?? 0,
            rate: ticks.last?.rate ?? 1,
            audioRunning: ticks.last?.audioRunning ?? false)
    }
}
