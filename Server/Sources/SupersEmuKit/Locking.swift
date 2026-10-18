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
public final class OnceContinuation<Value, Failure: Error>: @unchecked Sendable {
    private let continuation = LockedValue<CheckedContinuation<Value, Failure>?>(nil)

    public init() {}

    public init(_ continuation: CheckedContinuation<Value, Failure>) {
        self.continuation.value = continuation
    }

    public func install(_ continuation: CheckedContinuation<Value, Failure>) {
        self.continuation.value = continuation
    }

    /// Returns true if this call resumed the continuation.
    @discardableResult
    public func resume(with result: Result<Value, Failure>) -> Bool {
        let pending = continuation.withLock { stored -> CheckedContinuation<Value, Failure>? in
            defer { stored = nil }
            return stored
        }
        pending?.resume(with: result)
        return pending != nil
    }

    @discardableResult
    public func resume(returning value: Value) -> Bool { resume(with: .success(value)) }

    @discardableResult
    public func resume(throwing error: Failure) -> Bool { resume(with: .failure(error)) }
}
