import XCTest

final class EmulationLoopTests: XCTestCase {
    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0
        func increment() { lock.lock(); value += 1; lock.unlock() }
        func incrementAndRead() -> Int { lock.lock(); value += 1; defer { lock.unlock() }; return value }
        func read() -> Int { lock.lock(); defer { lock.unlock() }; return value }
    }

    private final class Activity: @unchecked Sendable {
        private let lock = NSLock()
        private var active = 0
        private var maximum = 0
        func begin() {
            lock.lock()
            active += 1
            maximum = max(maximum, active)
            lock.unlock()
        }
        func end() { lock.lock(); active -= 1; lock.unlock() }
        func currentActive() -> Int { lock.lock(); defer { lock.unlock() }; return active }
        func maximumActive() -> Int { lock.lock(); defer { lock.unlock() }; return maximum }
    }

    func testRunsAtApproximateRequestedRate() {
        let counter = Counter()
        let loop = EmulationLoop(framesPerSecond: 60, runFrame: { _ in counter.increment() })
        defer { loop.stop() }

        loop.start(running: true)
        Thread.sleep(forTimeInterval: 0.5)
        loop.setRunning(false)

        XCTAssertEqual(counter.read(), 30, accuracy: 5)
    }

    func testPerformRunsOnSerializedEmulationThread() throws {
        let counter = Counter()
        let activity = Activity()
        let frameStarted = DispatchSemaphore(value: 0)
        let loop = EmulationLoop(framesPerSecond: 60, runFrame: { _ in
            activity.begin()
            frameStarted.signal()
            counter.increment()
            Thread.sleep(forTimeInterval: 0.01)
            activity.end()
        })
        defer { loop.stop() }
        loop.start(running: true)
        XCTAssertEqual(frameStarted.wait(timeout: .now() + 1), .success)

        let threadName = try loop.perform { _ in Thread.current.name }
        let activeDuringPerform = try loop.perform { _ in activity.currentActive() }
        loop.setRunning(false)

        XCTAssertEqual(threadName, "SupersEmu.emulation")
        XCTAssertEqual(activeDuringPerform, 0)
        XCTAssertGreaterThan(counter.read(), 0)
    }

    func testPauseWaitsForInFlightFrameBatch() {
        let frameStarted = DispatchSemaphore(value: 0)
        let releaseFrame = DispatchSemaphore(value: 0)
        let paused = DispatchSemaphore(value: 0)
        let loop = EmulationLoop(framesPerSecond: 60, runFrame: { _ in
            frameStarted.signal()
            releaseFrame.wait()
        })
        defer {
            releaseFrame.signal()
            loop.stop()
        }
        loop.start(running: true)
        XCTAssertEqual(frameStarted.wait(timeout: .now() + 1), .success)

        DispatchQueue.global().async {
            loop.setRunning(false)
            paused.signal()
        }
        XCTAssertEqual(paused.wait(timeout: .now() + 0.05), .timedOut)
        releaseFrame.signal()
        XCTAssertEqual(paused.wait(timeout: .now() + 1), .success)
    }

    func testSlowFramesAreRunSeriallyWithoutOverlapping() {
        let activity = Activity()
        let frames = Counter()
        let loop = EmulationLoop(framesPerSecond: 60, runFrame: { _ in
            activity.begin()
            let frame = frames.incrementAndRead()
            Thread.sleep(forTimeInterval: frame.isMultiple(of: 10) ? 0.025 : 0.001)
            activity.end()
        })
        defer { loop.stop() }
        loop.start(running: true)
        Thread.sleep(forTimeInterval: 0.5)
        loop.setRunning(false)

        XCTAssertEqual(frames.read(), 30, accuracy: 6)
        XCTAssertEqual(activity.maximumActive(), 1)
        XCTAssertGreaterThan(loop.pacingMetrics().catchUpFrames, 0)
    }

    func testTakingFrameImageDoesNotWaitForSlowFrame() {
        let frameStarted = DispatchSemaphore(value: 0)
        let loop = EmulationLoop(framesPerSecond: 10, runFrame: { _ in
            frameStarted.signal()
            Thread.sleep(forTimeInterval: 0.1)
        })
        defer { loop.stop() }
        loop.start(running: true)
        XCTAssertEqual(frameStarted.wait(timeout: .now() + 1), .success)

        let start = ProcessInfo.processInfo.systemUptime
        _ = loop.takeFrameImage()
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - start, 0.005)
    }

    func testAudioStallBackoffDoublesCapsAndResetsAfterProgress() {
        var backoff = AudioStallBackoff()
        XCTAssertEqual(backoff.attempt(at: 0), 1)
        XCTAssertNil(backoff.attempt(at: 4.9))
        XCTAssertEqual(backoff.attempt(at: 5), 2)
        XCTAssertEqual(backoff.attempt(at: 15), 3)
        XCTAssertEqual(backoff.attempt(at: 35), 4)
        XCTAssertEqual(backoff.attempt(at: 75), 5)
        XCTAssertNil(backoff.attempt(at: 134))
        XCTAssertEqual(backoff.attempt(at: 135), 6)

        backoff.reset()
        XCTAssertEqual(backoff.attempt(at: 200), 1)
    }
}
