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

    @Test func concurrentRecordThenCloseProducesValidFile() async throws {
        let url = tempURL()
        let writer = try FrameManifestWriter(url: url)
        let recordCount = 200
        await withTaskGroup(of: Void.self) { group in
            for i in 0 ..< recordCount {
                group.addTask {
                    writer.record(
                        FrameTimestamp(frameID: UInt64(i), cameraTimestampNs: 0, hostTimestampNs: 0),
                        status: .delivered
                    )
                }
            }
        }
        writer.close()
        // Calling close() a second time after already closed must be a no-op (no crash).
        writer.close()

        let contents = try String(contentsOf: url, encoding: .utf8)
        let lines = contents.split(separator: "\n", omittingEmptySubsequences: true)
        // First line is always the header.
        #expect(lines.first == "frame_id,camera_timestamp_ns,host_timestamp_ns,status")
        // All records that raced before close() must have landed; count includes header.
        // Under concurrent execution every record should complete before close(), so we
        // expect header + recordCount data rows.
        #expect(lines.count == recordCount + 1)
        try? FileManager.default.removeItem(at: url)
    }

    @Test func closeIsIdempotent() throws {
        let url = tempURL()
        let writer = try FrameManifestWriter(url: url)
        writer.close()
        // A second close must not crash or throw.
        writer.close()
        try? FileManager.default.removeItem(at: url)
    }
}
