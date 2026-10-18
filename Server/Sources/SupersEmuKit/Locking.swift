import Foundation

/// A value guarded by a lock, for state shared with callbacks that can't be async.
public final class LockedValue<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value

    public init(_ value: Value) { stored = value }

    public var value: Value {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }

    /// Reads or mutates the value while holding the lock.
    @discardableResult
    public func withLock<Result>(_ body: (inout Value) throws -> Result) rethrows -> Result {
        try lock.withLock { try body(&stored) }
    }
}

/// Resumes a continuation at most once, whichever callback gets there first. Later calls are ignored.
/// A resume before any continuation is installed is a no-op. Installing twice is a programming error.
public final class OnceContinuation<Value, Failure: Error>: @unchecked Sendable {
    private enum State {
        case idle
        case pending(CheckedContinuation<Value, Failure>)
        case finished
    }

    private let state = LockedValue(State.idle)

    public init() {}

    public init(_ continuation: CheckedContinuation<Value, Failure>) {
        install(continuation)
    }

    public func install(_ continuation: CheckedContinuation<Value, Failure>) {
        state.withLock { state in
            guard case .idle = state else { preconditionFailure("OnceContinuation installed more than once") }
            state = .pending(continuation)
        }
    }

    /// Returns true if this call resumed the continuation.
    @discardableResult
    public func resume(with result: Result<Value, Failure>) -> Bool {
        let pending = state.withLock { state -> CheckedContinuation<Value, Failure>? in
            guard case .pending(let continuation) = state else { return nil }
            state = .finished
            return continuation
        }
        pending?.resume(with: result)
        return pending != nil
    }

    @discardableResult
    public func resume(returning value: Value) -> Bool { resume(with: .success(value)) }

    @discardableResult
    public func resume(throwing error: Failure) -> Bool { resume(with: .failure(error)) }
}
