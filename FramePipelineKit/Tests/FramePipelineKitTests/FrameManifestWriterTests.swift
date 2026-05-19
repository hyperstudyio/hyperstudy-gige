import Testing
import Foundation
@testable import FramePipelineKit

@Suite struct FrameManifestWriterTests {
    private func tempURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("manifest-\(UUID().uuidString).csv")
    }

    @Test func writesHeaderAndRows() throws {
        let url = tempURL()
        let writer = try FrameManifestWriter(url: url)
        writer.record(FrameTimestamp(frameID: 1, cameraTimestampNs: 10, hostTimestampNs: 20),
                      status: .delivered)
        writer.record(FrameTimestamp(frameID: 2, cameraTimestampNs: 30, hostTimestampNs: 40),
                      status: .droppedBuffer)
        writer.close()

        let contents = try String(contentsOf: url, encoding: .utf8)
        let lines = contents.split(separator: "\n", omittingEmptySubsequences: true)
        #expect(lines[0] == "frame_id,camera_timestamp_ns,host_timestamp_ns,status")
        #expect(lines[1] == "1,10,20,delivered")
        #expect(lines[2] == "2,30,40,dropped_buffer")
        try? FileManager.default.removeItem(at: url)
    }

    @Test func queueDropStatusSerializesCorrectly() throws {
        let url = tempURL()
        let writer = try FrameManifestWriter(url: url)
        writer.record(FrameTimestamp(frameID: 9, cameraTimestampNs: 0, hostTimestampNs: 0),
                      status: .droppedQueue)
        writer.close()
        let contents = try String(contentsOf: url, encoding: .utf8)
        #expect(contents.contains("9,0,0,dropped_queue"))
        try? FileManager.default.removeItem(at: url)
    }
}
