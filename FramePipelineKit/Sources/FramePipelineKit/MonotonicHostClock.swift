import Foundation

/// Returns a strictly-increasing sequence of host-time values from a possibly
/// non-monotonic input.
///
/// Why this exists: the CMIO extension's source stream is fed from two paths
/// — the sink-to-source bridge (real frames, on the CMIO callback queue) and
/// a 2-second no-frame watchdog (default frames, on the main runloop). These
/// can race, and `CMIOExtensionStream.send(_:discontinuity:hostTimeInNanoseconds:)`
/// freezes consuming clients (QuickTime, Zoom, etc.) the instant it sees a
/// `hostTime` <= the previous one. Even when both producers read
/// `CLOCK_UPTIME_RAW`, two threads can sample the same nanosecond or sample
/// out of order if scheduling reorders the underlying `stream.send` calls.
///
/// Strategy: clamp every emit time to `max(now, last + 1ns)`. Same as the
/// app-side PTS guard in `CMIOFrameSender.createSampleBuffer`. We bump by 1ns
/// rather than dropping the frame so a brief reorder doesn't show as a gap to
/// the consumer; this is sound for video timing where ns-level jitter is
/// imperceptible.
public final class MonotonicHostClock {
    private let lock = NSLock()
    private var lastNs: UInt64 = 0
    private(set) public var nudgeCount: UInt64 = 0

    public init() {}

    /// Returns the next host-time to use, bumping forward if necessary.
    /// Thread-safe.
    public func next(now nowNs: UInt64) -> UInt64 {
        lock.lock()
        defer { lock.unlock() }
        if nowNs <= lastNs {
            lastNs = lastNs &+ 1
            nudgeCount &+= 1
        } else {
            lastNs = nowNs
        }
        return lastNs
    }

    /// Resets state. Use when a new client session starts so a stale `lastNs`
    /// from a previous session doesn't cause every frame to be nudged.
    public func reset() {
        lock.lock()
        defer { lock.unlock() }
        lastNs = 0
        nudgeCount = 0
    }
}
