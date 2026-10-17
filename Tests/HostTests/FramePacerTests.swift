import XCTest

final class FramePacerTests: XCTestCase {
    func testNominalPacingRunsOneFramePerDeadline() {
        var pacer = FramePacer(framesPerSecond: 60)
        pacer.reset(now: 1)

        var now = 1.0
        for _ in 0..<60 {
            let step = pacer.step(now: now, rate: 1)
            XCTAssertEqual(step.framesToRun, 1)
            now = step.wakeAt
        }
        XCTAssertEqual(pacer.catchUpFrames, 0)
        XCTAssertEqual(pacer.droppedFrames, 0)
    }

    func testFortyMillisecondDelayCatchesUp() {
        var pacer = FramePacer(framesPerSecond: 60)
        pacer.reset(now: 0)

        let step = pacer.step(now: 0.04, rate: 1)

        XCTAssertEqual(step.framesToRun, 3)
        XCTAssertEqual(step.wakeAt, 0.05, accuracy: 0.000_001)
        XCTAssertEqual(pacer.catchUpFrames, 2)
        XCTAssertEqual(pacer.droppedFrames, 0)
    }

    func testLargeDelayCapsCatchUpAndDropsBacklog() {
        var pacer = FramePacer(framesPerSecond: 60)
        pacer.reset(now: 0)

        let step = pacer.step(now: 0.5, rate: 1)
        let due = Int(floor(0.5 / (1.0 / 60))) + 1

        XCTAssertEqual(step.framesToRun, 3)
        XCTAssertEqual(pacer.droppedFrames, due - 3)
        XCTAssertLessThan(step.wakeAt, 0.6)
    }

    func testRateChangesDeadlineInterval() {
        var pacer = FramePacer(framesPerSecond: 60)
        pacer.reset(now: 0)

        let first = pacer.step(now: 0, rate: 1.005)

        XCTAssertEqual(first.wakeAt, 1 / (60 * 1.005), accuracy: 0.000_001)
    }

    func testCatchUpIsCapped() {
        var pacer = FramePacer(framesPerSecond: 60, maxCatchUpFrames: 2)
        pacer.reset(now: 0)

        XCTAssertEqual(pacer.step(now: 0.2, rate: 1).framesToRun, 2)
    }

    func testResetClearsBacklogAndCounters() {
        var pacer = FramePacer(framesPerSecond: 60)
        pacer.reset(now: 0)
        _ = pacer.step(now: 0.5, rate: 1)
        pacer.reset(now: 10)

        XCTAssertEqual(pacer.catchUpFrames, 0)
        XCTAssertEqual(pacer.droppedFrames, 0)
        XCTAssertEqual(pacer.step(now: 10, rate: 1).framesToRun, 1)
    }
}
