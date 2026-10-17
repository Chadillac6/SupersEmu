import XCTest

final class AudioRateControlTests: XCTestCase {
    func testHalfFullBufferTargetsNormalRate() {
        XCTAssertEqual(AudioRateControl.rate(bufferedFrames: 500, capacityFrames: 1_000), 1)
    }

    func testEmptyBufferSpeedsUp() {
        XCTAssertEqual(AudioRateControl.rate(bufferedFrames: 0, capacityFrames: 1_000), 1.005)
    }

    func testFullBufferSlowsDown() {
        XCTAssertEqual(AudioRateControl.rate(bufferedFrames: 1_000, capacityFrames: 1_000), 0.995)
    }

    func testRateClampsToConfiguredDeviation() {
        XCTAssertEqual(AudioRateControl.rate(bufferedFrames: -1_000, capacityFrames: 1_000, maxDeviation: 0.002), 1.002)
        XCTAssertEqual(AudioRateControl.rate(bufferedFrames: 5_000, capacityFrames: 1_000, maxDeviation: 0.002), 0.998)
    }

    func testZeroCapacityUsesNormalRate() {
        XCTAssertEqual(AudioRateControl.rate(bufferedFrames: 100, capacityFrames: 0), 1)
    }

    func testStoppedEngineUsesNormalRateEvenWithFullBuffer() {
        XCTAssertEqual(AudioRateControl.rate(bufferedFrames: 1_000, capacityFrames: 1_000, engineRunning: false), 1)
    }
}
