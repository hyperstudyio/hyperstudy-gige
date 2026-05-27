//
//  SharedExtensionLog.swift
//
//  Cross-process diagnostic log via the app group container.
//
//  Why this exists: the diagnostics drawer is backed by
//  OSLogStore(scope: .currentProcessIdentifier), which only reads the calling
//  process's own log entries. The CMIO Camera Extension runs in a separate
//  process, so every `Logger().info` call inside the extension is invisible
//  to the drawer — and during a real bug (sink never attaches, no-frame
//  watchdog firing in a loop, etc.) those are the lines that matter most.
//
//  This file gives the extension a tiny additional sink: append a JSON line
//  per event to a shared file in the app group container. The app tails that
//  file and merges entries into the same in-memory buffer the drawer renders.
//  Existing Logger() calls are left untouched; they still go to the unified
//  system log via `os.log`. This is purely additive.
//
//  Format choices:
//   - JSONL (one self-contained JSON object per line). Survives partial
//     writes, parses incrementally, inspectable with `cat`/`jq`.
//   - Append-only writes through a serial queue. Each line is < 4 KB so a
//     single `Data.write` is atomic on darwin under O_APPEND.
//   - Soft rotation at `maxFileSizeBytes`: rename current to `.old` and
//     start fresh. Reader checks both files. Bounds disk use at ~2x cap.
//

import Foundation

public final class SharedExtensionLog {
    public static let shared = SharedExtensionLog()

    public enum Level: String, Codable {
        case info, notice, warning, error
    }

    public struct Entry: Codable {
        public let timestampMs: Int64
        public let level: Level
        public let category: String
        public let message: String
    }

    private static let appGroupID = "group.S368GH6KF7.com.lukechang.GigEVirtualCamera"
    private static let directoryName = "ExtensionDiagnostics"
    private static let currentFileName = "log.jsonl"
    private static let rotatedFileName = "log.jsonl.old"
    /// Rotate when the active file passes this size. 5 MB is ~35k entries at
    /// ~150 B each — plenty for any session, small enough to read quickly.
    private static let maxFileSizeBytes: UInt64 = 5 * 1024 * 1024
    /// Truncate over-long messages so a runaway log line can't blow past
    /// PIPE_BUF and break the single-write atomicity guarantee.
    private static let maxMessageBytes = 3500

    private let queue = DispatchQueue(label: "com.lukechang.SharedExtensionLog", qos: .utility)
    private let encoder: JSONEncoder = {
        let e = JSONEncoder()
        // Compact output — JSONL needs one line per record.
        e.outputFormatting = []
        return e
    }()

    /// Resolved on first use and cached. `nil` if the app group container is
    /// somehow unavailable (entitlement misconfiguration); writes become no-ops.
    private lazy var currentFileURL: URL? = makeFileURL(name: Self.currentFileName)
    private lazy var rotatedFileURL: URL? = makeFileURL(name: Self.rotatedFileName)

    private var currentFileHandle: FileHandle?
    private var currentFileSize: UInt64 = 0

    private init() {}

    // MARK: - Writer API (extension)

    public func write(level: Level, category: String, message: String) {
        // Capture timestamp on the caller's thread so a queue backlog
        // doesn't backdate entries.
        let timestampMs = Int64(Date().timeIntervalSince1970 * 1000)
        let trimmed = Self.truncate(message, toBytes: Self.maxMessageBytes)
        let entry = Entry(timestampMs: timestampMs, level: level,
                          category: category, message: trimmed)
        queue.async { [weak self] in
            self?.appendOnQueue(entry)
        }
    }

    // MARK: - Reader API (app)

    /// Read all entries newer than the cursor and advance the cursor in place.
    /// Returns entries in chronological order. Safe to call repeatedly; new
    /// reads are incremental (byte-offset based against the active file).
    ///
    /// Implementation note: the rotated file is only consulted on the FIRST
    /// read after process start (cursor at 0/distantPast) or when we detect
    /// rotation (active file shrunk below cursor). Steady-state reads only
    /// touch the active file.
    public func readNewEntries(cursor: inout Cursor) -> [Entry] {
        var results: [Entry] = []
        // Detect rotation by comparing the rotated file's mtime against the
        // last one we saw. If rotation happened since the last read, drain
        // the rotated file (which now contains entries newer than cursor).
        if let rotatedURL = rotatedFileURL,
           let rotatedMtime = fileModificationDate(at: rotatedURL),
           rotatedMtime > cursor.lastSeenRotationDate {
            results.append(contentsOf: parseEntries(in: rotatedURL, after: cursor.lastEntryDate))
            cursor.lastSeenRotationDate = rotatedMtime
            // After rotation we restart byte cursor; the active file is fresh.
            cursor.activeFileOffset = 0
        }

        if let currentURL = currentFileURL {
            // If the active file shrank, an in-flight rotation happened
            // between rotation detection and now; reset to start.
            let size = fileSize(at: currentURL) ?? 0
            if size < cursor.activeFileOffset {
                cursor.activeFileOffset = 0
            }
            let (entries, newOffset) = parseEntries(in: currentURL,
                                                    fromOffset: cursor.activeFileOffset)
            results.append(contentsOf: entries)
            cursor.activeFileOffset = newOffset
        }

        if let lastTs = results.last?.timestampMs {
            cursor.lastEntryDate = Date(timeIntervalSince1970: TimeInterval(lastTs) / 1000)
        }
        return results
    }

    /// Wipe both files. Called from the drawer's "Clear" button.
    public func clear() {
        queue.async { [weak self] in
            guard let self = self else { return }
            self.currentFileHandle?.closeFile()
            self.currentFileHandle = nil
            self.currentFileSize = 0
            if let u = self.currentFileURL { try? FileManager.default.removeItem(at: u) }
            if let u = self.rotatedFileURL { try? FileManager.default.removeItem(at: u) }
        }
    }

    /// Cursor that the reader uses to track its progress. Caller owns it and
    /// passes it back in on each `readNewEntries` call. Initial value is the
    /// no-op default — first read returns everything currently on disk.
    public struct Cursor {
        public var activeFileOffset: UInt64 = 0
        public var lastSeenRotationDate: Date = .distantPast
        public var lastEntryDate: Date = .distantPast
        public init() {}
    }

    // MARK: - Internals (writer)

    private func appendOnQueue(_ entry: Entry) {
        guard let url = currentFileURL else { return }
        guard let payload = try? encoder.encode(entry) else { return }

        // Lazy-init the file + handle. If anything fails (sandbox refusal,
        // disk full), drop the entry — diagnostic logging must not crash
        // the extension's hot path.
        if currentFileHandle == nil {
            do {
                try FileManager.default.createDirectory(
                    at: url.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                if !FileManager.default.fileExists(atPath: url.path) {
                    FileManager.default.createFile(atPath: url.path, contents: nil)
                }
                let handle = try FileHandle(forWritingTo: url)
                _ = try? handle.seekToEnd()
                currentFileHandle = handle
                currentFileSize = (try? fileSizeViaHandle(handle)) ?? 0
            } catch {
                return
            }
        }

        guard let handle = currentFileHandle else { return }

        // One write per entry: JSON bytes + '\n'. Bounded above by
        // maxMessageBytes + overhead → < 4 KB, single atomic syscall in
        // append mode.
        var line = payload
        line.append(0x0A)  // '\n'

        do {
            try handle.write(contentsOf: line)
            currentFileSize &+= UInt64(line.count)
        } catch {
            // Re-open on next call.
            currentFileHandle = nil
            return
        }

        if currentFileSize > Self.maxFileSizeBytes {
            rotateOnQueue()
        }
    }

    private func rotateOnQueue() {
        currentFileHandle?.closeFile()
        currentFileHandle = nil
        currentFileSize = 0
        guard let current = currentFileURL, let rotated = rotatedFileURL else { return }
        // Overwrite any existing .old without prompting.
        try? FileManager.default.removeItem(at: rotated)
        try? FileManager.default.moveItem(at: current, to: rotated)
    }

    // MARK: - Internals (reader)

    private func parseEntries(in url: URL, after date: Date) -> [Entry] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        return decodeLines(in: data, filterAfterMs: Int64(date.timeIntervalSince1970 * 1000))
    }

    private func parseEntries(in url: URL, fromOffset offset: UInt64) -> ([Entry], UInt64) {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return ([], offset) }
        defer { try? handle.close() }
        do {
            try handle.seek(toOffset: offset)
        } catch {
            return ([], offset)
        }
        let data = (try? handle.readToEnd()) ?? Data()
        let entries = decodeLines(in: data, filterAfterMs: nil)
        let newOffset = offset &+ UInt64(data.count)
        return (entries, newOffset)
    }

    private func decodeLines(in data: Data, filterAfterMs: Int64?) -> [Entry] {
        guard !data.isEmpty else { return [] }
        var entries: [Entry] = []
        // Split on newline. Partial trailing line (no '\n' yet) is skipped.
        var start = data.startIndex
        let decoder = JSONDecoder()
        while start < data.endIndex {
            guard let nlIdx = data[start..<data.endIndex].firstIndex(of: 0x0A) else { break }
            let slice = data[start..<nlIdx]
            start = data.index(after: nlIdx)
            if slice.isEmpty { continue }
            guard let entry = try? decoder.decode(Entry.self, from: slice) else { continue }
            if let cutoff = filterAfterMs, entry.timestampMs <= cutoff { continue }
            entries.append(entry)
        }
        return entries
    }

    // MARK: - Helpers

    private func makeFileURL(name: String) -> URL? {
        guard let container = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: Self.appGroupID
        ) else { return nil }
        return container
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Caches", isDirectory: true)
            .appendingPathComponent(Self.directoryName, isDirectory: true)
            .appendingPathComponent(name)
    }

    private func fileSize(at url: URL) -> UInt64? {
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        return (attrs?[.size] as? NSNumber)?.uint64Value
    }

    private func fileSizeViaHandle(_ handle: FileHandle) throws -> UInt64 {
        let end = try handle.seekToEnd()
        return end
    }

    private func fileModificationDate(at url: URL) -> Date? {
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        return attrs?[.modificationDate] as? Date
    }

    private static func truncate(_ s: String, toBytes maxBytes: Int) -> String {
        if s.utf8.count <= maxBytes { return s }
        // Drop trailing bytes; reslice to a valid scalar boundary.
        var bytes = Array(s.utf8.prefix(maxBytes))
        while !bytes.isEmpty {
            if let s = String(bytes: bytes, encoding: .utf8) { return s + "…" }
            bytes.removeLast()
        }
        return ""
    }
}
