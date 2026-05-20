import Foundation

/// Thread-safe bounded FIFO. When full, `push` discards the oldest element to
/// keep latency bounded toward "live", and returns it so the caller can log the
/// drop. Correct for a stream that must not accumulate latency but should buffer
/// transient spikes rather than dropping on every hiccup.
public final class BoundedFrameRing<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [Value] = []
    private var _totalDropped = 0
    public let capacity: Int

    public init(capacity: Int) {
        precondition(capacity > 0, "capacity must be > 0")
        self.capacity = capacity
        storage.reserveCapacity(capacity)
    }

    /// Append `value`. If at capacity, drop and return the oldest element.
    @discardableResult
    public func push(_ value: Value) -> Value? {
        lock.lock(); defer { lock.unlock() }
        var dropped: Value?
        if storage.count >= capacity {
            dropped = storage.removeFirst()
            _totalDropped += 1
        }
        storage.append(value)
        return dropped
    }

    public func pop() -> Value? {
        lock.lock(); defer { lock.unlock() }
        return storage.isEmpty ? nil : storage.removeFirst()
    }

    public var count: Int {
        lock.lock(); defer { lock.unlock() }
        return storage.count
    }

    public var totalDropped: Int {
        lock.lock(); defer { lock.unlock() }
        return _totalDropped
    }
}
