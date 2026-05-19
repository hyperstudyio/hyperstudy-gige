import Foundation

/// Append-only CSV writer recording the fate of every frame, keyed by the
/// monotonic Aravis frame id. This is the ground truth for research sync: the
/// recorded video may re-encode/lose precise timestamps, but this manifest
/// records exactly which frames were delivered or dropped and their capture-time
/// stamps. Gaps in `frame_id` plus explicit drop rows make missing frames
/// observable instead of silent.
public final class FrameManifestWriter {
    public enum Status: String {
        case delivered
        case droppedBuffer = "dropped_buffer" // discarded by the bounded ring (consumer behind)
        case droppedQueue = "dropped_queue"   // CMIO sink queue rejected it (recorder behind)
    }

    public static let header = "frame_id,camera_timestamp_ns,host_timestamp_ns,status"

    private let handle: FileHandle
    private let lock = NSLock()

    public init(url: URL) throws {
        FileManager.default.createFile(atPath: url.path, contents: nil)
        self.handle = try FileHandle(forWritingTo: url)
        write(Self.header + "\n")
    }

    public func record(_ ts: FrameTimestamp, status: Status) {
        write("\(ts.frameID),\(ts.cameraTimestampNs),\(ts.hostTimestampNs),\(status.rawValue)\n")
    }

    public func close() {
        lock.lock(); defer { lock.unlock() }
        try? handle.close()
    }

    private func write(_ line: String) {
        guard let data = line.data(using: .utf8) else { return }
        lock.lock(); defer { lock.unlock() }
        handle.write(data)
    }
}
