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

class StreamStateCoordinator {
    private let logger = Logger(subsystem: "com.lukechang.GigEVirtualCamera.Extension", category: "StreamState")
    private let appGroupID = "group.S368GH6KF7.com.lukechang.GigEVirtualCamera"
    
    private var groupDefaults: UserDefaults? {
        UserDefaults(suiteName: appGroupID)
    }
    
    func signalNeedFrames() {
        guard let defaults = groupDefaults else {
            logger.error("Failed to access App Group UserDefaults")
            return
        }
        
        let state = [
            "streamActive": true,
            "timestamp": Date().timeIntervalSince1970,
            "pid": ProcessInfo.processInfo.processIdentifier
        ] as [String : Any]
        
        defaults.set(state, forKey: "StreamState")
        defaults.synchronize()
        
        logger.info("Signaled app to start sending frames")
    }
    
    func signalStreamStopped() {
        guard let defaults = groupDefaults else { return }
        
        defaults.removeObject(forKey: "StreamState")
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
        
        // Stop subscribing
        isSubscribing = false
        
        // Notify device source that sink is stopping
        deviceSource.stopSinkStreaming()
    }
    
    private var isSubscribing = false
    
    private func subscribe() throws {
        guard let client = self.client else {
            logger.error("No client available for subscription")
            NSLog("❌❌❌ No client available for subscription")
            return
        }
        
        guard !isSubscribing else { 
            logger.warning("Already subscribing - skipping duplicate subscription")
            return 
        }
        isSubscribing = true
        
        logger.info("🔵 Sink subscribing to consume buffers from client PID: \(client.pid)")
        NSLog("🔵🔵🔵 SINK SUBSCRIBING - Client PID: \(client.pid)")
        
        // Start consuming buffers - this will be called repeatedly by CMIO
        consumeNextBuffer()
    }
    
    private func consumeNextBuffer() {
        guard isSubscribing, let client = self.client else { 
            NSLog("⚠️⚠️⚠️ Stopping consumption - subscribing: \(isSubscribing), client: \(client != nil)")
            return 
        }
        
        // Consume buffers from the client
        stream.consumeSampleBuffer(from: client) { [weak self] (sampleBuffer, sequenceNumber, discontinuity, hasMoreSampleBuffers, error) in
            guard let self = self else {
                NSLog("❌❌❌ self is nil in callback")
                return
            }
            
            if let error = error {
                NSLog("❌❌❌ Error consuming sample buffer: \(error.localizedDescription)")
                self.logger.error("❌ Error consuming sample buffer: \(error.localizedDescription)")
                
                // Try to recover by re-subscribing after a delay
                if self.isSubscribing {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                        self.consumeNextBuffer()
                    }
                }
                return
            }
            
            if let sampleBuffer = sampleBuffer {
                // We have a real frame!
                NSLog("✅✅✅ consumeSampleBuffer received REAL frame! seq:\(sequenceNumber) hasMore:\(hasMoreSampleBuffers)")
                
                // Write debug marker for first frame
                if sequenceNumber == 0 {
                    if let groupDefaults = UserDefaults(suiteName: "group.S368GH6KF7.com.lukechang.GigEVirtualCamera") {
                        groupDefaults.set("First frame received at \(Date())", forKey: "Debug_FirstFrameReceived")
                        groupDefaults.synchronize()
                    }
                }
                
                // Log periodically for debugging
                if sequenceNumber % 30 == 0 {
                    // Get format info from the sample buffer
                    if let formatDesc = CMSampleBufferGetFormatDescription(sampleBuffer) {
                        let dimensions = CMVideoFormatDescriptionGetDimensions(formatDesc)
                        let pixelFormat = CMFormatDescriptionGetMediaSubType(formatDesc)
                        let formatString = pixelFormat == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange ? "YUV420v" : 
                                         pixelFormat == kCVPixelFormatType_32BGRA ? "BGRA" : "Unknown(\(pixelFormat))"
                        NSLog("✅✅✅ Sink received frame #\(sequenceNumber) | \(dimensions.width)x\(dimensions.height) | Format: \(formatString)")
                        self.logger.info("✅ Sink received frame #\(sequenceNumber) | \(dimensions.width)x\(dimensions.height) | Format: \(formatString)")
                    } else {
                        NSLog("✅✅✅ Sink received frame #\(sequenceNumber)")
                        self.logger.info("✅ Sink received frame #\(sequenceNumber) | hasMore: \(hasMoreSampleBuffers)")
                    }
                }
                
                // Check if we have a consumer
                if let consumeCallback = self.consumeSampleBuffer {
                    NSLog("📤📤📤 Forwarding frame #\(sequenceNumber) to DeviceSource")
                    self.logger.debug("Forwarding frame to DeviceSource...")
                    consumeCallback(sampleBuffer)
                } else {
                    self.logger.warning("⚠️ No consumer callback set - frame will be dropped!")
                    NSLog("⚠️⚠️⚠️ No consumer callback set!")
                }
                
                // Continue consuming immediately if there are more buffers
                if self.isSubscribing && hasMoreSampleBuffers {
                    self.consumeNextBuffer()
                } else if self.isSubscribing {
                    // No more buffers right now, wait a bit before checking again
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.033) { // ~30fps
                        self.consumeNextBuffer()
                    }
                }
            } else {
                // Nil buffer means queue is empty
                // Don't log this as it's normal when queue is empty
                // Just wait and try again
                if self.isSubscribing {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.033) { // ~30fps
                        self.consumeNextBuffer()
                    }
                }
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
    private var lastRealFrameUptimeNs: UInt64 = 0

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
    // `hostTimeInNanoseconds` MUST be drawn from a single monotonic clock
    // (CLOCK_UPTIME_RAW, the same source the app's capture path uses) for both
    // real and default frames. Mixing CMSampleBuffer PTS (capture time) with
    // host-time clock (send time) is what previously made CMIO clients freeze
    // on non-monotonic timestamps.
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

        let hostTimeNs = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)

        stream.send(
            sampleBuffer,
            discontinuity: [],
            hostTimeInNanoseconds: hostTimeNs
        )

        if !isDefault {
            lastRealFrameUptimeNs = hostTimeNs
        }
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
            let now = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
            let last = self.lastRealFrameUptimeNs
            if last == 0 || now - last > Self.noFrameTimeoutNs {
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

        var sampleBuffer: CMSampleBuffer?
        var timingInfo = CMSampleTimingInfo(
            duration: frameDuration,
            presentationTimeStamp: CMClockGetTime(CMClockGetHostTimeClock()),
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
    
    // Stream state
    var streamingCounter = 0  // Number of clients connected to source
    private(set) var isSinking = false  // Whether sink is active
    
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
        streamingCounter += 1
        NSLog("🎬🎬🎬 DeviceSource.startStreaming() called - counter: \(self.streamingCounter)")
        logger.info("🎬 Source stream started. Client count: \(self.streamingCounter)")
        logger.info("Sink active: \(self.isSinking)")
        
        // If this is the first client and sink isn't active, signal app
        if streamingCounter == 1 && !isSinking {
            logger.info("📢 Signaling app to start sending frames")
            streamStateCoordinator.signalNeedFrames()
        } else if streamingCounter == 1 && isSinking {
            logger.info("✅ Sink already active - frames should be flowing")
            NSLog("✅✅✅ Sink already active - frames should start flowing to source")
        }
    }
    
    // Called by source stream when client stops watching
    func stopStreaming() {
        if streamingCounter > 0 {
            streamingCounter -= 1
        }
        
        logger.info("Source stream stopped. Client count: \(self.streamingCounter)")
        
        // If no more clients, signal app to stop
        if streamingCounter == 0 {
            streamStateCoordinator.signalStreamStopped()
        }
    }
    
    // Called by sink stream when app starts sending
    func startSinkStreaming() {
        logger.info("🎯 Starting sink streaming - setting up bridge to source")
        logger.info("Current streaming counter: \(self.streamingCounter)")
        isSinking = true
        
        // Set up the bridge: route buffers from sink to source
        sinkStreamSource.consumeSampleBuffer = { [weak self] buffer in
            guard let self = self else { 
                self?.logger.error("DeviceSource deallocated - cannot forward frame")
                return 
            }
            
            self.logger.debug("🔄 DeviceSource received frame from sink")
            
            // Always forward frames to source stream when sink is active
            // The source stream will handle client management
            self.logger.info("📤 Forwarding frame to source (clients: \(self.streamingCounter))")
            NSLog("🚀🚀🚀 Sending frame to source stream - clients: \(self.streamingCounter)")
            
            // Check if sourceStreamSource is nil
            if self.sourceStreamSource == nil {
                NSLog("❌❌❌ sourceStreamSource is NIL!")
                self.logger.error("sourceStreamSource is nil - cannot forward frame")
                return
            }
            
            NSLog("🚀🚀🚀 sourceStreamSource exists, calling sendSampleBuffer...")
            self.sourceStreamSource.sendSampleBuffer(buffer)
            NSLog("🚀🚀🚀 sendSampleBuffer call completed")
        }
        
        logger.info("✅ Sink-to-source bridge configured")
    }
    
    // Called by sink stream when app stops sending
    func stopSinkStreaming() {
        logger.info("Stopping sink streaming")
        isSinking = false
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
    }
    
    func disconnect(from client: CMIOExtensionClient) {
        logger.info("Client disconnected: PID \(client.pid)")
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