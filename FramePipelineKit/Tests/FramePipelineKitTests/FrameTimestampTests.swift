import Testing
@testable import FramePipelineKit

@Suite struct FrameTimestampTests {
    @Test func storesAllFields() {
        let ts = FrameTimestamp(frameID: 7, cameraTimestampNs: 100, hostTimestampNs: 200)
        #expect(ts.frameID == 7)
        #expect(ts.cameraTimestampNs == 100)
        #expect(ts.hostTimestampNs == 200)
    }

    @Test func consecutiveFramesHaveNoGap() {
        let a = FrameTimestamp(frameID: 4, cameraTimestampNs: 0, hostTimestampNs: 0)
        let b = FrameTimestamp(frameID: 5, cameraTimestampNs: 0, hostTimestampNs: 0)
        #expect(b.droppedFrames(since: a) == 0)
    }

    @Test func gapCountsMissingFrames() {
        let a = FrameTimestamp(frameID: 4, cameraTimestampNs: 0, hostTimestampNs: 0)
        let b = FrameTimestamp(frameID: 7, cameraTimestampNs: 0, hostTimestampNs: 0)
        #expect(b.droppedFrames(since: a) == 2) // 5 and 6 missing
    }

    @Test func nonIncreasingIdReportsZero() {
        let a = FrameTimestamp(frameID: 7, cameraTimestampNs: 0, hostTimestampNs: 0)
        let b = FrameTimestamp(frameID: 7, cameraTimestampNs: 0, hostTimestampNs: 0)
        #expect(b.droppedFrames(since: a) == 0)
    }
}
