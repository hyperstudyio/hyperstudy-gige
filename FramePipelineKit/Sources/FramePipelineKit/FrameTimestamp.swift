/// Capture-time identity for a single frame, captured as early as possible
/// in the acquisition path so downstream timing never inherits queue jitter.
///
/// - `frameID`: monotonic per-camera frame counter (Aravis frame id). Gaps in
///   this sequence are exactly the dropped/missing frames.
/// - `cameraTimestampNs`: device-clock timestamp (for cross-device research sync).
/// - `hostTimestampNs`: host monotonic clock at capture (CLOCK_UPTIME_RAW), used
///   to build the CMSampleBuffer presentation timestamp in the host time domain.
public struct FrameTimestamp: Equatable, Sendable {
    public let frameID: UInt64
    public let cameraTimestampNs: UInt64
    public let hostTimestampNs: UInt64

    public init(frameID: UInt64, cameraTimestampNs: UInt64, hostTimestampNs: UInt64) {
        self.frameID = frameID
        self.cameraTimestampNs = cameraTimestampNs
        self.hostTimestampNs = hostTimestampNs
    }

    /// Number of frames missing between `previous` and `self` based on frame id.
    /// Returns 0 when ids are consecutive or non-increasing.
    public func droppedFrames(since previous: FrameTimestamp) -> UInt64 {
        guard frameID > previous.frameID else { return 0 }
        return frameID - previous.frameID - 1
    }
}
