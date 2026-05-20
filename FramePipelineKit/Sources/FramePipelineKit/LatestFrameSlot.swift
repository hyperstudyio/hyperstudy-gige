import Foundation

/// Thread-safe single-value slot with drop-to-latest semantics.
/// Setting a new value while one is pending discards the old one (counted as a
/// drop). Correct for a live preview, where only the newest frame matters.
public final class LatestFrameSlot<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value?
    private var _droppedCount = 0

    public init() {}

    public var droppedCount: Int {
        lock.lock(); defer { lock.unlock() }
        return _droppedCount
    }

    /// Store `newValue`. Returns the displaced value, if any.
    @discardableResult
    public func set(_ newValue: Value) -> Value? {
        lock.lock(); defer { lock.unlock() }
        let displaced = value
        if displaced != nil { _droppedCount += 1 }
        value = newValue
        return displaced
    }

    /// Remove and return the current value, leaving the slot empty.
    public func take() -> Value? {
        lock.lock(); defer { lock.unlock() }
        let current = value
        value = nil
        return current
    }
}
