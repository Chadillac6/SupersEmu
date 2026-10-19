import Foundation
import SupersEmuKit

/// A clock that only moves when a test calls `advance(by:)`, so timing tests don't depend on how fast the machine schedules tasks.
final class ManualClock: Clock, Sendable {
    struct Instant: InstantProtocol {
        var offset: Duration

        func advanced(by duration: Duration) -> Instant { Instant(offset: offset + duration) }
        func duration(to other: Instant) -> Duration { other.offset - offset }
        static func < (lhs: Instant, rhs: Instant) -> Bool { lhs.offset < rhs.offset }
    }

    private struct Sleeper {
        let deadline: Instant
        let wake: OnceContinuation<Void, Error>
    }

    private struct State {
        var now = Instant(offset: .zero)
        var sleepers: [UUID: Sleeper] = [:]
        var sleeperWaiters: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []
    }

    private let state = LockedValue(State())

    var now: Instant { state.value.now }
    var minimumResolution: Duration { .zero }
    var pendingSleepers: Int { state.value.sleepers.count }

    func sleep(until deadline: Instant, tolerance: Duration? = nil) async throws {
        let id = UUID()
        let wake = OnceContinuation<Void, Error>()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                wake.install(continuation)
                let (due, ready) = state.withLock { state -> (Bool, [CheckedContinuation<Void, Never>]) in
                    guard state.now < deadline else { return (true, []) }
                    state.sleepers[id] = Sleeper(deadline: deadline, wake: wake)
                    let count = state.sleepers.count
                    let ready = state.sleeperWaiters.filter { $0.count <= count }.map(\.continuation)
                    state.sleeperWaiters.removeAll { $0.count <= count }
                    return (false, ready)
                }
                ready.forEach { $0.resume() }
                if due {
                    wake.resume(returning: ())
                } else if Task.isCancelled {
                    cancel(id, wake)
                }
            }
        } onCancel: {
            cancel(id, wake)
        }
    }

    func advance(by duration: Duration) {
        let due = state.withLock { state -> [Sleeper] in
            state.now = state.now.advanced(by: duration)
            let now = state.now
            let due = state.sleepers.filter { $0.value.deadline <= now }
            due.keys.forEach { state.sleepers[$0] = nil }
            return Array(due.values)
        }
        due.forEach { $0.wake.resume(returning: ()) }
    }

    /// Returns once at least `count` tasks are suspended in `sleep(until:)`.
    func waitForSleepers(_ count: Int) async {
        await withCheckedContinuation { continuation in
            let ready = state.withLock { state -> Bool in
                guard state.sleepers.count < count else { return true }
                state.sleeperWaiters.append((count, continuation))
                return false
            }
            if ready { continuation.resume() }
        }
    }

    private func cancel(_ id: UUID, _ wake: OnceContinuation<Void, Error>) {
        state.withLock { $0.sleepers[id] = nil }
        wake.resume(throwing: CancellationError())
    }
}
