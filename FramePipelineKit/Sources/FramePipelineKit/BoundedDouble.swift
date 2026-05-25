import Foundation

/// Validates and clamps `Double` values against a declared `[min, max]` range.
///
/// Used by the app to guard camera-control writes (exposure, gain, frame rate)
/// against bad reads from Aravis. The lived bug: after a reconnect cycle, the
/// MR-CAM-HR returned 0 from `arv_camera_get_exposure_time` even though it
/// reported a valid range of 10–10,000,000 µs. The app propagated the 0 into
/// its `@Published var exposureTime`, the didSet then wrote 0 back to the
/// camera, and the camera entered a "controls not available" state. Both
/// `contains(_:)` and `clamping(_:)` exist primarily so this filter has
/// unit-testable behavior — the lived code mirrors the same algorithm inline.
public struct BoundedDouble {
    public let min: Double
    public let max: Double

    public init(min: Double, max: Double) {
        self.min = min
        self.max = max
    }

    /// True if `value` is within `[min, max]` (inclusive). Used at the point
    /// where we *read* a value from the camera — out-of-range reads should
    /// be rejected, not propagated into UI state.
    public func contains(_ value: Double) -> Bool {
        return value >= min && value <= max
    }

    /// Clamps `value` to the declared range. Used at the point where we
    /// *write* a value to the camera — even if upstream code somehow lets
    /// an out-of-range value through, the bridge sees only valid inputs.
    public func clamping(_ value: Double) -> Double {
        if value < min { return min }
        if value > max { return max }
        return value
    }
}
