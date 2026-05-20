# Preview + Stream Performance Overhaul Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Eliminate preview lag and protect the recorded stream by (1) reusing expensive objects, (2) isolating preview and stream onto independent threads, and (3) applying bounded backpressure with capture-time timestamps and a drop-logging sidecar manifest for research-grade sync.

**Architecture:** Frames are captured on the Aravis frame queue, stamped with capture-time identity (frame ID + camera + host timestamps) at the bridge, then handed off **without blocking the acquisition loop** to two independent serial queues — a drop-to-latest **preview** path and a bounded-FIFO **stream** path. The preview reuses a single `CIContext` and renders downscaled; the stream reuses a pixel-buffer pool and stamps each `CMSampleBuffer` with the capture-time PTS. Every delivered or dropped frame is recorded to a CSV sidecar manifest keyed by the monotonic Aravis frame ID, so missing frames are *observable* rather than silent.

**Tech Stack:** Swift / SwiftUI, Objective-C++ (Aravis bridge), Core Image, Core Video, CoreMediaIO. New pure-logic units live in a standalone Swift Package (`FramePipelineKit`) tested with **Swift Testing** (`swift test`), which runs unmodified on the GitHub Actions macOS runner.

---

## Why this structure

Two hard constraints from the codebase shape every decision below:

1. **`xcodegen` is forbidden** (it breaks manual provisioning) and the `.xcodeproj` references each source file individually (no synchronized folder groups). Therefore **adding a brand-new `.swift` file to the app target is expensive** (manual pbxproj/Xcode work), while **editing an existing file is free**.
2. **There is no test target**, and adding one would require the forbidden project regeneration.

The resolution: **all new, unit-testable logic lives in a SwiftPM package** (`FramePipelineKit`) added to the app *once* as a local package dependency via the Xcode GUI (Task 7). Every other change is made *inside existing files*. This gives us real TDD on the algorithmic core (`swift test`, CI-friendly) without touching the project's file-reference machinery more than once.

## Testing approach (and why it works on GHA)

- **Unit tests:** Swift Testing in `FramePipelineKit`. Run with `swift test` from the package directory. No Xcode, no signing, no provisioning, no `xcodegen` — runs identically on a dev machine and on the GHA `macos-15` runner. Task 6 adds the workflow.
- **Integration (camera/UI/CMIO) changes:** cannot be unit-tested without hardware. They are verified by **building the app** (`xcodebuild`) and **running against the built-in Aravis fake camera** while observing `os_signpost` output and the sidecar manifest file. Each integration task lists the exact build command and the exact observable success criteria.

## File structure

**New (in package — unit tested):**
- `FramePipelineKit/Package.swift` — SwiftPM manifest (library + test target)
- `FramePipelineKit/Sources/FramePipelineKit/FrameTimestamp.swift` — capture-time identity value type + gap detection
- `FramePipelineKit/Sources/FramePipelineKit/LatestFrameSlot.swift` — thread-safe drop-to-latest single slot (preview backpressure)
- `FramePipelineKit/Sources/FramePipelineKit/BoundedFrameRing.swift` — thread-safe bounded FIFO, drop-oldest-on-overflow (stream backpressure)
- `FramePipelineKit/Sources/FramePipelineKit/FrameManifestWriter.swift` — append-only CSV sidecar writer
- `FramePipelineKit/Tests/FramePipelineKitTests/*.swift` — Swift Testing suites
- `.github/workflows/test.yml` — runs `swift test` on GHA

**Modified (existing app files — integration, build-verified):**
- `GigECameraApp/AravisBridge.h` — extend delegate with frame ID + timestamps
- `GigECameraApp/AravisBridge.mm` — capture capture-time identity; deliver off the acquisition path without re-dispatching to main
- `GigECameraApp/GigECameraManager.swift` — define `PipelineFrame`; fan-out to preview/stream queues; drive the manifest; replace the handler-list API
- `GigECameraApp/CameraPreviewView.swift` — reuse one `CIContext`, downscale, main thread only for the image assignment
- `GigECameraApp/PixelBufferConverter.swift` — pooled YUV output buffers
- `GigECameraApp/CMIOFrameSender.swift` — `sendFrame(_:timestamp:) -> Bool` stamping capture-time PTS
- `GigECameraApp/CameraManager.swift` — wire the stream callback; manifest lifecycle

---

## Phase 1 — Pure-logic package (TDD via `swift test`)

### Task 1: Scaffold the `FramePipelineKit` package

**Files:**
- Create: `FramePipelineKit/Package.swift`
- Create: `FramePipelineKit/Sources/FramePipelineKit/FramePipelineKit.swift`
- Create: `FramePipelineKit/Tests/FramePipelineKitTests/SmokeTests.swift`

- [ ] **Step 1: Write the manifest**

`FramePipelineKit/Package.swift`:
```swift
// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "FramePipelineKit",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "FramePipelineKit", targets: ["FramePipelineKit"])
    ],
    targets: [
        .target(name: "FramePipelineKit"),
        .testTarget(
            name: "FramePipelineKitTests",
            dependencies: ["FramePipelineKit"]
        )
    ]
)
```

- [ ] **Step 2: Add a placeholder source so the target compiles**

`FramePipelineKit/Sources/FramePipelineKit/FramePipelineKit.swift`:
```swift
// FramePipelineKit: pure, platform-agnostic frame-pipeline primitives.
// Camera/UI/CMIO code lives in the app target and depends on this package.
public enum FramePipelineKit {
    public static let version = "1.0.0"
}
```

- [ ] **Step 3: Write a smoke test (Swift Testing)**

`FramePipelineKit/Tests/FramePipelineKitTests/SmokeTests.swift`:
```swift
import Testing
@testable import FramePipelineKit

@Test func packageVersionIsSet() {
    #expect(FramePipelineKit.version == "1.0.0")
}
```

- [ ] **Step 4: Run the tests, verify they pass**

Run: `cd FramePipelineKit && swift test`
Expected: build succeeds, `1 test` passes (Swift Testing prints `Test run with 1 test ... passed`).

- [ ] **Step 5: Commit**

```bash
git add FramePipelineKit
git commit -m "feat(pipeline): scaffold FramePipelineKit swift package with Swift Testing"
```

---

### Task 2: `FrameTimestamp` — capture-time identity + gap detection

**Files:**
- Create: `FramePipelineKit/Sources/FramePipelineKit/FrameTimestamp.swift`
- Test: `FramePipelineKit/Tests/FramePipelineKitTests/FrameTimestampTests.swift`

- [ ] **Step 1: Write the failing tests**

`FramePipelineKit/Tests/FramePipelineKitTests/FrameTimestampTests.swift`:
```swift
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
```

- [ ] **Step 2: Run, verify failure**

Run: `cd FramePipelineKit && swift test`
Expected: compile error / FAIL — `cannot find 'FrameTimestamp' in scope`.

- [ ] **Step 3: Implement**

`FramePipelineKit/Sources/FramePipelineKit/FrameTimestamp.swift`:
```swift
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
```

- [ ] **Step 4: Run, verify pass**

Run: `cd FramePipelineKit && swift test`
Expected: all `FrameTimestampTests` pass.

- [ ] **Step 5: Commit**

```bash
git add FramePipelineKit
git commit -m "feat(pipeline): add FrameTimestamp with frame-gap detection"
```

---

### Task 3: `LatestFrameSlot` — drop-to-latest (preview backpressure)

**Files:**
- Create: `FramePipelineKit/Sources/FramePipelineKit/LatestFrameSlot.swift`
- Test: `FramePipelineKit/Tests/FramePipelineKitTests/LatestFrameSlotTests.swift`

- [ ] **Step 1: Write the failing tests**

`FramePipelineKit/Tests/FramePipelineKitTests/LatestFrameSlotTests.swift`:
```swift
import Testing
@testable import FramePipelineKit

@Suite struct LatestFrameSlotTests {
    @Test func takeReturnsTheValueThatWasSet() {
        let slot = LatestFrameSlot<Int>()
        slot.set(42)
        #expect(slot.take() == 42)
    }

    @Test func takeOnEmptyReturnsNil() {
        let slot = LatestFrameSlot<Int>()
        #expect(slot.take() == nil)
    }

    @Test func secondSetReplacesFirstAndCountsDrop() {
        let slot = LatestFrameSlot<Int>()
        slot.set(1)
        let displaced = slot.set(2)
        #expect(displaced == 1)
        #expect(slot.droppedCount == 1)
        #expect(slot.take() == 2)
    }

    @Test func takeClearsTheSlot() {
        let slot = LatestFrameSlot<Int>()
        slot.set(9)
        _ = slot.take()
        #expect(slot.take() == nil)
    }
}
```

- [ ] **Step 2: Run, verify failure**

Run: `cd FramePipelineKit && swift test`
Expected: FAIL — `cannot find 'LatestFrameSlot' in scope`.

- [ ] **Step 3: Implement**

`FramePipelineKit/Sources/FramePipelineKit/LatestFrameSlot.swift`:
```swift
import Foundation

/// Thread-safe single-value slot with drop-to-latest semantics.
/// Setting a new value while one is pending discards the old one (counted as a
/// drop). Correct for a live preview, where only the newest frame matters.
public final class LatestFrameSlot<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value?
    private var _droppedCount = 0

    public init() {}

    public var droppedCount: Int {
        lock.lock(); defer { lock.unlock() }
        return _droppedCount
    }

    /// Store `newValue`. Returns the displaced value, if any.
    @discardableResult
    public func set(_ newValue: Value) -> Value? {
        lock.lock(); defer { lock.unlock() }
        let displaced = value
        if displaced != nil { _droppedCount += 1 }
        value = newValue
        return displaced
    }

    /// Remove and return the current value, leaving the slot empty.
    public func take() -> Value? {
        lock.lock(); defer { lock.unlock() }
        let current = value
        value = nil
        return current
    }
}
```

- [ ] **Step 4: Run, verify pass**

Run: `cd FramePipelineKit && swift test`
Expected: all `LatestFrameSlotTests` pass.

- [ ] **Step 5: Commit**

```bash
git add FramePipelineKit
git commit -m "feat(pipeline): add LatestFrameSlot drop-to-latest primitive"
```

---

### Task 4: `BoundedFrameRing` — bounded FIFO, drop-oldest (stream backpressure)

**Files:**
- Create: `FramePipelineKit/Sources/FramePipelineKit/BoundedFrameRing.swift`
- Test: `FramePipelineKit/Tests/FramePipelineKitTests/BoundedFrameRingTests.swift`

- [ ] **Step 1: Write the failing tests**

`FramePipelineKit/Tests/FramePipelineKitTests/BoundedFrameRingTests.swift`:
```swift
import Testing
@testable import FramePipelineKit

@Suite struct BoundedFrameRingTests {
    @Test func pushesWithinCapacityKeepFifoOrder() {
        let ring = BoundedFrameRing<Int>(capacity: 3)
        #expect(ring.push(1) == nil)
        #expect(ring.push(2) == nil)
        #expect(ring.push(3) == nil)
        #expect(ring.count == 3)
        #expect(ring.pop() == 1)
        #expect(ring.pop() == 2)
        #expect(ring.pop() == 3)
        #expect(ring.pop() == nil)
    }

    @Test func overflowDropsOldestAndReturnsIt() {
        let ring = BoundedFrameRing<Int>(capacity: 2)
        #expect(ring.push(1) == nil)
        #expect(ring.push(2) == nil)
        let dropped = ring.push(3) // capacity exceeded -> drop oldest (1)
        #expect(dropped == 1)
        #expect(ring.totalDropped == 1)
        #expect(ring.count == 2)
        #expect(ring.pop() == 2)
        #expect(ring.pop() == 3)
    }

    @Test func popOnEmptyReturnsNil() {
        let ring = BoundedFrameRing<Int>(capacity: 4)
        #expect(ring.pop() == nil)
    }
}
```

- [ ] **Step 2: Run, verify failure**

Run: `cd FramePipelineKit && swift test`
Expected: FAIL — `cannot find 'BoundedFrameRing' in scope`.

- [ ] **Step 3: Implement**

`FramePipelineKit/Sources/FramePipelineKit/BoundedFrameRing.swift`:
```swift
import Foundation

/// Thread-safe bounded FIFO. When full, `push` discards the oldest element to
/// keep latency bounded toward "live", and returns it so the caller can log the
/// drop. Correct for a stream that must not accumulate latency but should buffer
/// transient spikes rather than dropping on every hiccup.
public final class BoundedFrameRing<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [Value] = []
    private var _totalDropped = 0
    public let capacity: Int

    public init(capacity: Int) {
        precondition(capacity > 0, "capacity must be > 0")
        self.capacity = capacity
        storage.reserveCapacity(capacity + 1)
    }

    /// Append `value`. If at capacity, drop and return the oldest element.
    @discardableResult
    public func push(_ value: Value) -> Value? {
        lock.lock(); defer { lock.unlock() }
        var dropped: Value?
        if storage.count >= capacity {
            dropped = storage.removeFirst()
            _totalDropped += 1
        }
        storage.append(value)
        return dropped
    }

    public func pop() -> Value? {
        lock.lock(); defer { lock.unlock() }
        return storage.isEmpty ? nil : storage.removeFirst()
    }

    public var count: Int {
        lock.lock(); defer { lock.unlock() }
        return storage.count
    }

    public var totalDropped: Int {
        lock.lock(); defer { lock.unlock() }
        return _totalDropped
    }
}
```

- [ ] **Step 4: Run, verify pass**

Run: `cd FramePipelineKit && swift test`
Expected: all `BoundedFrameRingTests` pass.

- [ ] **Step 5: Commit**

```bash
git add FramePipelineKit
git commit -m "feat(pipeline): add BoundedFrameRing drop-oldest backpressure buffer"
```

---

### Task 5: `FrameManifestWriter` — CSV sidecar for sync-critical drop logging

**Files:**
- Create: `FramePipelineKit/Sources/FramePipelineKit/FrameManifestWriter.swift`
- Test: `FramePipelineKit/Tests/FramePipelineKitTests/FrameManifestWriterTests.swift`

- [ ] **Step 1: Write the failing tests**

`FramePipelineKit/Tests/FramePipelineKitTests/FrameManifestWriterTests.swift`:
```swift
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
```

- [ ] **Step 2: Run, verify failure**

Run: `cd FramePipelineKit && swift test`
Expected: FAIL — `cannot find 'FrameManifestWriter' in scope`.

- [ ] **Step 3: Implement**

`FramePipelineKit/Sources/FramePipelineKit/FrameManifestWriter.swift`:
```swift
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
```

- [ ] **Step 4: Run, verify pass**

Run: `cd FramePipelineKit && swift test`
Expected: all tests pass (`FrameManifestWriterTests` + earlier suites).

- [ ] **Step 5: Commit**

```bash
git add FramePipelineKit
git commit -m "feat(pipeline): add FrameManifestWriter CSV sidecar for drop logging"
```

---

### Task 6: GitHub Actions workflow to run `swift test`

**Files:**
- Create: `.github/workflows/test.yml`

- [ ] **Step 1: Write the workflow**

`.github/workflows/test.yml`:
```yaml
name: Unit Tests

on:
  push:
    branches: [main]
  pull_request:

jobs:
  framepipelinekit:
    runs-on: macos-15
    steps:
      - uses: actions/checkout@v4
      - name: Show Swift version
        run: swift --version
      - name: Run FramePipelineKit tests
        working-directory: FramePipelineKit
        run: swift test
```

- [ ] **Step 2: Verify locally that the exact CI command passes**

Run: `cd FramePipelineKit && swift test`
Expected: all suites pass. (This is the same command CI runs, so a local pass predicts a CI pass.)

- [ ] **Step 3: Commit**

```bash
git add .github/workflows/test.yml
git commit -m "ci: run FramePipelineKit unit tests on GitHub Actions"
```

---

## Phase 2 — Integrate the package into the app

### Task 7: Add `FramePipelineKit` as a local package dependency

> Integration task — verified by build, not unit test. This is the single deliberate `.xcodeproj` edit; do it through the Xcode GUI so the pbxproj is updated correctly without `xcodegen`.

**Files:**
- Modify: `GigEVirtualCamera.xcodeproj` (via Xcode GUI)

- [ ] **Step 1: Add the local package**

In Xcode: open `GigEVirtualCamera.xcodeproj` → File ▸ Add Package Dependencies… ▸ "Add Local…" ▸ select the `FramePipelineKit` folder ▸ Add Package. When prompted, add the `FramePipelineKit` library product to the **GigEVirtualCamera** app target only (not the extension).

- [ ] **Step 2: Verify the dependency compiles into the app**

Add a temporary import to confirm linkage. In `GigECameraApp/GigECameraManager.swift`, add at the top (just below `import Combine`):
```swift
import FramePipelineKit
```

- [ ] **Step 3: Build**

Run:
```bash
xcodebuild -project GigEVirtualCamera.xcodeproj -scheme GigECameraApp -configuration Debug build
```
Expected: `** BUILD SUCCEEDED **`. If the scheme name differs, list schemes with `xcodebuild -list -project GigEVirtualCamera.xcodeproj` and use the app scheme.

- [ ] **Step 4: Commit**

```bash
git add GigEVirtualCamera.xcodeproj GigECameraApp/GigECameraManager.swift
git commit -m "build: link FramePipelineKit local package into app target"
```

---

## Phase 3 — Capture-time identity at the bridge

### Task 8: Stamp frame id + timestamps and deliver off the acquisition path

> Integration task — verified by build + runtime log. **Key behavior change:** the delegate is currently re-dispatched to the **main thread** (`AravisBridge.mm:659`), which funnels all per-frame work onto the UI thread. We remove that hop: the delegate is invoked directly on the frame queue with a cheap, non-blocking fan-out (Task 9), and capture-time identity is read before any heavy work.

**Files:**
- Modify: `GigECameraApp/AravisBridge.h:30-34`
- Modify: `GigECameraApp/AravisBridge.mm:572-575` and `:644-674`

- [ ] **Step 1: Extend the delegate protocol**

In `GigECameraApp/AravisBridge.h`, replace the `didReceiveFrame` line in the protocol (currently line 31):
```objc
- (void)aravisBridge:(id)bridge didReceiveFrame:(CVPixelBufferRef)pixelBuffer;
```
with:
```objc
- (void)aravisBridge:(id)bridge
      didReceiveFrame:(CVPixelBufferRef)pixelBuffer
              frameID:(uint64_t)frameID
    cameraTimestampNs:(uint64_t)cameraTimestampNs
      hostTimestampNs:(uint64_t)hostTimestampNs;
```

- [ ] **Step 2: Capture identity at the top of `processBuffer`**

In `GigECameraApp/AravisBridge.mm`, immediately after line 575 (`arv_buffer_get_image_region(...)`), add:
```objc
    // Capture-time identity, read before any conversion work so timing never
    // inherits downstream queue jitter. CLOCK_UPTIME_RAW shares the mach
    // timebase used by CMClockGetHostTimeClock, so it is a valid host-domain PTS.
    uint64_t frameID = arv_buffer_get_frame_id(buffer);
    uint64_t cameraTimestampNs = arv_buffer_get_timestamp(buffer);
    uint64_t hostTimestampNs = clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
```

- [ ] **Step 3: Deliver on the frame queue (no main-thread hop), passing identity**

In `GigECameraApp/AravisBridge.mm`, replace the delivery block (currently lines 659-666):
```objc
        dispatch_async(dispatch_get_main_queue(), ^{
            if (self.delegate) {
                [self.delegate aravisBridge:self didReceiveFrame:pixelBuffer];
            } else {
                NSLog(@"AravisBridge: WARNING - No delegate set, dropping frame!");
            }
            CVPixelBufferRelease(pixelBuffer);
        });
```
with:
```objc
        // Deliver synchronously on the frame queue. The delegate fan-out is a
        // cheap, non-blocking enqueue (see GigECameraManager), so the acquisition
        // loop is not stalled and the Aravis buffer is recycled promptly below.
        if (self.delegate) {
            [self.delegate aravisBridge:self
                        didReceiveFrame:pixelBuffer
                                frameID:frameID
                      cameraTimestampNs:cameraTimestampNs
                        hostTimestampNs:hostTimestampNs];
        } else {
            NSLog(@"AravisBridge: WARNING - No delegate set, dropping frame!");
        }
        CVPixelBufferRelease(pixelBuffer);
```

- [ ] **Step 4: Build (expect a Swift conformance error — that is correct)**

Run:
```bash
xcodebuild -project GigEVirtualCamera.xcodeproj -scheme GigECameraApp -configuration Debug build
```
Expected: FAIL — `GigECameraManager` no longer satisfies `AravisBridgeDelegate` (signature changed). This proves the protocol change took effect; Task 9 updates the conformance.

- [ ] **Step 5: Commit**

```bash
git add GigECameraApp/AravisBridge.h GigECameraApp/AravisBridge.mm
git commit -m "feat(bridge): stamp capture-time identity and deliver off main thread"
```

---

## Phase 4 — Fan-out in GigECameraManager

### Task 9: `PipelineFrame` + dual-queue fan-out + manifest

> Integration task — verified by build + runtime log. Replaces the unsafe shared `frameHandlers` list (whose `removeAllFrameHandlers()` also tore down the stream feed) with two explicit, independent consumer paths plus the manifest.

**Files:**
- Modify: `GigECameraApp/GigECameraManager.swift` (properties at `:26-30`, frame API at `:197-205`, delegate at `:261-277`)

- [ ] **Step 1: Add pipeline state and the `PipelineFrame` type**

In `GigECameraApp/GigECameraManager.swift`, replace the existing private storage block (currently lines 26-30):
```swift
    private let aravisBridge = AravisBridge()
    private var frameHandlers: [(CVPixelBuffer) -> Void] = []
    private var lastDiscoveryTime = Date.distantPast
    private var connectionRetryCount = 0
    private var frameDistributionCount = 0
```
with:
```swift
    private let aravisBridge = AravisBridge()
    private var lastDiscoveryTime = Date.distantPast
    private var connectionRetryCount = 0

    // MARK: - Frame fan-out
    /// One frame plus its capture-time identity, passed to both consumers.
    public struct PipelineFrame {
        public let pixelBuffer: CVPixelBuffer
        public let timestamp: FrameTimestamp
    }

    /// Preview consumer: drop-to-latest; cosmetic, never logged.
    private let previewSlot = LatestFrameSlot<PipelineFrame>()
    private let previewQueue = DispatchQueue(label: "com.lukechang.gigecamera.preview", qos: .userInitiated)
    /// Invoked on `previewQueue` with the newest available frame.
    public var onPreviewFrame: ((PipelineFrame) -> Void)?

    /// Stream consumer: bounded FIFO; drops are logged to the manifest.
    private let streamRing = BoundedFrameRing<PipelineFrame>(capacity: 6)
    private let streamQueue = DispatchQueue(label: "com.lukechang.gigecamera.stream", qos: .userInitiated)
    /// Invoked on `streamQueue`; returns true if the frame was enqueued to the sink.
    public var onStreamFrame: ((PipelineFrame) -> Bool)?

    /// Sidecar manifest; non-nil only while a streaming session is active.
    private var manifestWriter: FrameManifestWriter?
    private let manifestLock = NSLock()
    private var lastStreamFrameID: UInt64?
```

- [ ] **Step 2: Replace the handler registration API with manifest lifecycle**

In `GigECameraApp/GigECameraManager.swift`, replace the `addFrameHandler`/`removeAllFrameHandlers` block (currently lines 199-205):
```swift
    func addFrameHandler(_ handler: @escaping (CVPixelBuffer) -> Void) {
        frameHandlers.append(handler)
    }

    func removeAllFrameHandlers() {
        frameHandlers.removeAll()
    }
```
with:
```swift
    /// Begin a manifest for a new streaming session. Safe to call repeatedly.
    func startManifest() {
        manifestLock.lock(); defer { manifestLock.unlock() }
        guard manifestWriter == nil else { return }
        let dir = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("GigEVirtualCamera/manifests", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let url = dir.appendingPathComponent("frames-\(stamp).csv")
        manifestWriter = try? FrameManifestWriter(url: url)
        lastStreamFrameID = nil
        print("GigECameraManager: frame manifest -> \(url.path)")
    }

    /// Close the current manifest at the end of a streaming session.
    func stopManifest() {
        manifestLock.lock(); defer { manifestLock.unlock() }
        manifestWriter?.close()
        manifestWriter = nil
    }

    private func recordManifest(_ ts: FrameTimestamp, status: FrameManifestWriter.Status) {
        manifestLock.lock(); defer { manifestLock.unlock() }
        manifestWriter?.record(ts, status: status)
    }
```

- [ ] **Step 3: Rewrite the delegate to fan out (new signature)**

In `GigECameraApp/GigECameraManager.swift`, replace the entire `didReceiveFrame` method (currently lines 262-277):
```swift
    @objc func aravisBridge(_ bridge: Any, didReceiveFrame pixelBuffer: CVPixelBuffer) {
        print("GigECameraManager: 🎯 didReceiveFrame called!")
        // Notify all frame handlers
        if frameHandlers.isEmpty {
            print("GigECameraManager: ⚠️ Received frame but no handlers registered!")
        } else {
            // Only log every 30th frame to avoid spam
            frameDistributionCount += 1
            if frameDistributionCount == 1 || frameDistributionCount % 30 == 0 {
                print("GigECameraManager: 📹 Distributing frame #\(frameDistributionCount) to \(frameHandlers.count) handlers")
            }
            for handler in frameHandlers {
                handler(pixelBuffer)
            }
        }
    }
```
with:
```swift
    @objc func aravisBridge(_ bridge: Any,
                            didReceiveFrame pixelBuffer: CVPixelBuffer,
                            frameID: UInt64,
                            cameraTimestampNs: UInt64,
                            hostTimestampNs: UInt64) {
        // Runs on the Aravis frame queue. Do only cheap, non-blocking work here.
        let ts = FrameTimestamp(frameID: frameID,
                                cameraTimestampNs: cameraTimestampNs,
                                hostTimestampNs: hostTimestampNs)
        let frame = PipelineFrame(pixelBuffer: pixelBuffer, timestamp: ts)

        // Preview: keep only the newest; render off the acquisition thread.
        previewSlot.set(frame)
        previewQueue.async { [weak self] in
            guard let self, let latest = self.previewSlot.take() else { return }
            self.onPreviewFrame?(latest)
        }

        // Stream: bounded buffer; a displaced frame is a logged buffer-drop.
        if let dropped = streamRing.push(frame) {
            recordManifest(dropped.timestamp, status: .droppedBuffer)
        }
        streamQueue.async { [weak self] in
            guard let self, let next = self.streamRing.pop() else { return }
            let delivered = self.onStreamFrame?(next) ?? false
            self.recordManifest(next.timestamp,
                                status: delivered ? .delivered : .droppedQueue)
        }
    }
```

- [ ] **Step 4: Build (expect errors in CameraManager/CameraPreviewView — fixed in Tasks 10–12)**

Run:
```bash
xcodebuild -project GigEVirtualCamera.xcodeproj -scheme GigECameraApp -configuration Debug build 2>&1 | grep -E "error:|BUILD" | head
```
Expected: errors only in `CameraManager.swift` and `CameraPreviewView.swift` referencing the removed `addFrameHandler`/`removeAllFrameHandlers`. `GigECameraManager.swift` itself compiles.

- [ ] **Step 5: Commit**

```bash
git add GigECameraApp/GigECameraManager.swift
git commit -m "feat(pipeline): fan out frames to preview/stream queues with manifest"
```

---

## Phase 5 — Preview path

### Task 10: Reuse one `CIContext`, downscale, main thread only for the image

> Integration task — verified by build + runtime. Removes the per-frame `CIContext()` allocation (`CameraPreviewView.swift:107`) and moves rendering off the main thread (it now runs on `previewQueue`); the main thread is touched only to publish the image.

**Files:**
- Modify: `GigECameraApp/CameraPreviewView.swift:72-117`

- [ ] **Step 1: Rewrite `FrameHandler`**

In `GigECameraApp/CameraPreviewView.swift`, replace the entire `FrameHandler` class (currently lines 72-117) with:
```swift
// MARK: - Frame Handler
class FrameHandler: ObservableObject {
    @Published var currentImage: NSImage?
    @Published var fps: Double = 0.0

    private var frameCount = 0
    private var lastFPSUpdate = Date()
    private let gigEManager = GigECameraManager.shared

    // Created once and reused. Color management disabled for the preview path:
    // a live preview does not need colorimetric accuracy, and skipping it removes
    // per-pixel gamma math. (Reusing the context is Apple's #1 Core Image perf rule.)
    private let ciContext = CIContext(options: [.workingColorSpace: NSNull()])

    // Preview is rendered downscaled; performance scales with output pixels.
    private let maxPreviewWidth: CGFloat = 1280

    func startReceivingFrames() {
        gigEManager.onPreviewFrame = { [weak self] frame in
            self?.handleFrame(frame.pixelBuffer)
        }
    }

    func stopReceivingFrames() {
        // Only detaches the preview. The stream path is independent and untouched.
        gigEManager.onPreviewFrame = nil
    }

    /// Called on GigECameraManager.previewQueue (a background serial queue).
    private func handleFrame(_ pixelBuffer: CVPixelBuffer) {
        frameCount += 1
        let now = Date()
        let elapsed = now.timeIntervalSince(lastFPSUpdate)
        if elapsed > 1.0 {
            let fps = Double(frameCount) / elapsed
            frameCount = 0
            lastFPSUpdate = now
            DispatchQueue.main.async { self.fps = fps }
        }

        let source = CIImage(cvPixelBuffer: pixelBuffer)
        let width = source.extent.width
        let scale = width > maxPreviewWidth ? maxPreviewWidth / width : 1.0
        let scaled = scale < 1.0
            ? source.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            : source

        guard let cgImage = ciContext.createCGImage(scaled, from: scaled.extent) else { return }
        let nsImage = NSImage(cgImage: cgImage,
                              size: NSSize(width: cgImage.width, height: cgImage.height))
        DispatchQueue.main.async { self.currentImage = nsImage }
    }
}
```

- [ ] **Step 2: Build (CameraManager errors remain until Task 12)**

Run:
```bash
xcodebuild -project GigEVirtualCamera.xcodeproj -scheme GigECameraApp -configuration Debug build 2>&1 | grep -E "error:|BUILD" | head
```
Expected: remaining errors only in `CameraManager.swift` (still references `addFrameHandler`). `CameraPreviewView.swift` compiles.

- [ ] **Step 3: Commit**

```bash
git add GigECameraApp/CameraPreviewView.swift
git commit -m "perf(preview): reuse CIContext, downscale, render off main thread"
```

---

## Phase 6 — Stream path

### Task 11: Pool the YUV output buffers in `PixelBufferConverter`

> Integration task — verified by build. Avoids a `CVPixelBufferCreate` allocation on every frame (`PixelBufferConverter.swift:50` and `:104`) by reusing buffers from a `CVPixelBufferPool` sized to the output.

**Files:**
- Modify: `GigECameraApp/PixelBufferConverter.swift:13-77` and `:79-131`

- [ ] **Step 1: Add a pool and a pooled-buffer helper**

In `GigECameraApp/PixelBufferConverter.swift`, replace the property/init region (currently lines 13-29):
```swift
class PixelBufferConverter {
    private let logger = Logger(subsystem: "com.lukechang.GigEVirtualCamera", category: "PixelBufferConverter")
    private var converter: VTPixelTransferSession?

    init() {
        // Create pixel transfer session
        VTPixelTransferSessionCreate(allocator: kCFAllocatorDefault, pixelTransferSessionOut: &converter)

        if let converter = converter {
            // Set conversion quality
            VTSessionSetProperty(converter, key: kVTPixelTransferPropertyKey_ScalingMode, value: kVTScalingMode_Normal)
        }
    }

    deinit {
        converter = nil
    }
```
with:
```swift
class PixelBufferConverter {
    private let logger = Logger(subsystem: "com.lukechang.GigEVirtualCamera", category: "PixelBufferConverter")
    private var converter: VTPixelTransferSession?

    // Reused output pool, recreated only when the output dimensions change.
    private var pool: CVPixelBufferPool?
    private var poolWidth = 0
    private var poolHeight = 0

    init() {
        VTPixelTransferSessionCreate(allocator: kCFAllocatorDefault, pixelTransferSessionOut: &converter)
        if let converter = converter {
            VTSessionSetProperty(converter, key: kVTPixelTransferPropertyKey_ScalingMode, value: kVTScalingMode_Normal)
        }
    }

    deinit {
        converter = nil
    }

    /// Returns a recycled YUV420 IOSurface-backed buffer of the given size,
    /// (re)building the pool only when dimensions change.
    private func dequeueYUVBuffer(width: Int, height: Int) -> CVPixelBuffer? {
        if pool == nil || width != poolWidth || height != poolHeight {
            let bufferAttrs: [CFString: Any] = [
                kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                kCVPixelBufferWidthKey: width,
                kCVPixelBufferHeightKey: height,
                kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary
            ]
            var newPool: CVPixelBufferPool?
            let status = CVPixelBufferPoolCreate(kCFAllocatorDefault, nil,
                                                 bufferAttrs as CFDictionary, &newPool)
            guard status == kCVReturnSuccess, let createdPool = newPool else {
                logger.error("Failed to create pixel buffer pool: \(status)")
                return nil
            }
            pool = createdPool
            poolWidth = width
            poolHeight = height
        }
        var buffer: CVPixelBuffer?
        let status = CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool!, &buffer)
        guard status == kCVReturnSuccess else {
            logger.error("Failed to dequeue pooled buffer: \(status)")
            return nil
        }
        return buffer
    }
```

- [ ] **Step 2: Use the pool in `convertBGRAToYUV420`**

In `GigECameraApp/PixelBufferConverter.swift`, replace the buffer-creation block inside `convertBGRAToYUV420` (currently lines 41-62):
```swift
        // Create YUV420 output buffer
        let pixelBufferAttributes: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            kCVPixelBufferWidthKey: width,
            kCVPixelBufferHeightKey: height,
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary
        ]

        var yuvBuffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            width,
            height,
            kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            pixelBufferAttributes as CFDictionary,
            &yuvBuffer
        )

        guard status == kCVReturnSuccess, let outputBuffer = yuvBuffer else {
            logger.error("Failed to create YUV buffer: \(status)")
            return nil
        }
```
with:
```swift
        guard let outputBuffer = dequeueYUVBuffer(width: width, height: height) else {
            return nil
        }
```

- [ ] **Step 3: Use the pool in `convertToHD`**

In `GigECameraApp/PixelBufferConverter.swift`, replace the scaled-buffer creation block inside `convertToHD` (currently lines 95-116):
```swift
        // Create scaled YUV buffer
        let pixelBufferAttributes: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            kCVPixelBufferWidthKey: targetWidth,
            kCVPixelBufferHeightKey: targetHeight,
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary
        ]

        var scaledBuffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            targetWidth,
            targetHeight,
            kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            pixelBufferAttributes as CFDictionary,
            &scaledBuffer
        )

        guard status == kCVReturnSuccess, let outputBuffer = scaledBuffer else {
            logger.error("Failed to create scaled buffer: \(status)")
            return nil
        }
```
with:
```swift
        guard let outputBuffer = dequeueYUVBuffer(width: targetWidth, height: targetHeight) else {
            return nil
        }
```

- [ ] **Step 4: Build**

Run:
```bash
xcodebuild -project GigEVirtualCamera.xcodeproj -scheme GigECameraApp -configuration Debug build 2>&1 | grep -E "error:|BUILD" | head
```
Expected: `PixelBufferConverter.swift` compiles (errors still only in `CameraManager.swift`).

- [ ] **Step 5: Commit**

```bash
git add GigECameraApp/PixelBufferConverter.swift
git commit -m "perf(stream): reuse pooled YUV output buffers"
```

---

### Task 12: Capture-time PTS on the sink + wire the stream callback

> Integration task — verified by build + runtime. Replaces the arrival-time PTS (`CMIOFrameSender.swift:406`) with the capture-time host timestamp, makes `sendFrame` report success, and connects `GigECameraManager.onStreamFrame` to the sink in `CameraManager`.

**Files:**
- Modify: `GigECameraApp/CMIOFrameSender.swift:299-353` and `:389-408`
- Modify: `GigECameraApp/CameraManager.swift:728-799`

- [ ] **Step 1: Make `sendFrame` accept the timestamp and return success**

In `GigECameraApp/CMIOFrameSender.swift`, change the `sendFrame` signature and the two early-return/`createSampleBuffer` call sites. Replace the signature line (currently line 299):
```swift
    func sendFrame(_ pixelBuffer: CVPixelBuffer) {
```
with:
```swift
    @discardableResult
    func sendFrame(_ pixelBuffer: CVPixelBuffer, timestamp: FrameTimestamp) -> Bool {
```
Then, in that method, update each `return` to report success/failure:
- The `guard isConnected …` block (currently lines 300-305): change its body's `return` to `return false`.
- The `guard let yuvBuffer …` block (line 308-311): change `return nil` to `return false`.
- The `guard let sampleBuffer = createSampleBuffer(from: yuvBuffer)` line (314): change to:
  ```swift
        guard let sampleBuffer = createSampleBuffer(from: yuvBuffer, timestamp: timestamp) else {
            logger.error("Failed to create sample buffer from pixel buffer")
            return false
        }
  ```
- After the `if result == noErr {` success branch (around line 322-332), make the method return `true` at the end of that branch and `false` in the error branch. Concretely, replace the closing of the method (currently lines 333-352, the `} else { … }` error handling) with:
  ```swift
        } else {
            switch result {
            case kCMSimpleQueueError_QueueIsFull:
                logger.warning("Queue is full - dropping frame")
            default:
                logger.error("Failed to enqueue buffer: \(result)")
            }
            return false
        }
        return true
    }
  ```
  (This removes the now-redundant verbose error switch while preserving the queue-full log; the boolean return is what the manifest uses to mark `delivered` vs `dropped_queue`.)

- [ ] **Step 2: Stamp capture-time PTS in `createSampleBuffer`**

In `GigECameraApp/CMIOFrameSender.swift`, change the `createSampleBuffer` signature (currently line 389):
```swift
    private func createSampleBuffer(from pixelBuffer: CVPixelBuffer) -> CMSampleBuffer? {
```
to:
```swift
    private func createSampleBuffer(from pixelBuffer: CVPixelBuffer,
                                    timestamp: FrameTimestamp) -> CMSampleBuffer? {
```
and replace the timing-info block (currently lines 404-408):
```swift
        var timingInfo = CMSampleTimingInfo(
            duration: CMTime.invalid,
            presentationTimeStamp: CMClockGetTime(CMClockGetHostTimeClock()),
            decodeTimeStamp: CMTime.invalid
        )
```
with:
```swift
        // Use the capture-time host timestamp (CLOCK_UPTIME_RAW ns, same mach
        // timebase as the host time clock) so the presentation timeline reflects
        // when the frame was captured — not when it happened to be processed.
        var timingInfo = CMSampleTimingInfo(
            duration: CMTime.invalid,
            presentationTimeStamp: CMTimeMake(value: Int64(timestamp.hostTimestampNs),
                                              timescale: 1_000_000_000),
            decodeTimeStamp: CMTime.invalid
        )
```

- [ ] **Step 3: Add the import to `CMIOFrameSender.swift`**

At the top of `GigECameraApp/CMIOFrameSender.swift`, after `import os.log` (line 12), add:
```swift
import FramePipelineKit
```

- [ ] **Step 4: Wire the stream callback and manifest lifecycle in `CameraManager`**

In `GigECameraApp/CameraManager.swift`, replace the body of `setupFrameHandler()` down to the sink-connector start (currently the handler-registration portion, lines 729-752) so it no longer calls `addFrameHandler`:
```swift
        // Set up frame handler to send frames to extension
        let gigEManager = GigECameraManager.shared
        gigEManager.addFrameHandler { [weak self] pixelBuffer in
            guard let self = self else { return }

            // Send frame through CMIO sink if connected
            if self.isFrameSenderConnected {
                self.sinkConnector.sendFrame(pixelBuffer)
                self.frameCount += 1

                // Log first frame and periodic updates
                if self.frameCount == 1 {
                    self.logger.info("First frame sent to CMIO sink!")
                } else if self.frameCount % 300 == 0 {
                    self.logger.info("Sent \(self.frameCount) frames to CMIO sink")
                }
            } else {
                // Log why we're not sending
                if self.frameCount % 30 == 0 {
                    self.logger.warning("Not sending frames - isFrameSenderConnected = false")
                }
            }
        }
```
with:
```swift
        // Stream consumer: runs on GigECameraManager.streamQueue (background).
        // Capture the connector locally to avoid main-actor isolation in the
        // closure; `sendFrame` self-guards on its own connection state and
        // returns whether the frame was actually enqueued to the sink.
        let gigEManager = GigECameraManager.shared
        let connector = self.sinkConnector
        gigEManager.onStreamFrame = { frame in
            return connector.sendFrame(frame.pixelBuffer, timestamp: frame.timestamp)
        }
```

- [ ] **Step 5: Start/stop the manifest with streaming**

In `GigECameraApp/CameraManager.swift`, in `setupSinkConnectorCallbacks()` inside the `onConnectionStateChanged` closure, after `self.isFrameSenderConnected = connected` (currently line 818), add manifest control:
```swift
            if connected {
                GigECameraManager.shared.startManifest()
            } else {
                GigECameraManager.shared.stopManifest()
            }
```

- [ ] **Step 6: Add the import to `CameraManager.swift`**

At the top of `GigECameraApp/CameraManager.swift`, after `import os.log` (line 11), add:
```swift
import FramePipelineKit
```

- [ ] **Step 7: Build — expect success**

Run:
```bash
xcodebuild -project GigEVirtualCamera.xcodeproj -scheme GigECameraApp -configuration Debug build 2>&1 | grep -E "error:|BUILD" | tail
```
Expected: `** BUILD SUCCEEDED **`, no errors.

- [ ] **Step 8: Commit**

```bash
git add GigECameraApp/CMIOFrameSender.swift GigECameraApp/CameraManager.swift
git commit -m "feat(stream): capture-time PTS, success-reporting sink, manifest lifecycle"
```

---

## Phase 7 — Cleanup, instrumentation, verification

### Task 13: Remove per-frame `print`, add `os_signpost` intervals

> Integration task — verified by build. Lightweight instrumentation so the two consumer paths can be measured in Instruments (Points of Interest) without re-architecting later. The per-frame `print` is already gone (replaced in Task 9); this adds signposts around the consumer work.

**Files:**
- Modify: `GigECameraApp/GigECameraManager.swift` (imports + the two `.async` blocks added in Task 9)

- [ ] **Step 1: Add the signpost log**

At the top of `GigECameraApp/GigECameraManager.swift`, after `import Combine`, add:
```swift
import os.signpost
```
and add a static log next to the other private properties (near the fan-out block):
```swift
    private static let signpostLog = OSLog(subsystem: "com.lukechang.GigEVirtualCamera",
                                           category: "FramePipeline")
```

- [ ] **Step 2: Wrap the preview and stream work with signposts**

In `aravisBridge(_:didReceiveFrame:…)`, wrap the body of the `previewQueue.async` block:
```swift
        previewQueue.async { [weak self] in
            guard let self, let latest = self.previewSlot.take() else { return }
            os_signpost(.begin, log: Self.signpostLog, name: "preview-render")
            self.onPreviewFrame?(latest)
            os_signpost(.end, log: Self.signpostLog, name: "preview-render")
        }
```
and the body of the `streamQueue.async` block:
```swift
        streamQueue.async { [weak self] in
            guard let self, let next = self.streamRing.pop() else { return }
            os_signpost(.begin, log: Self.signpostLog, name: "stream-send")
            let delivered = self.onStreamFrame?(next) ?? false
            os_signpost(.end, log: Self.signpostLog, name: "stream-send")
            self.recordManifest(next.timestamp,
                                status: delivered ? .delivered : .droppedQueue)
        }
```

- [ ] **Step 3: Build**

Run:
```bash
xcodebuild -project GigEVirtualCamera.xcodeproj -scheme GigECameraApp -configuration Debug build 2>&1 | grep -E "error:|BUILD" | tail
```
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 4: Commit**

```bash
git add GigECameraApp/GigECameraManager.swift
git commit -m "chore(pipeline): add os_signpost intervals for preview and stream"
```

---

### Task 14: End-to-end manual verification with the fake camera

> Integration verification — no code. Confirms the three goals (reuse, isolation, bounded backpressure + manifest) on a running app.

**Files:** none

- [ ] **Step 1: Install and launch**

Run:
```bash
./Scripts/install_app.sh
open /Applications/GigEVirtualCamera.app
```

- [ ] **Step 2: Connect the fake camera and start streaming**

In the app: select "Test Camera (Aravis Simulator)", Connect, and start streaming (per `docs/using_fake_camera.md`).

- [ ] **Step 3: Verify the manifest is being written**

Run:
```bash
ls -t ~/Library/Application\ Support/GigEVirtualCamera/manifests/ | head -1
tail -5 "$(ls -t ~/Library/Application\ Support/GigEVirtualCamera/manifests/*.csv | head -1)"
```
Expected: a `frames-<timestamp>.csv` exists; tail shows rows ending in `delivered` with **monotonically increasing `frame_id`** and no gaps under normal load.

- [ ] **Step 4: Verify preview ↔ stream isolation**

Open the preview, then open the virtual camera in QuickTime (`File ▸ New Movie Recording ▸ GigE Virtual Camera`). Confirm:
- Preview FPS label holds steady (no longer drifts down over time).
- Closing the preview window does **not** stop the QuickTime feed (regression check for the old `removeAllFrameHandlers` bug).

- [ ] **Step 5: Verify backpressure logging under load**

While streaming, induce load (e.g., set a high frame rate, or run a CPU stressor). Then check for logged drops:
```bash
grep -c "dropped_buffer\|dropped_queue" "$(ls -t ~/Library/Application\ Support/GigEVirtualCamera/manifests/*.csv | head -1)"
```
Expected: drops, when they occur, appear as explicit rows (not silent), and `frame_id` continuity lets you see exactly which frames were lost. Under normal load this count stays at/near 0.

- [ ] **Step 6: (Optional) Confirm signposts in Instruments**

Launch Instruments ▸ "Time Profiler" + "os_signpost", record the app, and confirm `preview-render` and `stream-send` intervals are short and that `preview-render` no longer dominates the main thread.

- [ ] **Step 7: Commit a short verification note (optional)**

```bash
# If you keep a verification log:
git commit --allow-empty -m "test: verified preview/stream isolation, manifest, backpressure with fake camera"
```

---

## Self-review

**Spec coverage:**
- *Initialize once* → Task 10 (single `CIContext`), Task 11 (pooled YUV buffers), and `PixelBufferConverter` already reuses its `VTPixelTransferSession`. ✓
- *Multi-thread / isolation* → Task 8 (no main-thread hop) + Task 9 (independent `previewQueue` / `streamQueue`). ✓
- *Backpressure / no accumulation* → Task 3 (`LatestFrameSlot`), Task 4 (`BoundedFrameRing`), wired in Task 9. ✓
- *Sync-critical timestamps* → Task 2 (`FrameTimestamp`), Task 8 (capture-time stamping), Task 12 (capture-time PTS). ✓
- *Drop logging / observability* → Task 5 (`FrameManifestWriter`), Task 9 + Task 12 (delivered/dropped rows). ✓
- *Bounded-buffer-not-drop-to-latest for the stream* → Task 4 capacity 6, drop-oldest. ✓
- *Works on GHA* → Task 1 (SwiftPM + Swift Testing), Task 6 (workflow). ✓
- *Fixes the `removeAllFrameHandlers` stream-teardown bug* → Task 9 (removed) + Task 10 (`onPreviewFrame = nil` only). ✓

**Type consistency:** `FrameTimestamp(frameID:cameraTimestampNs:hostTimestampNs:)`, `PipelineFrame(pixelBuffer:timestamp:)`, `onStreamFrame: ((PipelineFrame) -> Bool)?`, `sendFrame(_:timestamp:) -> Bool`, `createSampleBuffer(from:timestamp:)`, `FrameManifestWriter.Status` (`delivered`/`droppedBuffer`/`droppedQueue` → `delivered`/`dropped_buffer`/`dropped_queue`) are used identically across Tasks 2, 9, 10, 12. ✓

**Placeholder scan:** no TBD/“handle errors”/“similar to”; every code step shows complete code. ✓

**Known follow-ups (out of scope, intentionally):** stream-side drop policy assumes a live virtual camera (drop-oldest); if a downstream consumer ever needs gapless capture, lower the capture frame rate to a sustainable value instead (discussed in design). Camera-vs-host clock domain reconciliation for multi-camera PTP sync is recorded in the manifest (`camera_timestamp_ns`) but not yet used for alignment.
