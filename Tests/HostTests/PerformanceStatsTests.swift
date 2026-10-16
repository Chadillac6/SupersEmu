import XCTest

final class PerformanceStatsTests: XCTestCase {
    func testSpeedLateTicksAndAudioUnderrunMath() {
        var stats = PerformanceStats(windowDuration: 5)
        for frame in 1...60 {
            let timestamp = Double(frame) / 60
            stats.record(
                runDuration: 0.01,
                presentDuration: 0.002,
                timestamp: timestamp,
                framesPerSecond: 60,
                sampleRate: 48_000,
                audioUnderrunFrames: UInt64(frame * 2),
                audioOverflowFrames: 0,
                bufferedAudioFrames: 960)
        }

        let summary = stats.summary(framesPerSecond: 60, sampleRate: 48_000)
        XCTAssertEqual(summary.speedPercent, 100, accuracy: 0.001)
        XCTAssertEqual(summary.averageRunMilliseconds, 10, accuracy: 0.001)
        XCTAssertEqual(summary.maximumRunMilliseconds, 10, accuracy: 0.001)
        XCTAssertEqual(summary.averagePresentMilliseconds, 2, accuracy: 0.001)
        XCTAssertEqual(summary.lateTicks, 0)
        XCTAssertEqual(summary.audioUnderrunMilliseconds, Double(118) * 1000 / 48_000, accuracy: 0.001)
        XCTAssertEqual(summary.bufferedAudioMilliseconds, 20, accuracy: 0.001)

        stats.record(
            runDuration: 0.02,
            presentDuration: 0.003,
            timestamp: 1.1,
            framesPerSecond: 60,
            sampleRate: 48_000,
            audioUnderrunFrames: 240,
            audioOverflowFrames: 0,
            bufferedAudioFrames: 0)
        XCTAssertEqual(stats.summary(framesPerSecond: 60, sampleRate: 48_000).lateTicks, 1)
    }

    func testResetBaselineExcludesAudioAndTimeAccumulatedWhilePaused() {
        var stats = PerformanceStats()
        stats.record(
            runDuration: 0.01,
            presentDuration: 0.002,
            timestamp: 1,
            framesPerSecond: 60,
            sampleRate: 48_000,
            audioUnderrunFrames: 10,
            audioOverflowFrames: 3,
            bufferedAudioFrames: 100)
        stats.resetBaseline()
        stats.record(
            runDuration: 0.01,
            presentDuration: 0.002,
            timestamp: 100,
            framesPerSecond: 60,
            sampleRate: 48_000,
            audioUnderrunFrames: 10_000,
            audioOverflowFrames: 2_000,
            bufferedAudioFrames: 100)

        let summary = stats.summary(framesPerSecond: 60, sampleRate: 48_000)
        XCTAssertEqual(summary.speedPercent, 100, accuracy: 0.001)
        XCTAssertEqual(summary.audioUnderrunMilliseconds, 0)
        XCTAssertEqual(summary.audioOverflowMilliseconds, 0)
        XCTAssertEqual(summary.lateTicks, 0)
    }
}
