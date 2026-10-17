import Foundation

struct FramePacer {
    private let framesPerSecond: Double
    private let maxCatchUpFrames: Int
    private var nextDeadline: TimeInterval?
    private(set) var droppedFrames = 0
    private(set) var catchUpFrames = 0

    init(framesPerSecond: Double, maxCatchUpFrames: Int = 3) {
        self.framesPerSecond = max(framesPerSecond, 0.001)
        self.maxCatchUpFrames = max(maxCatchUpFrames, 1)
    }

    mutating func reset(now: TimeInterval) {
        nextDeadline = now
        droppedFrames = 0
        catchUpFrames = 0
    }

    mutating func step(now: TimeInterval, rate: Double) -> (framesToRun: Int, wakeAt: TimeInterval) {
        let interval = 1 / (framesPerSecond * max(rate, 0.0001))
        guard let deadline = nextDeadline else {
            nextDeadline = now + interval
            return (1, now + interval)
        }
        guard now >= deadline else { return (0, deadline) }

        let due = max(Int(floor((now - deadline) / interval)) + 1, 1)
        let run = min(due, maxCatchUpFrames)
        var updatedDeadline = deadline + Double(run) * interval
        catchUpFrames += max(run - 1, 0)
        if now - updatedDeadline > Double(maxCatchUpFrames) * interval {
            updatedDeadline = now + interval
            droppedFrames += due - run
        }
        nextDeadline = updatedDeadline
        return (run, updatedDeadline)
    }
}
