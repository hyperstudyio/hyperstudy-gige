# Sink-Streaming Rebuild — Design Spec

**Date:** 2026-05-28
**Status:** Approved (design); pending implementation plan
**Author:** Luke Chang (with Claude Code)

## 1. Purpose

Restore reliable virtual-camera streaming by rebuilding the **frame-transport seam** to match the canonical CMIO camera-extension reference model. The current pipeline (post "Preview/stream performance overhaul" refactor) fails to deliver frames to the virtual camera at all; the previous working version had its own reliability bug (lag → black → no recovery without restart). This rebuild earns reliability through **correctness**, not through recovery scaffolding.

### Real-world target

The app's primary job is to bridge the **MRI-compatible MRC camera (MRC Systems GmbH GVRD-MRC MR-CAM-HR)** into the **HyperStudy web experiment platform**. The acceptance bar is: MRC camera → app → "GigE Virtual Camera" → **HyperStudy in a browser**, live and stable for a full session.

Two facts from this deployment shape every decision:
- **The consumer is a web browser** (getUserMedia/WebRTC). Browsers are the strictest CMIO consumers: they freeze permanently on a non-monotonic presentation timestamp (PTS) or an unexpected pixel format, and they do not self-recover. Monotonic timestamps and a stable output format are therefore the primary correctness requirements.
- **The MRC is a quirky source.** Diagnostics show it ignoring exposure writes, intermittently reporting "control not available" for exposure/gain/frame-rate, and capping measured fps below the requested rate. The pipeline must pass through whatever the camera actually delivers with correct per-frame capture timestamps (never assume a fixed 25/30 fps), and control-setting quirks must never wedge the frame path.

## 2. Background: why it broke

- Last-known-good baseline: commit `8c85b09` ("finally got video stream working!"). Worked, but had a lag → black → no-recovery bug.
- Regression introduced during the refactor starting at `4803e7b` ("Preview/stream performance overhaul"), followed by a long tail of `fix(reliability)` / `fix(diagnostics)` commits adding recovery machinery.
- The 1.1.15 diagnostics show the failure is **"sink never connects"** (`sinkConnected: false`; every frame hits "Cannot send frame - not connected to sink"), **not** a mid-stream stall — the stall watchdog and dead-sink recovery never even fire.
- The sink-connection code in `CMIOFrameSender.swift` is **byte-for-byte unchanged** from the working baseline. The regression is in the surrounding orchestration/timing: a racy bidirectional "producer model" handshake (extension writes `StreamState` to app-group `UserDefaults`; app waits on it), a new `NetworkInterfaceMonitor` causing reconnect churn, and many new `disconnect()+forceRediscovery()` call sites. Connect remained a fragile one-shot-at-launch + event-listener with no robust retry until connected.
- Divergence from baseline: +4,822 / −1,457 lines. `CameraManager` grew ~1,515 lines; the extension provider ~749.

## 3. The reference model

Canonical pattern (Apple WWDC22 "Create camera extensions with Core Media IO"; `ldenoue/cameraextension`). One CMIO device exposes two streams:
- **Source stream** (`direction: .source`) — what consumers (the browser) read from.
- **Sink stream** (`direction: .sink`) — what the app writes into.

The extension's heart is a self-perpetuating consume loop:

```
app → CMSimpleQueueEnqueue → [sink] → consumeSampleBuffer(from: client) { buf in
                                          if consumerAttached { source.send(buf) }  // forward
                                          self.consume(client)                       // RE-ARM (heartbeat)
                                       }
                                       → [source] → consumer (browser)
```

The reference is ~480 (extension) + ~500 (app) lines with **zero** recovery machinery.

## 4. Target data flow

```
MRC camera ──Aravis──> App ──CMSimpleQueue──> [SINK stream] ──┐
                                                              │ extension forwards
                                                              ▼  ONLY if consumer attached
                                          [SOURCE stream] ──> HyperStudy (browser)
```

The app **captures continuously** whenever connected and pushes every frame to the sink unconditionally. The extension decides whether to forward to the source based on consumer presence. There is **no app↔extension signaling** in v1.

## 5. Core invariants (the reliability contract)

1. **The sink consume loop re-arms unconditionally and immediately.** In the `consumeSampleBuffer` completion handler, forward the buffer (if a consumer is attached), then immediately call the consume function again. No fixed-rate poll, no error-budget teardown. The loop stops only when the sink stream actually stops. Pacing itself to the camera's true delivery rate is what fixes lag/jitter on the MRC.
2. **Exactly one frame producer feeds the source stream at any moment.** When real frames flow, the idle/test-pattern path is silent (reference's `if sinkActive { return }`). One timeline → strictly monotonic host time *by construction*. This is the browser-freeze fix.
3. **The app connects the sink as soon as the device exists and pushes whenever it is capturing.** No handshake gating the connection. The extension forwards to the browser based on `streamingCounter > 0`; the app neither knows nor waits.

## 6. Component changes

### 6.1 Extension — `GigEVirtualCameraExtensionProvider.swift`

Target: shrink from ~1,012 lines toward the reference's ~480.

**Sink stream (consume loop):**
- Replace the fixed-30 fps `scheduleConsumeNextBuffer(after: 0.033)` poll with immediate, unconditional re-arm in the completion handler.
- Delete the consecutive-error budget and the `setSubscribing(false)` self-teardown. On a consume error, just re-arm; the loop ends naturally when `stopStream` clears the "subscribing" flag.
- Keep a lightweight "is the sink still started?" guard at the top of each iteration (reference's `if sinkStarted == false { return }`).
- Forward to the source gated by the existing `streamingCounter > 0` (consumer-attached) check.

**Source stream (single-producer timeline):**
- One emit path. While the sink is forwarding real frames, the idle path is silent, enforced by a `sinkActive` guard.
- Keep a **single minimal idle frame** so a consumer that opens before the camera produces sees a placeholder rather than black — emitted by one timer that suppresses itself the instant real frames arrive (NOT a concurrent 2-second watchdog racing the real path).
- Keep the monotonic host-time clamp (`MonotonicHostClock` logic) as a **diagnostic tripwire / safety net** over an already-correct single timeline — not as the primary mechanism arbitrating three racing producers.

**Device source:**
- Keep the two-stream setup, the hardcoded device/stream UUIDs (they match the app; consumers already see the device), and the YUV420 format.
- Delete the `StreamStateCoordinator` (app-group `StreamState` writer) and the `newClientConnected` notification in source `startStream`.

**Kept as-is:** `SharedExtensionLog` diagnostics writes, format, bundle/entitlement/app-group identity.

### 6.2 App — `CMIOFrameSender.swift`

- Keep the connect *primitive* unchanged: discover device by UID → find `.sink` stream → `CMIOStreamCopyBufferQueue` → `CMIODeviceStartStream` → enqueue.
- **Fix the regression:** replace the fragile one-shot discovery + listener-only path with a **deterministic connect loop** — when streaming starts, actively discover+connect; if the device isn't visible yet (extension still activating), retry on a short interval *until connected, then stop*. This is initial-connection correctness, not a recovery watchdog; once connected it never polls again.
- Delete `forceRediscovery`, the property-listener-only dead-end, and every `disconnect()+forceRediscovery()` call site.
- Keep the monotonic PTS in `createSampleBuffer` (capture-time host ns, strictly increasing) — the send-side browser-freeze defense.
- Keep `PixelBufferConverter` (BGRA→YUV420, scale to HD) and rate-limited diagnostics logging.

### 6.3 App — `CameraManager.swift`

- On connect: start Aravis capture; for every captured frame call `sinkConnector.sendFrame(buffer, timestamp:)`. Continuous capture, unconditional push.
- Delete: `StreamStateMonitor`/`StreamStateChanged` plumbing, the "producer model" auto-start-on-stream-state, the stall watchdog (`streamStalled`/`streamStallDurationSec`), dead-sink recovery, and the `NetworkInterfaceMonitor`-driven discovery/reconnect churn.
- **One reconnect path** for in-scope lifecycle events (camera switch / disconnect / reconnect / stop-start): stop capture → stop & release sink → re-run connect. Single-owner, no racing observers.
- Keep camera discovery/list and MRC control handling, but a control write the MRC rejects **logs and continues** — never blocks or tears down the frame path.

**Kept untouched:** SwiftUI UI / `ContentView`, `DesignSystem`, the diagnostics drawer + `SharedExtensionLog`/app-group log file, `AravisBridge`, signing/entitlements.

## 7. Error handling & lifecycle philosophy

- No watchdogs, no auto-recovery supervisors. Reliability comes from the three invariants holding.
- One deterministic reconnect path for in-scope lifecycle events.
- Control errors: log + skip + keep streaming.
- Genuine external events (network cable pulled): out of scope for v1.
- Monotonic-PTS clamp remains a logged tripwire (`ptsNudgeCount`); a nudge signals a real upstream bug rather than being silently "recovered."

## 8. What is deleted (summary)

- `StreamState` app-group handshake (both sides): `StreamStateCoordinator` (extension), `StreamStateMonitor` + `StreamStateChanged` (app).
- Stall watchdog (`streamStalled`, `streamStallDurationSec`), dead-sink recovery, `forceRediscovery` and its call sites.
- `NetworkInterfaceMonitor`-driven discovery/reconnect churn.
- Extension's 2-second default-frame watchdog as a *second producer*, and the consume-loop consecutive-error teardown.

## 9. What is kept

- SwiftUI UI, `DesignSystem`, diagnostics drawer.
- Diagnostics/logging: `SharedExtensionLog`, app-group log file, diagnostics export.
- `AravisBridge` camera capture.
- Sound `FramePipelineKit` pieces: `MonotonicHostClock`, `FrameTimestamp`, pixel-format conversion, and the existing unit tests.
- Monotonic capture-time PTS on the send side.
- Signing, entitlements, app-group, bundle identity, hardcoded device/stream UUIDs.

## 10. Verification ladder

Each rung must pass before the next:
1. **Unit tests** — existing `FramePipelineKit` tests (`swift test`) green.
2. **Build** — debug build of app + extension succeeds; reinstall extension.
3. **Sink smoke test** — `Scripts/test_direct_sink_connection.swift` against the installed extension proves the sink is reachable with zero app orchestration.
4. **Fake-camera integration** *(user-run checkpoint)* — Aravis simulator → "GigE Virtual Camera" → QuickTime/Photo Booth: steady video, no freeze over several minutes, survives repeated consumer open/close.
5. **MRC acceptance test** *(user-run checkpoint, the real bar)* — MRC GVRD-MRC → virtual camera → HyperStudy in a browser: live and stable for a full session, no black-out, clean recovery after an in-app disconnect/reconnect.

Hardware checkpoints (4–5) are run by the user; the diagnostics export is the shared evidence we review.

## 11. Non-goals (v1)

- Network-cable / physical-disconnect recovery.
- Consumer-presence gating of camera capture (capture is continuous for now).
- UI redesign (the current UI is kept).
- Audio.

## 12. Risks & mitigations

- **Risk:** removing recovery machinery exposes a latent correctness bug. **Mitigation:** the invariants are exactly the corrections for the known failure modes; the monotonic tripwire and diagnostics surface any residual issue.
- **Risk:** MRC delivers at a variable/low rate that interacts badly with consumers. **Mitigation:** consume loop paces to delivery; idle frame covers gaps; PTS reflects true capture time.
- **Risk:** large deletions in `CameraManager` destabilize unrelated features. **Mitigation:** staged implementation plan with build + smoke test between steps; UI and camera-control surfaces kept intact.
