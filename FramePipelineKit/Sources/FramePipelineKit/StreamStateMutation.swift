import Foundation

/// Pure logic for mutating the shared `StreamState` dict that the
/// GigEVirtualCameraExtension writes and the GigECameraApp observes.
///
/// The extension's `StreamStateCoordinator` implements the same algorithm
/// inline (it can't link this package), so any change here must be mirrored
/// there. These functions exist primarily so the merge behavior is unit-
/// testable — the lived bug was that `signalNeedFrames` replaced the entire
/// dict and clobbered `newClientConnected`, which was the only flag the app
/// used to know it needed to restart its sink path after a disconnect.
public enum StreamStateMutation {

    /// The keys this module knows about. Any other keys present in the dict
    /// are preserved by the mutating functions below.
    public enum Key {
        public static let streamActive = "streamActive"
        public static let timestamp = "timestamp"
        public static let pid = "pid"
        public static let newClientConnected = "newClientConnected"
        public static let clientConnectedTime = "clientConnectedTime"
    }

    /// Merge the "extension wants frames" signal into the existing dict.
    /// Preserves every key the caller doesn't explicitly set — in particular
    /// `newClientConnected`, which may have been set milliseconds earlier by
    /// `source.startStream`.
    public static func merging(
        needFramesInto existing: [String: Any]?,
        nowEpochSeconds: TimeInterval,
        pid: Int32
    ) -> [String: Any] {
        var merged = existing ?? [:]
        merged[Key.streamActive] = true
        merged[Key.timestamp] = nowEpochSeconds
        merged[Key.pid] = pid
        return merged
    }

    /// Merge the "extension is done" signal. Sets `streamActive = false`
    /// instead of removing the dict; the previous behavior caused the app's
    /// observer to early-return on a missing dict (no observable transition).
    public static func merging(
        streamStoppedInto existing: [String: Any]?,
        nowEpochSeconds: TimeInterval
    ) -> [String: Any] {
        var merged = existing ?? [:]
        merged[Key.streamActive] = false
        merged[Key.timestamp] = nowEpochSeconds
        return merged
    }

    /// Merge the "a new consumer just attached" edge-triggered flag.
    /// Source-side `startStream` calls this before triggering the device-
    /// source notification chain; the flag must survive `signalNeedFrames`.
    public static func merging(
        newClientConnectedInto existing: [String: Any]?,
        connectedAtEpochSeconds: TimeInterval
    ) -> [String: Any] {
        var merged = existing ?? [:]
        merged[Key.newClientConnected] = true
        merged[Key.clientConnectedTime] = connectedAtEpochSeconds
        return merged
    }
}
