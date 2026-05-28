# Sink-Streaming Rebuild Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Restore reliable MRC-camera → virtual-camera → browser streaming by rebuilding the CMIO transport seam to the canonical reference model: a self-re-arming sink consume loop, a single-producer source timeline, and a deterministic sink connect — deleting the producer-model handshake, stall watchdog, dead-sink recovery, and forced-rediscovery machinery.

**Architecture:** One CMIO device with a `.source` stream (browser reads) and a `.sink` stream (app writes). The app captures from the MRC continuously and pushes every frame to the sink; the extension consumes the sink with an immediately-re-arming loop and forwards to the source only when a consumer is attached. Reliability comes from correctness (monotonic PTS, unconditional re-arm, deterministic connect), not from supervisors.

**Tech Stack:** Swift, SwiftUI, CoreMediaIO (`CMIOExtension*` in the extension; `CMIO*` C API in the app), Aravis (via `AravisBridge` Obj-C++), `FramePipelineKit` (local SwiftPM package), Xcode project `GigEVirtualCamera.xcodeproj`.

---

## Conventions used in every task

**Build command (app + embedded extension), run from repo root:**
```bash
xcodebuild -project GigEVirtualCamera.xcodeproj -scheme GigEVirtualCamera -configuration Debug build 2>&1 | tail -20
```
Expected: ends with `** BUILD SUCCEEDED **`.

**Unit tests (pure logic only):**
```bash
cd FramePipelineKit && swift test 2>&1 | tail -20; cd ..
```
Expected: ends with a passing summary, e.g. `Test Suite 'All tests' passed`.

**Do NOT run `xcodegen` or `Scripts/create_xcodeproj.sh`** — they break the manual provisioning settings (per CLAUDE.md). Always build the existing `.xcodeproj`.

**Why this code is verified by build + smoke test + manual checkpoints, not unit TDD:** the changed behavior is CMIO/hardware integration (cross-process stream lifecycle, a real camera, a browser consumer). There is no in-process way to unit-test "the browser keeps rendering." The pure logic that *can* be unit-tested (monotonic host clock, timestamps) already lives in `FramePipelineKit` with tests, which we keep green. Integration is proven on the verification ladder in Task 9.

**Branch:** all work happens on `fix/sink-streaming-rebuild` (already created; the design spec is committed there).

---

## File structure

| File | Responsibility | Change |
|------|----------------|--------|
| `GigEVirtualCameraExtension/GigEVirtualCameraExtensionProvider.swift` | CMIO extension: device, source stream, sink stream, consume loop | Modify (sink loop rewrite, source tighten, delete handshake) |
| `GigECameraApp/CMIOFrameSender.swift` | App→sink connector: discover device, connect sink, enqueue frames | Modify (deterministic connect loop, delete forced-rediscovery) |
| `GigECameraApp/CameraManager.swift` | App orchestration: camera lifecycle, capture→push wiring, callbacks | Modify (delete watchdog, handshake monitor, dead-sink recovery; one reconnect path) |
| `GigECameraApp/NetworkInterfaceMonitor.swift` | Network-change → camera discovery | Modify (remove stream/sink reconnect reactions; keep camera-list discovery) |
| `Scripts/test_direct_sink_connection.swift` | Standalone sink reachability probe | Run only (no edit) |

---

## Task 1: Baseline — confirm the branch builds and unit tests pass

**Files:** none (verification only)

- [ ] **Step 1: Confirm branch**

Run:
```bash
git -C /Users/lukechang/Github/hyperstudy-gige branch --show-current
```
Expected: `fix/sink-streaming-rebuild`

- [ ] **Step 2: Build the current state**

Run the Build command (see Conventions).
Expected: `** BUILD SUCCEEDED **`. If it fails, STOP and report — the rebuild must start from a building baseline.

- [ ] **Step 3: Run FramePipelineKit unit tests**

Run the Unit tests command.
Expected: all tests pass. These cover `MonotonicHostClock`, `FrameTimestamp`, etc. — the pure logic we keep.

- [ ] **Step 4: No commit** (verification only). Proceed to Task 2.

---

## Task 2: Extension — self-re-arming sink consume loop

Replace the fixed-30 fps poll + consecutive-error teardown with the reference's immediate, unconditional re-arm. The loop must stop ONLY when `stopStream()` clears the subscribing flag.

**Files:**
- Modify: `GigEVirtualCameraExtension/GigEVirtualCameraExtensionProvider.swift` (`SinkStreamSource.consumeNextBuffer`, `scheduleConsumeNextBuffer`, and the error-budget fields)

- [ ] **Step 1: Replace `consumeNextBuffer()` and `scheduleConsumeNextBuffer(after:)`**

Find the existing `private func scheduleConsumeNextBuffer(after delay: TimeInterval)` and `private func consumeNextBuffer()` (currently around lines 249–333) and replace BOTH with:

```swift
    /// Re-arms the consume loop on the consumer queue. `cushionMs` adds a small
    /// delay ONLY when the last read produced no buffer (empty queue or transient
    /// error), preventing a hot spin without imposing a fixed frame-rate cap. On
    /// the success path it re-arms immediately so the loop paces itself to the
    /// camera's true delivery rate — the key fix for MRC lag/jitter.
    private func rearmConsume(cushionMs: Int) {
        guard isStillSubscribing() else { return }
        if cushionMs <= 0 {
            consumerQueue.async { [weak self] in self?.consumeNextBuffer() }
        } else {
            consumerQueue.asyncAfter(deadline: .now() + .milliseconds(cushionMs)) { [weak self] in
                self?.consumeNextBuffer()
            }
        }
    }

    private func consumeNextBuffer() {
        guard isStillSubscribing(), let client = self.client else { return }

        stream.consumeSampleBuffer(from: client) { [weak self] (sampleBuffer, sequenceNumber, _, _, error) in
            guard let self = self else { return }
            guard self.isStillSubscribing() else { return }

            if let sampleBuffer = sampleBuffer {
                if !self.hasLoggedFirstFrame {
                    self.hasLoggedFirstFrame = true
                    SharedExtensionLog.shared.write(level: .notice, category: "Ext.SinkStream",
                        message: "🎉 First frame consumed from sink")
                }
                // Sample the cadence to the shared log ~every 10s at 30fps.
                if sequenceNumber > 0 && sequenceNumber % 300 == 0 {
                    SharedExtensionLog.shared.write(level: .info, category: "Ext.SinkStream",
                        message: "Sink consumed frame #\(sequenceNumber)")
                }
                // Forward to the source stream (the device source's bridge
                // closure decides, via consumer presence, whether send happens).
                self.consumeSampleBuffer?(sampleBuffer)
                // Success → re-arm immediately; self-pacing to delivery rate.
                self.rearmConsume(cushionMs: 0)
                return
            }

            if let error = error {
                // Transient (queue momentarily empty, client busy). DO NOT tear
                // down — the reference never gives up here. Just re-arm after a
                // small cushion so a burst of errors can't hot-spin the queue.
                // The loop ends only when stopStream() flips the subscribing flag.
                SharedExtensionLog.shared.write(level: .info, category: "Ext.SinkStream",
                    message: "consumeSampleBuffer transient (re-arming): \(error.localizedDescription)")
                self.rearmConsume(cushionMs: 20)
                return
            }

            // No buffer, no error → queue empty. Re-arm with a small cushion.
            self.rearmConsume(cushionMs: 5)
        }
    }
```

- [ ] **Step 2: Update `subscribe()` to call the renamed re-arm**

In `subscribe()` (currently ends with `scheduleConsumeNextBuffer(after: 0)` around line 243), change that final line to:

```swift
        // Start consuming buffers — re-arms itself until stopStream().
        rearmConsume(cushionMs: 0)
```

- [ ] **Step 3: Delete the now-unused error-budget fields**

Remove these two declarations (currently around lines 197–198):

```swift
    private var consecutiveErrorCount = 0
    private static let maxConsecutiveErrors = 8
```

Also remove any remaining references to `consecutiveErrorCount` / `maxConsecutiveErrors` (the old `consumeNextBuffer` body referenced them; the Step 1 replacement removed those usages). Keep `isSubscribing`, `subscribeLock`, `consumerQueue`, `hasLoggedFirstFrame`, `setSubscribing`, `isStillSubscribing` — all still used.

- [ ] **Step 4: Verify the error-budget symbols are gone**

Run:
```bash
grep -n "consecutiveErrorCount\|maxConsecutiveErrors\|scheduleConsumeNextBuffer\|setSubscribing(false)" GigEVirtualCameraExtension/GigEVirtualCameraExtensionProvider.swift
```
Expected: the only `setSubscribing(false)` match is in `stopStream()` (line ~173). No matches for `consecutiveErrorCount`, `maxConsecutiveErrors`, or `scheduleConsumeNextBuffer`.

- [ ] **Step 5: Build**

Run the Build command. Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 6: Commit**

```bash
git add GigEVirtualCameraExtension/GigEVirtualCameraExtensionProvider.swift
git commit -m "fix(extension): self-re-arming sink consume loop; drop error-budget teardown"
```

---

## Task 3: Extension — single-producer source timeline (idle path silent when real frames flow)

The source already uses a 2-second idle watchdog (not a 30 Hz generator) plus a monotonic clamp. This task makes the "one producer at a time" property explicit and keeps the clamp as a documented safety net.

**Files:**
- Modify: `GigEVirtualCameraExtension/GigEVirtualCameraExtensionProvider.swift` (`SourceStreamSource.sendSampleBuffer`, `startNoFrameWatchdog`)

- [ ] **Step 1: Confirm the idle watchdog already self-suppresses on real frames**

Read `startNoFrameWatchdog()` (around lines 652–670). Confirm it computes `isStale` from `lastRealFrameUptimeNs` under `sendLock` and only calls `sendDefaultFrame()` when stale. This is the single-producer guard — the idle frame is emitted only when no real frame arrived in the last 2 s. No change needed if this matches.

- [ ] **Step 2: Tighten the idle interval so a fresh consumer isn't black for up to 2 s**

In `startNoFrameWatchdog()`, the timer interval is `0.5` and `noFrameTimeoutNs` is `2_000_000_000`. Leave the 2 s staleness threshold (it defines "no real frames"), but ensure the FIRST idle frame after the source starts is covered by the existing one-shot bootstrap in `SourceStreamSource.startStream()` (the `frameQueue.async { ... sendDefaultFrame() }` block around lines 503–516). Confirm that bootstrap still exists and is marked `isDefault: true`. No code change if present; if the bootstrap block was removed in a prior edit, re-add it exactly:

```swift
        frameQueue.async { [weak self] in
            guard let self = self else { return }
            let bootstrap = self.lastReceivedFrame
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                if let bootstrap = bootstrap {
                    self.sendSampleBuffer(bootstrap, isDefault: true)
                } else {
                    self.sendDefaultFrame()
                }
            }
        }
```

- [ ] **Step 3: Add a clarifying comment to the monotonic clamp (no behavior change)**

In `sendSampleBuffer(_:isDefault:)`, just above the `os_unfair_lock_lock(&sendLock)` (around line 566), add:

```swift
        // Single-producer invariant: while real frames flow, the idle watchdog
        // stays silent (it self-suppresses on fresh lastRealFrameUptimeNs), so
        // this clamp is a safety net over an already-monotonic timeline rather
        // than an arbiter between racing producers. Browsers freeze on a
        // non-monotonic hostTime, so the clamp stays as belt-and-suspenders.
```

- [ ] **Step 4: Build**

Run the Build command. Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 5: Commit**

```bash
git add GigEVirtualCameraExtension/GigEVirtualCameraExtensionProvider.swift
git commit -m "docs(extension): document single-producer source timeline + clamp role"
```

---

## Task 4: Extension — delete the `StreamState` app-group handshake

The app no longer waits on the extension (continuous capture). Remove the extension's side of the bidirectional handshake.

**Files:**
- Modify: `GigEVirtualCameraExtension/GigEVirtualCameraExtensionProvider.swift` (`StreamStateCoordinator` class, its field, and `signalNeedFrames`/`signalStreamStopped`/`newClientConnected` calls)

- [ ] **Step 1: Remove the handshake writes in `startStreaming()`**

In `GigEVirtualCameraExtensionDeviceSource.startStreaming()` (around lines 872–899), delete the `shouldSignalNeedFrames` computation and the `if shouldSignalNeedFrames { ... streamStateCoordinator.signalNeedFrames() } else if ...` block. Keep the `_streamingCounter += 1` and the logging. Result:

```swift
    func startStreaming() {
        os_unfair_lock_lock(&stateLock)
        _streamingCounter += 1
        let counter = _streamingCounter
        let sinking = _isSinking
        os_unfair_lock_unlock(&stateLock)

        logger.info("🎬 Source stream started. Client count: \(counter), sink: \(sinking)")
        SharedExtensionLog.shared.write(level: .info, category: "Ext.Device",
            message: "🎬 Source stream started (clients: \(counter), sink active: \(sinking))")
    }
```

- [ ] **Step 2: Remove the handshake writes in `stopStreaming()`**

In `stopStreaming()` (around lines 902–920), delete the `shouldSignalStopped` computation and the `if shouldSignalStopped { ... streamStateCoordinator.signalStreamStopped() }` block. Keep the counter decrement and logging. Result:

```swift
    func stopStreaming() {
        os_unfair_lock_lock(&stateLock)
        if _streamingCounter > 0 {
            _streamingCounter -= 1
        }
        let counter = _streamingCounter
        os_unfair_lock_unlock(&stateLock)

        logger.info("Source stream stopped. Client count: \(counter)")
        SharedExtensionLog.shared.write(level: .info, category: "Ext.Device",
            message: "Source stream stopped (clients remaining: \(counter))")
    }
```

- [ ] **Step 3: Remove the `newClientConnected` write in `SourceStreamSource.startStream()`**

In `SourceStreamSource.startStream()` (around lines 466–479), delete the entire `if let groupDefaults = UserDefaults(suiteName: ...) { ... groupDefaults.synchronize() }` block that writes `Debug_SourceStreamStarted`, `newClientConnected`, and `clientConnectedTime`. Keep the surrounding `NSLog`/`logger`/watchdog/bootstrap logic.

- [ ] **Step 4: Remove the coordinator field and class**

Delete the field (around line 770):
```swift
    private let streamStateCoordinator = StreamStateCoordinator()
```
Then delete the entire `StreamStateCoordinator` class (the block beginning `class StreamStateCoordinator {` near the top of the file, lines ~26 onward, through its closing brace).

- [ ] **Step 5: Verify the handshake is gone**

Run:
```bash
grep -n "StreamStateCoordinator\|signalNeedFrames\|signalStreamStopped\|newClientConnected\|streamStateCoordinator" GigEVirtualCameraExtension/GigEVirtualCameraExtensionProvider.swift
```
Expected: no matches.

- [ ] **Step 6: Build**

Run the Build command. Expected: `** BUILD SUCCEEDED **`. (If the build complains about an unused `StreamStateMutation` import in the extension, leave `FramePipelineKit` imports as-is — the app still uses them.)

- [ ] **Step 7: Commit**

```bash
git add GigEVirtualCameraExtension/GigEVirtualCameraExtensionProvider.swift
git commit -m "fix(extension): delete StreamState app-group handshake"
```

---

## Task 5: App — deterministic sink connect loop in `CMIOFrameSender`

Replace the fragile one-shot-at-launch + listener-only connect with a connect that actively polls discovery until connected, then stops. Delete `forceRediscovery` and the listener-only dead end.

**Files:**
- Modify: `GigECameraApp/CMIOFrameSender.swift` (`connect()`, `forceRediscovery()`, add poll timer; `connectToSinkStream` success path)

- [ ] **Step 1: Add a connect-poll timer field**

In `CMIOSinkConnector`, near the other timer fields (after `private var connectionRetryTimer: Timer?` around line 193), add:

```swift
    // Drives initial connection: polls discovery every second until the sink
    // is connected, then stops. This is connection-establishment correctness,
    // NOT a recovery watchdog — once connected it never polls again. Replaces
    // the previous one-shot-at-launch + property-listener-only path that sat
    // silent forever if it missed the initial CMIO change event.
    private var connectPollTimer: Timer?
    private var connectPollAttempts = 0
```

- [ ] **Step 2: Replace `connect()` and `forceRediscovery()`**

Replace the existing `func connect() -> Bool { ... }` and `func forceRediscovery() { ... }` (lines ~280–314) with:

```swift
    @discardableResult
    func connect() -> Bool {
        if isConnected { return true }
        if propertyListener == nil { setupPropertyListener() }

        // If we already have discovered IDs, connect now.
        if let streamID = sinkStreamID, let deviceID = deviceID,
           connectToSinkStream(streamID: streamID, deviceID: deviceID) {
            return true
        }

        // Otherwise actively discover+connect, and keep polling until we do.
        tryManualDiscovery()
        if isConnected { return true }
        startConnectPolling()
        return false
    }

    private func startConnectPolling() {
        guard connectPollTimer == nil else { return }
        connectPollAttempts = 0
        connectPollTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            if self.isConnected { self.stopConnectPolling(); return }
            self.connectPollAttempts += 1
            // After 10 quick attempts, the device almost certainly isn't there
            // (extension not installed/approved). Keep trying, but slower, and
            // surface a clear, actionable log line — not a silent dead end.
            if self.connectPollAttempts == 10 {
                self.logger.error("Virtual camera device not found after 10s — is the extension installed and approved in System Settings?")
            }
            if self.connectPollAttempts > 10 && self.connectPollAttempts % 5 != 0 {
                return  // throttle to once every 5s past the first 10 attempts
            }
            self.tryManualDiscovery()
            if self.isConnected { self.stopConnectPolling() }
        }
    }

    private func stopConnectPolling() {
        connectPollTimer?.invalidate()
        connectPollTimer = nil
    }
```

- [ ] **Step 3: Stop polling on successful connect**

In `connectToSinkStream(streamID:deviceID:)`, immediately after `isConnected = true` (around line 360), add:

```swift
        stopConnectPolling()
```

- [ ] **Step 4: Clean up the poll timer in `deinit` and `handleDisconnection`**

In `deinit` (around line 212), add `connectPollTimer?.invalidate()` alongside the other invalidations.
In `handleDisconnection()` (around line 394), after `self.isConnected = false`, the connector is intentionally left disconnected; do NOT auto-restart polling here (the single reconnect path lives in `CameraManager`, Task 7). Leave `handleDisconnection` otherwise as-is.

- [ ] **Step 5: Verify `forceRediscovery` is gone**

Run:
```bash
grep -n "forceRediscovery" GigECameraApp/CMIOFrameSender.swift
```
Expected: no matches.

- [ ] **Step 6: Build**

Run the Build command. Expected: `** BUILD SUCCEEDED **`. It will likely FAIL to compile `CameraManager.swift` because it still calls `sinkConnector.forceRediscovery()` — that is expected and fixed in Task 6/7. If the ONLY errors are "value of type 'CMIOSinkConnector' has no member 'forceRediscovery'" in `CameraManager.swift`, proceed; otherwise fix the unexpected error.

- [ ] **Step 7: Commit**

```bash
git add GigECameraApp/CMIOFrameSender.swift
git commit -m "fix(app): deterministic sink connect-poll; remove forceRediscovery"
```

---

## Task 6: App — delete the stall watchdog and dead-sink recovery from `CameraManager`

**Files:**
- Modify: `GigECameraApp/CameraManager.swift` (`startStreamStallWatchdog`, `tickStreamStallWatchdog`, watchdog state fields, `noteDisruption`, the `streamStallWatchdog` timer)

- [ ] **Step 1: Delete the watchdog methods**

Delete `private func startStreamStallWatchdog()` (around line 1032) and `private func tickStreamStallWatchdog()` (around line 1044) in their entirety, including the doc comment block starting at "// MARK: - Stream Stall Watchdog" (around line 1022).

- [ ] **Step 2: Delete the call that starts the watchdog**

In `setupFrameHandler()` (around line 925), delete:
```swift
        // Start the stream-stall watchdog. ...
        startStreamStallWatchdog()
```
(Remove the call and its preceding comment lines.)

- [ ] **Step 3: Delete `noteDisruption` and disruption-grace state**

Find and delete `noteDisruption` (search for `func noteDisruption`) and the now-unused watchdog/disruption state fields. Run this to enumerate them first:
```bash
grep -n "streamStallWatchdog\|sinkDeadSinceUptimeNs\|lastPipelineDisruptionUptimeNs\|pipelineGraceSec\|sinkDeadThresholdSec\|sinkRecoveryCooldownSec\|lastSinkRecoveryAttemptUptimeNs\|streamStallTimeoutSec\|lastSinkAvailabilityState\|lastSinkConnectedState\|noteDisruption" GigECameraApp/CameraManager.swift
```
Delete each field declaration and any remaining references EXCEPT the two `@Published` UI properties handled in Step 4. For references inside `setupSinkConnectorCallbacks` (the `noteDisruption("...")` lines and the `lastSink*State` flip checks), remove those lines — the callbacks are simplified in Task 7.

- [ ] **Step 4: Keep the UI-facing properties, but make them inert**

`streamStalled`, `streamStallDurationSec`, and `ptsNudgeCount` are `@Published` and may be read by `ContentView`. To avoid touching the UI in this task:
- Keep their declarations.
- `streamStalled` stays `false` and `streamStallDurationSec` stays `0` (nothing sets them now).
- Keep `ptsNudgeCount` updated as a pure diagnostic: add a lightweight timer OR fold it into an existing periodic update. Simplest: in `setupFrameHandler()`, replace the deleted watchdog start with a 1 Hz diagnostics refresh:

```swift
        // Lightweight diagnostics refresh (no recovery logic). Surfaces the
        // PTS-nudge tripwire to the UI; a nonzero value signals a real upstream
        // monotonicity bug worth investigating, not something to auto-"recover".
        diagnosticsRefreshTimer?.invalidate()
        diagnosticsRefreshTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            DispatchQueue.main.async { self?.ptsNudgeCount = self?.sinkConnector.nonMonotonicNudges ?? 0 }
        }
```

Add the field near the other timers:
```swift
    private var diagnosticsRefreshTimer: Timer?
```
And invalidate it wherever other timers are torn down (search for an existing `deinit` or a stop/cleanup method in `CameraManager`; add `diagnosticsRefreshTimer?.invalidate()` there).

- [ ] **Step 5: Verify watchdog/recovery symbols are gone**

Run:
```bash
grep -n "startStreamStallWatchdog\|tickStreamStallWatchdog\|noteDisruption\|sinkDeadSinceUptimeNs\|forceRediscovery\|sinkConnector.disconnect()" GigECameraApp/CameraManager.swift
```
Expected: no matches for `startStreamStallWatchdog`, `tickStreamStallWatchdog`, `noteDisruption`, `sinkDeadSinceUptimeNs`, or `forceRediscovery`. The only acceptable `sinkConnector.disconnect()` match is inside the single reconnect path created in Task 7 (none yet at this step — so zero matches now).

- [ ] **Step 6: Build**

Run the Build command. Expected: `** BUILD SUCCEEDED **` (Task 5's `forceRediscovery` compile error is now resolved). If references to deleted fields remain, fix them by deleting the referencing lines.

- [ ] **Step 7: Commit**

```bash
git add GigECameraApp/CameraManager.swift
git commit -m "fix(app): delete stall watchdog + dead-sink recovery; keep PTS tripwire"
```

---

## Task 7: App — continuous capture→push, simplified callbacks, one reconnect path

Remove the producer-model handshake (`StreamStateMonitor`/`StreamStateChanged`) and collapse reconnect to a single deterministic method. Capture is continuous; every frame is pushed.

**Files:**
- Modify: `GigECameraApp/CMIOFrameSender.swift` (`StreamStateMonitor` usage), `GigECameraApp/CameraManager.swift` (callbacks, `StreamStateChanged` observer, reconnect)

- [ ] **Step 1: Confirm the capture→push wiring already pushes unconditionally**

Read `setupFrameHandler()` in `CameraManager.swift` (around line 908). Confirm:
```swift
        gigEManager.onStreamFrame = { frame in
            return connector.sendFrame(frame.pixelBuffer, timestamp: frame.timestamp)
        }
```
This is the continuous capture→push path and needs NO change — `sendFrame` self-guards on connection state. Leave it.

- [ ] **Step 2: Simplify `setupSinkConnectorCallbacks()`**

Replace the body of `setupSinkConnectorCallbacks()` (around lines 971–1020) with the minimal version — no `noteDisruption`, no availability-flip bookkeeping:

```swift
    private func setupSinkConnectorCallbacks() {
        sinkConnector.onConnectionStateChanged = { [weak self] connected in
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.isFrameSenderConnected = connected
                if connected {
                    self.logger.info("✅ Sink connector connected")
                    // Camera capture is continuous; if the camera is connected
                    // but not yet streaming, start it now.
                    if self.isConnected && !GigECameraManager.shared.isStreaming {
                        GigECameraManager.shared.startStreaming()
                    }
                } else {
                    self.logger.warning("⚠️ Sink connector disconnected")
                }
            }
        }
        // onSinkStreamAvailable is no longer used to drive streaming; leave it unset.
    }
```

- [ ] **Step 3: Remove the `StreamStateMonitor` from the app**

In `CMIOFrameSender.swift`, the `StreamStateMonitor` class and `streamStateMonitor` property drove the old handshake. Remove them:
- Delete the `private let streamStateMonitor = StreamStateMonitor()` field (around line 183).
- Delete the `startStreamStateMonitoring()` method (around line 736) and its call in `connectToSinkStream` (the `startStreamStateMonitoring()` line around 368).
- Delete the `streamStateMonitor.stopMonitoring()` calls in `deinit` and `handleDisconnection`.
- Delete the entire `class StreamStateMonitor { ... }` (top of file, lines ~18–73).

- [ ] **Step 4: Remove the `StreamStateChanged` observer in `CameraManager`**

Run:
```bash
grep -n "StreamStateChanged\|StreamStateMonitor\|startStreamStateMonitoring\|newClientConnected\|producer model" GigECameraApp/CameraManager.swift
```
Delete the `NotificationCenter` observer registration for `StreamStateChanged` and any handler that reacts to it (including the "Auto-starting streaming on state change (producer model)" path and the "New client connected but sink not ready - reconnecting sink first" block around lines 638–715). Camera capture is continuous and starts on connect (Step 2), so these reactive auto-starts are removed.

- [ ] **Step 5: Add the single reconnect path**

Add one method to `CameraManager` (place near `setupFrameHandler`). This is the ONLY place that tears down and re-establishes the sink, used for in-app lifecycle events (camera switch, user stop/start):

```swift
    /// The single deterministic sink reconnect path. Used for in-app lifecycle
    /// events (camera switch, stop/start). No watchdog calls this — it is invoked
    /// only from explicit user/lifecycle actions. Order matters: stop capture,
    /// release the sink, then reconnect.
    func reconnectSink() {
        logger.info("Reconnecting sink (deterministic path)")
        if GigECameraManager.shared.isStreaming {
            GigECameraManager.shared.stopStreaming()
        }
        sinkConnector.disconnect()
        _ = sinkConnector.connect()  // connect() polls until the device is reachable
    }
```

- [ ] **Step 6: Route existing reconnect call sites through `reconnectSink()`**

Find call sites that previously did ad-hoc `sinkConnector.disconnect()` + `connect()`/`forceRediscovery()` (e.g., the camera-switch path, the "Retry CMIO Sink" button handler). Run:
```bash
grep -n "sinkConnector.connect()\|sinkConnector.disconnect()\|retryFrameSenderConnection" GigECameraApp/CameraManager.swift
```
Replace each ad-hoc disconnect+connect pair with a single `reconnectSink()` call. Keep the initial connect in `setupFrameHandler()` as a plain `sinkConnector.connect()` (first connection, not a reconnect).

- [ ] **Step 7: Verify handshake + ad-hoc reconnect removed**

Run:
```bash
grep -n "StreamStateMonitor\|StreamStateChanged\|startStreamStateMonitoring" GigECameraApp/CMIOFrameSender.swift GigECameraApp/CameraManager.swift
```
Expected: no matches.

- [ ] **Step 8: Build**

Run the Build command. Expected: `** BUILD SUCCEEDED **`. Fix any dangling references to removed symbols by deleting those lines.

- [ ] **Step 9: Commit**

```bash
git add GigECameraApp/CMIOFrameSender.swift GigECameraApp/CameraManager.swift
git commit -m "fix(app): continuous capture+push; drop handshake; single reconnect path"
```

---

## Task 8: App — stop network-change stream reconnects; make control errors non-fatal

**Files:**
- Modify: `GigECameraApp/CameraManager.swift` (network-change handler, camera-control writes), `GigECameraApp/NetworkInterfaceMonitor.swift` (no behavioral change expected; verify it only emits a signal)

- [ ] **Step 1: Verify the network monitor only signals (no stream teardown inside it)**

Run:
```bash
grep -n "onNetworkChange\|configuration changed\|sink\|stream\|connect\|discover" GigECameraApp/NetworkInterfaceMonitor.swift
```
Expected: the monitor only detects changes and invokes a callback; it should NOT call sink/stream/connect APIs directly. If it does, remove those calls — its only job is to notify `CameraManager`.

- [ ] **Step 2: Scope the network-change reaction to camera-list discovery only**

In `CameraManager`, find the network-change handler (search `Network change`). Keep ONLY camera-list discovery when NOT streaming; remove any sink reconnect / stream restart reaction. Confirm the existing guard "Network change while streaming - skipping discovery broadcast" remains, and that no `reconnectSink()`/`sinkConnector` call exists in this handler.

Run:
```bash
grep -n "Network change" GigECameraApp/CameraManager.swift
```
Expected: the handler triggers camera discovery only when idle; no sink/stream calls.

- [ ] **Step 3: Make MRC control-write failures non-fatal**

Find the camera-control write paths (search for the diagnostic strings). Run:
```bash
grep -n "control not available\|out-of-range exposure\|ignored the write\|Failed to set camera resolution\|Updated exposure\|Updated gain\|Updated frame rate" GigECameraApp/CameraManager.swift
```
For each control write (exposure, gain, fps, resolution): ensure a failure path **logs and returns/continues** and never calls `stopStreaming()`, `disconnect()`, `reconnectSink()`, or throws out of the capture path. If any control-failure branch currently tears down streaming or the sink, replace that teardown with a `logger.warning(...)` + `return`. The frame path must be independent of control success.

- [ ] **Step 4: Build**

Run the Build command. Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 5: Commit**

```bash
git add GigECameraApp/CameraManager.swift GigECameraApp/NetworkInterfaceMonitor.swift
git commit -m "fix(app): network changes don't touch the stream; control errors non-fatal"
```

---

## Task 9: Integration verification ladder

This is where end-to-end behavior is proven. Steps 3–5 require hardware/a human and are **run by the user**; the agent prepares the build and waits for results.

**Files:** none (verification)

- [ ] **Step 1: Full build + reinstall the extension**

Run the Build command (expect `** BUILD SUCCEEDED **`), then install and reinstall the extension:
```bash
./Scripts/install_app.sh
./Scripts/clean_reinstall_extension.sh
```
Expected: app installed to `/Applications`; extension reinstalled. Approve in System Settings if prompted.

- [ ] **Step 2: Sink smoke test (isolation probe)**

With the extension installed, run:
```bash
swift Scripts/test_direct_sink_connection.swift
```
Expected: it finds the virtual camera device, lists its streams, identifies the sink stream, and connects without app orchestration. This proves the sink is reachable. If it fails here, the extension (not the app) is the problem — investigate the extension before proceeding.

- [ ] **Step 3: Fake-camera integration (USER-RUN checkpoint)**

Launch the app, select "Test Camera (Aravis Simulator)", Connect + Start Streaming. Open Photo Booth or QuickTime → New Movie Recording → select "GigE Virtual Camera".
Expected: steady video for several minutes with no freeze/black; open and close the consumer (Photo Booth) 3+ times and confirm it re-renders cleanly each time. Export the diagnostics and confirm `sinkConnected: true`, `ptsNudgeCount: 0`, and no "Cannot send frame - not connected to sink".

- [ ] **Step 4: MRC acceptance test (USER-RUN checkpoint — the real bar)**

Connect the MRC GVRD-MRC camera. In the app, select it, Connect + Start Streaming. Open HyperStudy in a browser and select "GigE Virtual Camera" as the experiment camera.
Expected: live, stable video for a full session with no black-out; an in-app disconnect/reconnect (or camera switch) recovers cleanly via `reconnectSink()`. Export diagnostics; confirm `sinkConnected: true`, `ptsNudgeCount: 0`, and a session-average fps consistent with what the MRC actually delivers.

- [ ] **Step 5: Review diagnostics together**

Share the exported diagnostics JSON. Confirm: no stall/dead-sink log lines (those code paths are gone), no handshake churn, monotonic timestamps (no nudges), continuous frame delivery. If any anomaly appears, return to systematic-debugging with this evidence — do NOT reintroduce recovery machinery.

- [ ] **Step 6: Finalize**

Once Steps 3–5 pass, the branch is ready for review/merge per the `superpowers:finishing-a-development-branch` skill. Do not merge without the user's explicit go-ahead.

---

## Self-review notes (coverage check)

- Spec §5 invariant 1 (re-arm) → Task 2. Invariant 2 (single producer) → Task 3. Invariant 3 (connect-once + push) → Tasks 5 & 7.
- Spec §6.1 (extension) → Tasks 2–4. §6.2 (`CMIOFrameSender`) → Tasks 5 & 7. §6.3 (`CameraManager`) → Tasks 6, 7, 8.
- Spec §7/§8 deletions → Tasks 4, 6, 7, 8. §9 keeps (UI, diagnostics, Aravis, FramePipelineKit) → untouched; `ptsNudgeCount` tripwire preserved in Task 6 Step 4.
- Spec §10 verification ladder → Task 9.
- Spec §11 non-goals: continuous capture (Task 7 Step 1), no network-disconnect recovery (Task 8), UI unchanged.
