import Foundation
import Testing
@testable import FramePipelineKit

@Suite struct BoundedDoubleTests {

    // MARK: - contains

    @Test func containsRejectsBelowMin() {
        // The lived bug: camera returned 0 µs but its declared min was 10 µs.
        let range = BoundedDouble(min: 10, max: 10_000_000)
        #expect(range.contains(0) == false)
    }

    @Test func containsAcceptsMin() {
        let range = BoundedDouble(min: 10, max: 100)
        #expect(range.contains(10) == true)
    }

    @Test func containsAcceptsMax() {
        let range = BoundedDouble(min: 10, max: 100)
        #expect(range.contains(100) == true)
    }

    @Test func containsRejectsAboveMax() {
        let range = BoundedDouble(min: 10, max: 100)
        #expect(range.contains(101) == false)
    }

    @Test func containsAcceptsMidpoint() {
        let range = BoundedDouble(min: 10, max: 10_000_000)
        #expect(range.contains(10_000) == true)
    }

    // MARK: - clamping

    @Test func clampingLiftsBelowMin() {
        let range = BoundedDouble(min: 10, max: 10_000_000)
        #expect(range.clamping(0) == 10)
        #expect(range.clamping(-100) == 10)
    }

    @Test func clampingCapsAboveMax() {
        let range = BoundedDouble(min: 10, max: 100)
        #expect(range.clamping(200) == 100)
    }

    @Test func clampingPreservesInRange() {
        let range = BoundedDouble(min: 10, max: 100)
        #expect(range.clamping(50) == 50)
        #expect(range.clamping(10) == 10)
        #expect(range.clamping(100) == 100)
    }

    // MARK: - Bug repro

    @Test func bugRepro_zeroExposureFromCameraIsRejected() {
        // The MR-CAM-HR scenario: capabilities reported exposure range
        // [10, 10_000_000] µs, but a get-exposure read returned 0. Without
        // this guard the app overwrote its UI state with 0, wrote 0 back
        // to the camera, and the camera turned off its control surface.
        let cameraDeclaredRange = BoundedDouble(min: 10, max: 10_000_000)
        let cameraReportedCurrentValue: Double = 0
        #expect(cameraDeclaredRange.contains(cameraReportedCurrentValue) == false,
                "value below declared min must be rejected before propagating to UI state")
    }

    @Test func bugRepro_unclampedWriteIsCorrectedAtBoundary() {
        // Defense-in-depth: even if a bad value reaches updateExposureTime,
        // the clamp before writing to the bridge ensures the camera only
        // ever sees in-range values.
        let cameraDeclaredRange = BoundedDouble(min: 10, max: 10_000_000)
        #expect(cameraDeclaredRange.clamping(0) == 10)
    }
}
