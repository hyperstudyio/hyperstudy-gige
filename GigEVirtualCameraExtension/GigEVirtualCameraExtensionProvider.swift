//
//  GigEVirtualCameraExtensionProvider.swift
//  GigEVirtualCameraExtension
//
//  CMIO Extension with sink/source stream architecture
//

import Foundation
import CoreMediaIO
import IOKit.audio
import os.log

// MARK: - Stream State Coordinator

/// Writes to the shared `StreamState` dict that the app observes.
///
/// The mutation logic is duplicated in `FramePipelineKit/StreamStateMutation.swift`
/// so it can be unit-tested. Keep both in sync if you change one.
///
/// Why merge instead of replace: source.startStream sets
/// `newClientConnected = true`, then immediately calls
/// `deviceSource.startStreaming()` which may call `signalNeedFrames()`. The
/// previous implementation replaced the entire dict in `signalNeedFrames`,
/// erasing `newClientConnected` before the app could observe it. That broke
/// the recovery path the app relies on when its sink is disconnected.
class StreamStateCoordinator {
    private let logger = Logger(subsystem: "com.lukechang.GigEVirtualCamera.Extension", category: "StreamState")
    private let appGroupID = "group.S368GH6KF7.com.lukechang.GigEVirtualCamera"
    static let stateKey = "StreamState"

    private var groupDefaults: UserDefaults? {
        UserDefaults(suiteName: appGroupID)
    }

    func signalNeedFrames() {
        guard let defaults = groupDefaults else {
            logger.error("Failed to access App Group UserDefaults")
            SharedExtensionLog.shared.write(level: .error, category: "Ext.StreamState",
                message: "Failed to access App Group UserDefaults in signalNeedFrames")
            return
        }
        let existing = defaults.dictionary(forKey: Self.stateKey) ?? [:]
        var merged = existing
        merged["streamActive"] = true
        merged["timestamp"] = Date().timeIntervalSince1970
        merged["pid"] = ProcessInfo.processInfo.processIdentifier
        defaults.set(merged, forKey: Self.stateKey)
        defaults.synchronize()

        logger.info("Signaled app to start sending frames")
        SharedExtensionLog.shared.write(level: .notice, category: "Ext.StreamState",
            message: "Wrote streamActive=true to app group; awaiting app sink attach")
    }

    /// Clears the active flag but preserves `newClientConnected` and other
    /// transient flags the app may still need to observe. Previously this
    /// removed the entire dict, which caused the app's handler to early-return
    /// (no observable transition) and silently leave Aravis streaming.
    func signalStreamStopped() {
        guard let defaults = groupDefaults else { return }
        let existing = defaults.dictionary(forKey: Self.stateKey) ?? [:]
        var merged = existing
        merged["streamActive"] = false
        merged["timestamp"] = Date().timeIntervalSince1970
        defaults.set(merged, forKey: Self.stateKey)
        defaults.synchronize()

        logger.info("Signaled app to stop sending frames")
    }
}

// MARK: - Sink Stream Source

class SinkStreamSource: NSObject, CMIOExtensionStreamSource {
    
    private(set) var stream: CMIOExtensionStream!
    private let device: CMIOExtensionDevice
    private let streamFormat: CMIOExtensionStreamFormat
    private var client: CMIOExtensionClient?
    
    // Closure set by DeviceSource to handle received buffers
    var consumeSampleBuffer: ((CMSampleBuffer) -> Void)?
    
    private let logger = Logger(subsystem: "com.lukechang.GigEVirtualCamera.Extension", category: "SinkStream")
    
    init(localizedName: String, streamID: UUID, streamFormat: CMIOExtensionStreamFormat, device: CMIOExtensionDevice) {
        self.device = device
        self.streamFormat = streamFormat
        super.init()
        
        // Create sink stream
        self.stream = CMIOExtensionStream(
            localizedName: localizedName,
            streamID: streamID,
            direction: .sink,
            clockType: .hostTime,
            source: self
        )
        
        logger.info("Sink stream initialized: \(localizedName)")
    }
    
    var formats: [CMIOExtensionStreamFormat] {
        return [streamFormat]
    }
    
    var activeFormatIndex: Int = 0
    
    var availableProperties: Set<CMIOExtensionProperty> {
        return [.streamActiveFormatIndex]
    }
    
    func streamProperties(forProperties properties: Set<CMIOExtensionProperty>) throws -> CMIOExtensionStreamProperties {
        let streamProperties = CMIOExtensionStreamProperties(dictionary: [:])
        if properties.contains(.streamActiveFormatIndex) {
            streamProperties.activeFormatIndex = activeFormatIndex
        }
        return streamProperties
    }
    
    func setStreamProperties(_ streamProperties: CMIOExtensionStreamProperties) throws {
        if let index = streamProperties.activeFormatIndex {
            self.activeFormatIndex = index
        }
    }
    
    func authorizedToStartStream(for client: CMIOExtensionClient) -> Bool {
        // Store the client reference
        self.client = client
        logger.info("Client authorized to start sink stream: PID \(client.pid)")
        SharedExtensionLog.shared.write(level: .info, category: "Ext.SinkStream",
            message: "Client authorized to start sink stream (PID \(client.pid))")
        return true
    }
    
    func startStream() throws {
        guard let deviceSource = device.source as? GigEVirtualCameraExtensionDeviceSource else {
            throw NSError(domain: "GigEVirtualCamera", code: 1, userInfo: [NSLocalizedDescriptionKey: "Invalid device source"])
        }
        
        // Write debug marker to UserDefaults
        if let groupDefaults = UserDefaults(suiteName: "group.S368GH6KF7.com.lukechang.GigEVirtualCamera") {
            groupDefaults.set("Sink stream started at \(Date())", forKey: "Debug_SinkStreamStarted")
            groupDefaults.synchronize()
        }
        
        NSLog("🟢🟢🟢 SINK STREAM STARTING - Client PID: \(self.client?.pid ?? 0)")
        logger.info("🟢 Starting sink stream")
        logger.info("Client info - PID: \(self.client?.pid ?? 0)")
        SharedExtensionLog.shared.write(level: .notice, category: "Ext.SinkStream",
            message: "🟢 Starting sink stream (client PID \(self.client?.pid ?? 0))")

        // Notify device source that sink is starting
        deviceSource.startSinkStreaming()

        // Begin consuming buffers
        logger.info("Beginning buffer consumption...")
        NSLog("🟢🟢🟢 Beginning sink buffer consumption...")
        try subscribe()
    }
    
    func stopStream() throws {
        guard let deviceSource = device.source as? GigEVirtualCameraExtensionDeviceSource else {
            throw NSError(domain: "GigEVirtualCamera", code: 1, userInfo: [NSLocalizedDescriptionKey: "Invalid device source"])
        }

        logger.info("Stopping sink stream")
        SharedExtensionLog.shared.write(level: .notice, category: "Ext.SinkStream",
            message: "Stopping sink stream")

        // Stop subscribing via the lock-protected setter so the consumer
        // queue's next tick observes the change.
        _ = setSubscribing(false)

        // Notify device source that sink is stopping
        deviceSource.stopSinkStreaming()
    }
    
    // Subscription state. Reads and writes happen from at least two contexts
    // (CMIO callback queue + main runloop retries), so we guard with a lock.
    private var isSubscribing = false
    private var subscribeLock = os_unfair_lock()

    // Consumer queue. Previously every continuation was dispatched to .main,
    // both flooding the UI thread and (in the error path) creating a
    // self-perpetuating retry loop that could pin the runloop in a tight
    // failure cycle. Now retries hop through a dedicated serial queue so
    // they can't starve user-facing work.
    private let consumerQueue = DispatchQueue(
        label: "com.lukechang.GigEVirtualCamera.Extension.consumer",
        qos: .userInteractive
    )

    // Error budget. CMIO can deliver many error callbacks in quick succession
    // (e.g., the app's client disappeared). Without a budget the .asyncAfter
    // retry on every error degenerates into a self-perpetuating loop.
    private var consecutiveErrorCount = 0
    private static let maxConsecutiveErrors = 8

    private func setSubscribing(_ value: Bool) -> Bool {
        os_unfair_lock_lock(&subscribeLock)
        defer { os_unfair_lock_unlock(&subscribeLock) }
        let oldValue = isSubscribing
        isSubscribing = value
        return oldValue
    }

    private func isStillSubscribing() -> Bool {
        os_unfair_lock_lock(&subscribeLock)
        defer { os_unfair_lock_unlock(&subscribeLock) }
        return isSubscribing
    }

    private func subscribe() throws {
        guard let client = self.client else {
            logger.error("No client available for subscription")
            SharedExtensionLog.shared.write(level: .error, category: "Ext.SinkStream",
                message: "subscribe() called but no client is available")
            return
        }

        let wasSubscribing = setSubscribing(true)
        guard !wasSubscribing else {
            logger.warning("Already subscribing - skipping duplicate subscription")
            SharedExtensionLog.shared.write(level: .warning, category: "Ext.SinkStream",
                message: "Already subscribing - skipping duplicate subscription")
            return
        }
        consecutiveErrorCount = 0

        logger.info("🔵 Sink subscribing to consume buffers from client PID: \(client.pid)")
        SharedExtensionLog.shared.write(level: .info, category: "Ext.SinkStream",
            message: "🔵 Sink subscribing to consume buffers (client PID \(client.pid))")

        // Start consuming buffers - this will be called repeatedly by CMIO
        scheduleConsumeNextBuffer(after: 0)
    }

    /// Schedules a call to `consumeNextBuffer` on the consumer queue. Replaces
    /// the previous synchronous recursion (stack growth) and per-call
    /// `DispatchQueue.main.asyncAfter` (UI-thread starvation + runloop pin).
    private func scheduleConsumeNextBuffer(after delay: TimeInterval) {
        guard isStillSubscribing() else { return }
        if delay <= 0 {
            consumerQueue.async { [weak self] in self?.consumeNextBuffer() }
        } else {
            consumerQueue.asyncAfter(deadline: .now() + delay) { [weak self] in
                self?.consumeNextBuffer()
            }
        }
    }

    private func consumeNextBuffer() {
        guard isStillSubscribing(), let client = self.client else { return }

        stream.consumeSampleBuffer(from: client) { [weak self] (sampleBuffer, sequenceNumber, _, hasMoreSampleBuffers, error) in
            guard let self = self else { return }
            guard self.isStillSubscribing() else { return }

            if let error = error {
                self.consecutiveErrorCount &+= 1
                let count = self.consecutiveErrorCount
                self.logger.error("❌ Error consuming sample buffer (#\(count)): \(error.localizedDescription)")
                // Log every 1st/4th/8th error to the shared log (the full
                // burst is in the unified log via os.log already); the
                // shared log surfaces the cadence to the diagnostics drawer.
                if count == 1 || count == 4 || count >= Self.maxConsecutiveErrors {
                    SharedExtensionLog.shared.write(level: .error, category: "Ext.SinkStream",
                        message: "❌ consumeSampleBuffer error #\(count): \(error.localizedDescription)")
                }

                if count >= Self.maxConsecutiveErrors {
                    // The client connection is dead. Tear down the subscription
                    // so the runloop is freed; CMIO will call stopStream when
                    // the app's sink handle finally closes, or a fresh
                    // startStream will reset everything.
                    self.logger.error("Giving up after \(count) consecutive errors; stopping consumption")
                    SharedExtensionLog.shared.write(level: .error, category: "Ext.SinkStream",
                        message: "Giving up after \(count) consecutive errors; subscription torn down")
                    _ = self.setSubscribing(false)
                    return
                }

                // Exponential backoff: 100ms, 200ms, 400ms, ... up to ~2s.
                let backoff = min(2.0, 0.1 * pow(2.0, Double(count - 1)))
                self.scheduleConsumeNextBuffer(after: backoff)
                return
            }

            // Successful read clears the error budget.
            self.consecutiveErrorCount = 0

            if let sampleBuffer = sampleBuffer {
                if sequenceNumber == 0 {
                    if let groupDefaults = UserDefaults(suiteName: "group.S368GH6KF7.com.lukechang.GigEVirtualCamera") {
                        groupDefaults.set("First frame received at \(Date())", forKey: "Debug_FirstFrameReceived")
                        groupDefaults.synchronize()
                    }
                    SharedExtensionLog.shared.write(level: .notice, category: "Ext.SinkStream",
                        message: "🎉 First frame consumed from sink (seq 0)")
                }

                if sequenceNumber % 300 == 0 {
                    // Per-frame NSLog calls are synchronous IPC and were
                    // costing ~150 calls/s at 30 fps. Sample once every 10
                    // seconds instead.
                    self.logger.info("Sink received frame #\(sequenceNumber)")
                    if sequenceNumber > 0 {
                        SharedExtensionLog.shared.write(level: .info, category: "Ext.SinkStream",
                            message: "Sink consumed frame #\(sequenceNumber)")
                    }
                }

                if let consumeCallback = self.consumeSampleBuffer {
                    consumeCallback(sampleBuffer)
                }

                // Keep draining without growing the stack. Even when
                // hasMoreSampleBuffers is true, we hop through the consumer
                // queue rather than synchronously recursing inside CMIO's
                // own callback frame (which previously risked stack growth
                // proportional to the queue depth).
                self.scheduleConsumeNextBuffer(after: hasMoreSampleBuffers ? 0 : 0.033)
            } else {
                // Queue empty — poll at ~30 fps.
                self.scheduleConsumeNextBuffer(after: 0.033)
            }
        }
    }
}

// MARK: - Source Stream Source

class SourceStreamSource: NSObject, CMIOExtensionStreamSource {
    
    private(set) var stream: CMIOExtensionStream!
    private let device: CMIOExtensionDevice
    private let streamFormat: CMIOExtensionStreamFormat
    
    private let logger = Logger(subsystem: "com.lukechang.GigEVirtualCamera.Extension", category: "SourceStream")
    
    // Default-frame fallback. The `timer` is a 2-second watchdog that emits a
    // default frame ONLY when no real frame has been delivered recently. It is
    // NOT a 30 Hz generator. Mixing two frame sources at 30 Hz interleaves PTS
    // values that originate from different paths and makes CMIO clients freeze.
    private var timer: Timer?
    private var defaultPixelBuffer: CVPixelBuffer?
    private let frameDuration = CMTime(value: 1, timescale: 30)  // 30 fps

    // Mach-uptime ns of the last real (non-default) frame successfully sent.
    // The watchdog suppresses itself while this is fresh (< 2s old).
    // Protected by `sendLock`.
    private var lastRealFrameUptimeNs: UInt64 = 0

    // Last hostTime value handed to stream.send(). CMIO consumers freeze on
    // non-monotonic hostTimes, and three producers can call sendSampleBuffer
    // concurrently: the sink-to-source bridge (CMIO queue), the no-frame
    // watchdog (main runloop), and the startStream bootstrap (main async).
    // Even when all three read CLOCK_UPTIME_RAW, two threads can sample the
    // same nanosecond or arrive at stream.send out of scheduling order.
    // sendSampleBuffer clamps every emit to max(now, lastSentHostTimeNs+1).
    // Mirrors the unit-tested logic in FramePipelineKit/MonotonicHostClock.
    private var lastSentHostTimeNs: UInt64 = 0
    private var sendLock = os_unfair_lock()

    // Keep reference to last frame for new clients
    private var lastReceivedFrame: CMSampleBuffer?
    private let frameQueue = DispatchQueue(label: "com.lukechang.lastframe", qos: .userInteractive)
    
    init(localizedName: String, streamID: UUID, streamFormat: CMIOExtensionStreamFormat, device: CMIOExtensionDevice) {
        self.device = device
        self.streamFormat = streamFormat
        super.init()
        
        // Create source stream
        self.stream = CMIOExtensionStream(
            localizedName: localizedName,
            streamID: streamID,
            direction: .source,
            clockType: .hostTime,
            source: self
        )
        
        // Create default pixel buffer
        createDefaultPixelBuffer()
        
        logger.info("Source stream initialized: \(localizedName)")

        // Default-frame emission is started by startStream(), not here. There
        // are no clients at init time and emitting frames before then is wasted
        // work that previously corrupted live streams by interleaving with the
        // real-frame path on a different clock domain.
    }
    
    var formats: [CMIOExtensionStreamFormat] {
        return [streamFormat]
    }
    
    var activeFormatIndex: Int = 0
    
    var availableProperties: Set<CMIOExtensionProperty> {
        return [
            .streamActiveFormatIndex, 
            .streamFrameDuration,
            .streamSinkBufferQueueSize,
            .streamSinkBuffersRequiredForStartup
        ]
    }
    
    func streamProperties(forProperties properties: Set<CMIOExtensionProperty>) throws -> CMIOExtensionStreamProperties {
        let streamProperties = CMIOExtensionStreamProperties(dictionary: [:])
        if properties.contains(.streamActiveFormatIndex) {
            streamProperties.activeFormatIndex = activeFormatIndex
        }
        if properties.contains(.streamFrameDuration) {
            streamProperties.frameDuration = frameDuration
        }
        if properties.contains(.streamSinkBufferQueueSize) {
            streamProperties.sinkBufferQueueSize = 30  // 1 second of frames at 30fps
        }
        if properties.contains(.streamSinkBuffersRequiredForStartup) {
            streamProperties.sinkBuffersRequiredForStartup = 1  // Minimal requirement
        }
        return streamProperties
    }
    
    func setStreamProperties(_ streamProperties: CMIOExtensionStreamProperties) throws {
        if let index = streamProperties.activeFormatIndex {
            self.activeFormatIndex = index
        }
    }
    
    func authorizedToStartStream(for client: CMIOExtensionClient) -> Bool {
        logger.info("Client authorized to start source stream: PID \(client.pid)")
        NSLog("🎬🎬🎬 SOURCE: authorizedToStartStream called - Client PID: \(client.pid)")
        SharedExtensionLog.shared.write(level: .info, category: "Ext.SourceStream",
            message: "Client authorized to start source stream (PID \(client.pid))")
        
        // Option 3: Start sending frames immediately upon authorization
        guard let deviceSource = device.source as? GigEVirtualCameraExtensionDeviceSource else {
            return true
        }
        
        NSLog("🎬🎬🎬 OPTION 3: Starting frame flow immediately on authorization")
        NSLog("🎬🎬🎬 Current sink active: \(deviceSource.isSinking)")
        
        // If sink is active, ensure frames are flowing to this source stream
        if deviceSource.isSinking {
            NSLog("🎬🎬🎬 Sink is active - frames should start flowing immediately")
        } else {
            NSLog("🎬🎬🎬 Sink not active - default frames should be flowing")
        }
        
        return true
    }
    
    func startStream() throws {
        guard let deviceSource = device.source as? GigEVirtualCameraExtensionDeviceSource else {
            throw NSError(domain: "GigEVirtualCamera", code: 1, userInfo: [NSLocalizedDescriptionKey: "Invalid device source"])
        }
        
        // Write debug marker to UserDefaults
        if let groupDefaults = UserDefaults(suiteName: "group.S368GH6KF7.com.lukechang.GigEVirtualCamera") {
            groupDefaults.set("Source stream started at \(Date())", forKey: "Debug_SourceStreamStarted")
            
            // IMPORTANT: Notify app that a new client has connected
            // This will trigger the app to restart camera streaming if needed
            var streamState = groupDefaults.dictionary(forKey: "StreamState") ?? [:]
            streamState["newClientConnected"] = true
            streamState["clientConnectedTime"] = Date().timeIntervalSince1970
            groupDefaults.set(streamState, forKey: "StreamState")
            groupDefaults.synchronize()
            
            NSLog("🎬🎬🎬 Notified app about new client connection")
        }
        
        NSLog("🎬🎬🎬 SOURCE STREAM STARTING - Sink active: \(deviceSource.isSinking)")
        NSLog("🎬🎬🎬 Current streamingCounter BEFORE increment: \(deviceSource.streamingCounter)")
        logger.info("🟢 Starting source stream")
        logger.info("Device sink active: \(deviceSource.isSinking)")
        SharedExtensionLog.shared.write(level: .notice, category: "Ext.SourceStream",
            message: "🟢 Starting source stream (sink active: \(deviceSource.isSinking))")

        // Notify device source
        deviceSource.startStreaming()

        NSLog("🎬🎬🎬 Current streamingCounter AFTER increment: \(deviceSource.streamingCounter)")

        // Start the 2-second no-real-frame watchdog. This is the ONLY scheduled
        // emission path for default frames. The previous 30Hz timer raced the
        // real-frame path and caused stuck/frozen video in clients.
        logger.info("Starting no-frame watchdog...")
        startNoFrameWatchdog()

        // One-shot bootstrap so freshly connected clients see something instead
        // of black. Prefer the last real frame; otherwise emit the test pattern.
        // Marked isDefault so this does not suppress the watchdog -- if no real
        // frames arrive within 2s, the watchdog still kicks in.
        frameQueue.async { [weak self] in
            guard let self = self else { return }
            let bootstrap = self.lastReceivedFrame
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                if let bootstrap = bootstrap {
                    self.logger.info("Bootstrap: sending cached real frame to new client")
                    self.sendSampleBuffer(bootstrap, isDefault: true)
                } else {
                    self.logger.info("Bootstrap: no cached frame, sending default test pattern")
                    self.sendDefaultFrame()
                }
            }
        }
    }
    
    func stopStream() throws {
        guard let deviceSource = device.source as? GigEVirtualCameraExtensionDeviceSource else {
            throw NSError(domain: "GigEVirtualCamera", code: 1, userInfo: [NSLocalizedDescriptionKey: "Invalid device source"])
        }

        logger.info("Stopping source stream")
        SharedExtensionLog.shared.write(level: .notice, category: "Ext.SourceStream",
            message: "Stopping source stream")

        // Stop watchdog
        stopNoFrameWatchdog()

        // Notify device source
        deviceSource.stopStreaming()
    }
    
    // Public method for DeviceSource to send frames.
    //
    // `isDefault == true` means the test-pattern or bootstrap path. Default
    // frames are NOT cached as `lastReceivedFrame` (we don't want the test
    // pattern to become the next bootstrap) and they do NOT update
    // `lastRealFrameUptimeNs` (so the watchdog stays armed).
    //
    // Concurrency: this method can be called from the CMIO callback queue
    // (real-frame path via the sink bridge), the main runloop (watchdog,
    // bootstrap), or any future producer. The check-and-emit MUST be atomic
    // with respect to the per-stream hostTime sequence — otherwise two
    // producers can race past each other and stream.send() receives a
    // non-monotonic pair, which CMIO consumers (QuickTime/Zoom/etc.) handle
    // by freezing. `sendLock` covers both the hostTime clamp and the call
    // to `stream.send` so a real frame can't slip between the watchdog's
    // check and emit.
    func sendSampleBuffer(_ sampleBuffer: CMSampleBuffer, isDefault: Bool = false) {
        if stream == nil {
            logger.error("stream is nil - cannot send frame")
            return
        }

        // Cache real frames only.
        if !isDefault {
            frameQueue.async { [weak self] in
                self?.lastReceivedFrame = sampleBuffer
            }
        }

        let nowNs = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)

        os_unfair_lock_lock(&sendLock)
        // Clamp to strictly-increasing. Bump by 1 ns rather than dropping;
        // ns-level jitter is imperceptible to video and a dropped frame is
        // worse than a 1 ns nudge. See MonotonicHostClock for tested logic.
        let hostTimeNs: UInt64
        if nowNs <= lastSentHostTimeNs {
            hostTimeNs = lastSentHostTimeNs &+ 1
        } else {
            hostTimeNs = nowNs
        }
        lastSentHostTimeNs = hostTimeNs
        if !isDefault {
            lastRealFrameUptimeNs = hostTimeNs
        }

        stream.send(
            sampleBuffer,
            discontinuity: [],
            hostTimeInNanoseconds: hostTimeNs
        )
        os_unfair_lock_unlock(&sendLock)
    }
    
    private func createDefaultPixelBuffer() {
        let width = Int(streamFormat.formatDescription.dimensions.width)
        let height = Int(streamFormat.formatDescription.dimensions.height)
        
        let attrs: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            kCVPixelBufferWidthKey: width,
            kCVPixelBufferHeightKey: height,
            kCVPixelBufferIOSurfacePropertiesKey: [:]
        ]
        
        CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, attrs as CFDictionary, &defaultPixelBuffer)
        
        // Fill with test pattern
        if let buffer = defaultPixelBuffer {
            fillWithTestPattern(buffer)
        }
    }
    
    private func fillWithTestPattern(_ buffer: CVPixelBuffer) {
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        
        // For 420v format, we have two planes: Y (luma) and UV (chroma)
        let width = CVPixelBufferGetWidth(buffer)
        let height = CVPixelBufferGetHeight(buffer)
        
        // Fill Y plane (plane 0) with gradient
        if let yPlane = CVPixelBufferGetBaseAddressOfPlane(buffer, 0) {
            let yBytesPerRow = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
            let yData = yPlane.assumingMemoryBound(to: UInt8.self)
            
            for y in 0..<height {
                for x in 0..<width {
                    // Create a gradient pattern
                    let offset = y * yBytesPerRow + x
                    yData[offset] = UInt8((x + y) * 255 / (width + height))
                }
            }
        }
        
        // Fill UV plane (plane 1) with color
        if let uvPlane = CVPixelBufferGetBaseAddressOfPlane(buffer, 1) {
            let uvBytesPerRow = CVPixelBufferGetBytesPerRowOfPlane(buffer, 1)
            let uvData = uvPlane.assumingMemoryBound(to: UInt8.self)
            
            // UV plane is half the resolution of Y plane
            for y in 0..<(height/2) {
                for x in 0..<(width/2) {
                    let offset = y * uvBytesPerRow + x * 2
                    uvData[offset] = 128      // U (blue-yellow balance)
                    uvData[offset + 1] = 128  // V (red-green balance)
                }
            }
        }
    }
    
    // 2s no-real-frame watchdog. Emits one default frame only when no real
    // frame has been delivered in the last 2 seconds. Replaces the previous
    // always-on 30 Hz default-frame generator that was the root cause of
    // frozen/stuck client video.
    private static let noFrameTimeoutNs: UInt64 = 2_000_000_000

    private func startNoFrameWatchdog() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            // Read `lastRealFrameUptimeNs` under the same lock that
            // sendSampleBuffer writes it. Without this, a real frame can
            // land between the read and the sendDefaultFrame call below
            // — and stream.send sees two emits with the same logical time
            // window, freezing the consumer.
            os_unfair_lock_lock(&self.sendLock)
            let now = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
            let last = self.lastRealFrameUptimeNs
            let isStale = (last == 0) || (now - last > Self.noFrameTimeoutNs)
            os_unfair_lock_unlock(&self.sendLock)
            if isStale {
                self.sendDefaultFrame()
            }
        }
    }

    private func stopNoFrameWatchdog() {
        timer?.invalidate()
        timer = nil
    }
    
    private func sendDefaultFrame() {
        guard let _ = device.source as? GigEVirtualCameraExtensionDeviceSource else { return }
        guard let buffer = defaultPixelBuffer else { return }

        // Use CLOCK_UPTIME_RAW for PTS so the watchdog frames are in the same
        // clock domain as real frames (sendSampleBuffer also uses CLOCK_UPTIME_RAW
        // for hostTimeInNanoseconds). On Apple Silicon these match the host-time
        // clock used previously, but the prior CMClockGetHostTimeClock() reading
        // is a different code path that can drift across macOS versions; using
        // one source removes the failure mode entirely.
        let ptsNs = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
        var sampleBuffer: CMSampleBuffer?
        var timingInfo = CMSampleTimingInfo(
            duration: frameDuration,
            presentationTimeStamp: CMTimeMake(value: Int64(bitPattern: ptsNs),
                                              timescale: 1_000_000_000),
            decodeTimeStamp: .invalid
        )

        var formatDesc: CMVideoFormatDescription?
        CMVideoFormatDescriptionCreateForImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: buffer,
            formatDescriptionOut: &formatDesc
        )

        guard let format = formatDesc else { return }

        CMSampleBufferCreateReadyWithImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: buffer,
            formatDescription: format,
            sampleTiming: &timingInfo,
            sampleBufferOut: &sampleBuffer
        )

        if let sample = sampleBuffer {
            logger.info("Watchdog emitting default frame -- no real frame in last 2s")
            // This is one of the most important diagnostic signals: when the
            // app side has stopped delivering, the extension falls back to a
            // test pattern. Repeated firings = ongoing stall.
            SharedExtensionLog.shared.write(level: .warning, category: "Ext.SourceStream",
                message: "⚠️ no-frame watchdog: emitting default frame (no real frame in last 2s)")
            sendSampleBuffer(sample, isDefault: true)
        }
    }
}

// MARK: - Device Source

class GigEVirtualCameraExtensionDeviceSource: NSObject, CMIOExtensionDeviceSource {
    
    private(set) var device: CMIOExtensionDevice!
    
    private let logger = Logger(subsystem: "com.lukechang.GigEVirtualCamera.Extension", category: "Device")
    
    // Stream management
    private var sourceStreamSource: SourceStreamSource!
    private var sinkStreamSource: SinkStreamSource!

    // Stream state. CMIO can invoke startStream/stopStream on any thread, and
    // the source-stream and sink-stream lifecycles can interleave (consumer
    // connects while app is in the middle of attaching its sink, etc.). The
    // "first-client" and "last-client" branches below relied on bare reads of
    // these counters, which produced stale-state windows where the extension
    // either over-signaled the app (multiple signalNeedFrames calls per
    // consumer) or under-signaled (consumer fully attached without the app
    // ever being woken). All mutations and decisions happen under stateLock.
    private var _streamingCounter = 0
    private var _isSinking = false
    private var stateLock = os_unfair_lock()

    /// Thread-safe snapshot for logging. Not for control flow — by the time
    /// the caller acts on the return value it may already be stale.
    func snapshotState() -> (counter: Int, isSinking: Bool) {
        os_unfair_lock_lock(&stateLock)
        defer { os_unfair_lock_unlock(&stateLock) }
        return (_streamingCounter, _isSinking)
    }

    var isSinking: Bool {
        os_unfair_lock_lock(&stateLock)
        defer { os_unfair_lock_unlock(&stateLock) }
        return _isSinking
    }

    var streamingCounter: Int {
        os_unfair_lock_lock(&stateLock)
        defer { os_unfair_lock_unlock(&stateLock) }
        return _streamingCounter
    }

    // App coordination
    private let streamStateCoordinator = StreamStateCoordinator()
    
    init(localizedName: String) {
        super.init()
        
        logger.info("Initializing device: \(localizedName)")
        
        let deviceID = UUID(uuidString: "4B59CDEF-BEA6-52E8-06E7-AD1B8E6B29C4")!
        self.device = CMIOExtensionDevice(localizedName: localizedName, deviceID: deviceID, legacyDeviceID: nil, source: self)
        
        // Get format from shared UserDefaults
        let groupDefaults = UserDefaults(suiteName: "group.S368GH6KF7.com.lukechang.GigEVirtualCamera")
        let width = Int32(groupDefaults?.integer(forKey: "SelectedFormatWidth") ?? 1920)
        let height = Int32(groupDefaults?.integer(forKey: "SelectedFormatHeight") ?? 1080)
        let fps = groupDefaults?.integer(forKey: "SelectedFormatFPS") ?? 30
        
        logger.info("Creating streams with format: \(width)×\(height) @ \(fps)fps")
        
        // Create video format for both streams
        // Use 420v format which is standard for video
        let formatDict: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            kCVPixelBufferWidthKey as String: Int(width),
            kCVPixelBufferHeightKey as String: Int(height),
            kCVPixelBufferIOSurfacePropertiesKey as String: [:]
        ]
        
        var videoDescription: CMFormatDescription?
        CMVideoFormatDescriptionCreate(
            allocator: kCFAllocatorDefault,
            codecType: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            width: width,
            height: height,
            extensions: formatDict as CFDictionary,
            formatDescriptionOut: &videoDescription
        )
        
        guard let videoDesc = videoDescription else {
            logger.error("Failed to create video format description")
            return
        }
        
        let videoStreamFormat = CMIOExtensionStreamFormat(
            formatDescription: videoDesc,
            maxFrameDuration: CMTime(value: 1, timescale: CMTimeScale(fps)),
            minFrameDuration: CMTime(value: 1, timescale: CMTimeScale(fps)),
            validFrameDurations: nil
        )
        
        // Create source stream
        let sourceStreamID = UUID(uuidString: "8B97F5C9-2B8C-5F9D-0F4E-6D3B9C5E0F1F")!
        sourceStreamSource = SourceStreamSource(
            localizedName: "GigE Camera Output",
            streamID: sourceStreamID,
            streamFormat: videoStreamFormat,
            device: device
        )
        
        // Create sink stream
        let sinkStreamID = UUID(uuidString: "7A86E4C8-1C7B-4E8C-9F3D-5B2A8D4C1E2E")!
        sinkStreamSource = SinkStreamSource(
            localizedName: "GigE Camera Input",
            streamID: sinkStreamID,
            streamFormat: videoStreamFormat,
            device: device
        )
        
        // Add streams to device
        do {
            try device.addStream(sourceStreamSource.stream)
            try device.addStream(sinkStreamSource.stream)
            logger.info("Successfully added source and sink streams to device")
        } catch {
            logger.error("Failed to add streams: \(error.localizedDescription)")
        }
    }
    
    var availableProperties: Set<CMIOExtensionProperty> {
        return [
            .deviceTransportType, 
            .deviceModel
        ]
    }
    
    func deviceProperties(forProperties properties: Set<CMIOExtensionProperty>) throws -> CMIOExtensionDeviceProperties {
        let deviceProperties = CMIOExtensionDeviceProperties(dictionary: [:])
        
        if properties.contains(.deviceTransportType) {
            deviceProperties.transportType = kIOAudioDeviceTransportTypeVirtual
        }
        if properties.contains(.deviceModel) {
            deviceProperties.model = "GigE Virtual Camera"
        }
        
        return deviceProperties
    }
    
    func setDeviceProperties(_ deviceProperties: CMIOExtensionDeviceProperties) throws {
        // These properties are read-only
    }
    
    // Called by source stream when client starts watching
    func startStreaming() {
        // Decide whether we are the first client and whether the sink is
        // already serving frames — atomically, so a concurrent consumer
        // attach/detach can't make us double-signal or skip signaling.
        os_unfair_lock_lock(&stateLock)
        _streamingCounter += 1
        let counter = _streamingCounter
        let sinking = _isSinking
        let shouldSignalNeedFrames = (counter == 1) && !sinking
        os_unfair_lock_unlock(&stateLock)

        logger.info("🎬 Source stream started. Client count: \(counter), sink: \(sinking)")
        SharedExtensionLog.shared.write(level: .info, category: "Ext.Device",
            message: "🎬 Source stream started (clients: \(counter), sink active: \(sinking))")

        // Notify outside the lock — signalNeedFrames touches UserDefaults
        // and shouldn't hold the lock across an IPC-style write.
        if shouldSignalNeedFrames {
            logger.info("📢 Signaling app to start sending frames")
            SharedExtensionLog.shared.write(level: .notice, category: "Ext.Device",
                message: "📢 Signaling app to start sending frames (newClientConnected=true)")
            streamStateCoordinator.signalNeedFrames()
        } else if counter == 1 && sinking {
            logger.info("✅ Sink already active - frames should be flowing")
            SharedExtensionLog.shared.write(level: .info, category: "Ext.Device",
                message: "✅ Sink already active - frames should be flowing")
        }
    }

    // Called by source stream when client stops watching
    func stopStreaming() {
        os_unfair_lock_lock(&stateLock)
        if _streamingCounter > 0 {
            _streamingCounter -= 1
        }
        let counter = _streamingCounter
        let shouldSignalStopped = (counter == 0)
        os_unfair_lock_unlock(&stateLock)

        logger.info("Source stream stopped. Client count: \(counter)")
        SharedExtensionLog.shared.write(level: .info, category: "Ext.Device",
            message: "Source stream stopped (clients remaining: \(counter))")

        if shouldSignalStopped {
            SharedExtensionLog.shared.write(level: .info, category: "Ext.Device",
                message: "Signaling app: streamActive=false (last client gone)")
            streamStateCoordinator.signalStreamStopped()
        }
    }

    // Called by sink stream when app starts sending
    func startSinkStreaming() {
        os_unfair_lock_lock(&stateLock)
        _isSinking = true
        let counter = _streamingCounter
        os_unfair_lock_unlock(&stateLock)

        logger.info("🎯 Starting sink streaming - setting up bridge to source (clients: \(counter))")
        SharedExtensionLog.shared.write(level: .notice, category: "Ext.Device",
            message: "🎯 Starting sink streaming - bridge to source attached (clients: \(counter))")

        // Set up the bridge: route buffers from sink to source. We deliberately
        // do NOT take stateLock inside the hot frame path; sendSampleBuffer has
        // its own lock, and a stale `streamingCounter` here is at worst a log
        // line — frames are still forwarded to the source stream regardless.
        sinkStreamSource.consumeSampleBuffer = { [weak self] buffer in
            guard let self = self else { return }
            guard self.sourceStreamSource != nil else {
                self.logger.error("sourceStreamSource is nil - cannot forward frame")
                return
            }
            self.sourceStreamSource.sendSampleBuffer(buffer)
        }

        logger.info("✅ Sink-to-source bridge configured")
    }

    // Called by sink stream when app stops sending
    func stopSinkStreaming() {
        os_unfair_lock_lock(&stateLock)
        _isSinking = false
        os_unfair_lock_unlock(&stateLock)

        logger.info("Stopping sink streaming")
        SharedExtensionLog.shared.write(level: .notice, category: "Ext.Device",
            message: "Stopping sink streaming - bridge detached")
        sinkStreamSource.consumeSampleBuffer = nil
    }
}

// MARK: - Provider Source

class GigEVirtualCameraExtensionProviderSource: NSObject, CMIOExtensionProviderSource {
    
    private(set) var provider: CMIOExtensionProvider!
    private var deviceSource: GigEVirtualCameraExtensionDeviceSource!
    private let logger = Logger(subsystem: "com.lukechang.GigEVirtualCamera.Extension", category: "Provider")
    
    override init() {
        super.init()
        
        logger.info("Provider initializing...")
        
        provider = CMIOExtensionProvider(source: self, clientQueue: nil)
        deviceSource = GigEVirtualCameraExtensionDeviceSource(localizedName: "GigE Virtual Camera")
        
        do {
            try provider.addDevice(deviceSource.device)
            logger.info("Provider initialized with device")
        } catch {
            logger.error("Failed to add device to provider: \(error.localizedDescription)")
        }
    }
    
    func connect(to client: CMIOExtensionClient) throws {
        logger.info("Client connected: PID \(client.pid)")
        SharedExtensionLog.shared.write(level: .info, category: "Ext.Provider",
            message: "Client connected (PID \(client.pid))")
    }

    func disconnect(from client: CMIOExtensionClient) {
        logger.info("Client disconnected: PID \(client.pid)")
        SharedExtensionLog.shared.write(level: .info, category: "Ext.Provider",
            message: "Client disconnected (PID \(client.pid))")
    }
    
    var availableProperties: Set<CMIOExtensionProperty> {
        return [.providerManufacturer]
    }
    
    func providerProperties(forProperties properties: Set<CMIOExtensionProperty>) throws -> CMIOExtensionProviderProperties {
        let providerProperties = CMIOExtensionProviderProperties(dictionary: [:])
        if properties.contains(.providerManufacturer) {
            providerProperties.manufacturer = "HyperStudy"
        }
        return providerProperties
    }
    
    func setProviderProperties(_ providerProperties: CMIOExtensionProviderProperties) throws {
        // Handle settable properties here
    }
}