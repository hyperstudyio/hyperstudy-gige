//
//  CMIOFrameSender.swift
//  GigECameraApp
//
//  Sends frames to CMIO extension's sink stream
//

import Foundation
import CoreMediaIO
import CoreVideo
import AVFoundation
import os.log
import os.lock
import FramePipelineKit

// MARK: - CMIO Sink Connector

class CMIOSinkConnector {
    private let logger = Logger(subsystem: "com.lukechang.GigEVirtualCamera", category: "CMIOSinkConnector")
    
    // CMIO objects
    private var deviceID: CMIODeviceID?
    private var sinkStreamID: CMIOStreamID?
    private var sinkQueue: CMSimpleQueue?
    
    // Pixel buffer converter
    private let pixelBufferConverter = PixelBufferConverter()
    
    // Configuration
    private let virtualCameraName = "4B59CDEF-BEA6-52E8-06E7-AD1B8E6B29C4"  // Device UID from extension
    private let sinkStreamName = "GigE Camera Input"  // Must match extension's sink stream name
    private let acceptAnySinkStream = true  // Accept any sink stream from our device
    
    // State
    private var isConnected = false
    private var frameCount: UInt64 = 0
    /// Wall-clock time of the most recent "Cannot send frame" warning. Used to
    /// rate-limit the disconnected-state log to at most once per second. The
    /// previous gate (`frameCount % 30 == 0`) keyed on `frameCount`, which only
    /// increments on SUCCESS — so a long disconnected stretch with no successes
    /// either logged every failed attempt (when frameCount was 0 or any multiple
    /// of 30) or none at all. At 250 fps that filled the 1000-entry diagnostics
    /// buffer in under 4 seconds and evicted every other log line, making the
    /// initial connection sequence impossible to retrace from a diagnostic export.
    private var lastNotConnectedLogTime: TimeInterval = 0

    // Mach-uptime ns of last successful CMSimpleQueueEnqueue. Read by the
    // stream-stall watchdog in CameraManager. Protected by `livenessLock`.
    private var _lastSuccessfulSendUptimeNs: UInt64 = 0

    // Last PTS (uptime ns) actually delivered to the sink queue, used for the
    // monotonicity guard. Protected by `livenessLock`.
    private var _lastPtsNs: UInt64 = 0

    // Monotonic-nudge counter for the manifest / debug logs.
    private var _nonMonotonicNudges: UInt64 = 0

    // Successful enqueues since the current sink session started (resets in
    // connectToSinkStream). The stall watchdog uses this to distinguish a
    // genuine stall from "queue filled because no consumer is reading":
    // with no consumer, the first ~6 frames fill the sink's CMSimpleQueue
    // and every subsequent enqueue returns kCMSimpleQueueError_QueueIsFull,
    // so the count stays near the queue capacity. A real consumer drains
    // the queue and the count grows continuously.
    private var _sessionSendCount: UInt64 = 0

    // Mach-uptime ns of the first successful enqueue in the current sink
    // session. Combined with `_sessionSendCount` and
    // `_lastSuccessfulSendUptimeNs` gives a session-average measured fps —
    // the value the diagnostic export reports as the format's effective
    // frame rate. 0 means "no frame yet this session." Protected by
    // `livenessLock`.
    private var _sessionFirstSendUptimeNs: UInt64 = 0

    private var livenessLock = os_unfair_lock()

    /// Thread-safe accessor for the watchdog. Returns 0 if no frame has ever
    /// been sent through this connector.
    var lastSuccessfulSendUptimeNs: UInt64 {
        os_unfair_lock_lock(&livenessLock)
        defer { os_unfair_lock_unlock(&livenessLock) }
        return _lastSuccessfulSendUptimeNs
    }

    /// Total number of times the PTS monotonicity guard had to nudge a
    /// timestamp forward. Should stay at 0 in healthy operation.
    var nonMonotonicNudges: UInt64 {
        os_unfair_lock_lock(&livenessLock)
        defer { os_unfair_lock_unlock(&livenessLock) }
        return _nonMonotonicNudges
    }

    /// Successful enqueues since the current sink session started. The stall
    /// watchdog only flags a stall once this exceeds a threshold roughly an
    /// order of magnitude larger than the sink queue's capacity, so initial
    /// queue-fill (with no consumer attached) doesn't get reported as a
    /// stall — it's just an idle state, no consumer is reading the camera.
    var sessionSendCount: UInt64 {
        os_unfair_lock_lock(&livenessLock)
        defer { os_unfair_lock_unlock(&livenessLock) }
        return _sessionSendCount
    }

    /// Average measured fps over the current sink session, or `nil` if no
    /// frames have flowed yet (or only one frame has, so no interval to
    /// average over). Used by the diagnostics export so the reported format
    /// reflects what the camera is actually delivering — necessary because
    /// some cameras (notably the MRC GVRD-MRC) silently cap below the
    /// requested rate, and `cameraManager.frameRate` only tracks the
    /// configured target.
    var measuredFps: Double? {
        os_unfair_lock_lock(&livenessLock)
        defer { os_unfair_lock_unlock(&livenessLock) }
        guard _sessionFirstSendUptimeNs != 0,
              _lastSuccessfulSendUptimeNs > _sessionFirstSendUptimeNs,
              _sessionSendCount > 1 else { return nil }
        let elapsedNs = _lastSuccessfulSendUptimeNs &- _sessionFirstSendUptimeNs
        let elapsedSec = Double(elapsedNs) / 1_000_000_000.0
        // `_sessionSendCount - 1` intervals between `_sessionSendCount` frames.
        return Double(_sessionSendCount - 1) / elapsedSec
    }

    // Property listener for automatic sink detection
    private var propertyListener: CMIOPropertyListener?

    // Callbacks
    var onSinkStreamAvailable: ((Bool) -> Void)?
    var onConnectionStateChanged: ((Bool) -> Void)?
    
    // Retry handling
    private var connectionRetryTimer: Timer?
    private var connectionRetryCount = 0
    private let maxRetryAttempts = 3
    private let retryDelay: TimeInterval = 2.0

    // Drives initial connection: polls discovery every second until the sink
    // is connected, then stops. This is connection-establishment correctness,
    // NOT a recovery watchdog — once connected it never polls again. Replaces
    // the previous one-shot-at-launch + property-listener-only path that sat
    // silent forever if it missed the initial CMIO change event.
    private var connectPollTimer: Timer?
    private var connectPollAttempts = 0
    
    init() {
        logger.info("CMIOSinkConnector initialized - starting property listener setup")
        NSLog("🔧🔧🔧 CMIOSinkConnector init - target device UID: \(virtualCameraName)")
        print("DEBUG: CMIOSinkConnector initializing...")
        setupPropertyListener()
        
        // Also try manual discovery as backup
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
            NSLog("🔍🔍🔍 Running manual discovery after 2 second delay")
            print("DEBUG: Running manual discovery...")
            self?.tryManualDiscovery()
        }
    }
    
    deinit {
        connectionRetryTimer?.invalidate()
        connectionRetryTimer = nil
        connectPollTimer?.invalidate()
        propertyListener?.stopListening()
    }
    
    // MARK: - Property Listener Setup
    
    private func setupPropertyListener() {
        logger.info("Setting up CMIO property listener...")
        
        propertyListener = CMIOPropertyListener(targetDeviceUID: virtualCameraName)
        
        // Set up callbacks for sink stream discovery
        propertyListener?.onSinkStreamDiscovered = { [weak self] streamInfo in
            guard let self = self else { return }
            
            self.logger.info("🎯 Sink stream discovered via callback: \(streamInfo.name) (ID: \(streamInfo.streamID))")
            
            // Automatically connect to the discovered sink stream
            if !self.isConnected && (self.acceptAnySinkStream || streamInfo.name.contains("Input")) {
                self.deviceID = streamInfo.deviceID
                self.sinkStreamID = streamInfo.streamID
                
                // Try to connect to the sink stream
                DispatchQueue.main.async {
                    self.connectToSinkStream(streamID: streamInfo.streamID, deviceID: streamInfo.deviceID)
                }
            }
        }
        
        propertyListener?.onSinkStreamRemoved = { [weak self] streamID in
            guard let self = self else { return }
            
            if streamID == self.sinkStreamID {
                self.logger.warning("Sink stream was removed")
                self.handleDisconnection()
            }
        }
        
        propertyListener?.onDeviceDiscovered = { [weak self] deviceID, uid in
            guard let self = self else { return }
            
            self.logger.info("Virtual camera device discovered: \(uid)")
            self.onSinkStreamAvailable?(true)
        }
        
        propertyListener?.onDeviceRemoved = { [weak self] deviceID in
            guard let self = self else { return }
            
            if deviceID == self.deviceID {
                self.logger.warning("Virtual camera device was removed")
                self.handleDisconnection()
            }
        }
        
        // Start listening
        do {
            try propertyListener?.startListening()
            logger.info("CMIO property listener started successfully")
        } catch {
            logger.error("Failed to start property listener: \(error)")
        }
    }
    
    // MARK: - Public Interface

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

    func disconnect() {
        handleDisconnection()
    }
    
    // MARK: - Private Connection Methods
    
    @discardableResult
    private func connectToSinkStream(streamID: CMIOStreamID, deviceID: CMIODeviceID) -> Bool {
        logger.info("Attempting to connect to sink stream ID: \(streamID) on device: \(deviceID)")
        
        // Cancel any pending retry timer
        connectionRetryTimer?.invalidate()
        connectionRetryTimer = nil
        
        // 1. Get the buffer queue for the sink stream
        guard let queue = getBufferQueue(streamID: streamID) else {
            logger.error("Failed to get buffer queue for sink stream - attempt \(self.connectionRetryCount + 1)/\(self.maxRetryAttempts)")
            scheduleRetryIfNeeded(streamID: streamID, deviceID: deviceID)
            return false
        }
        
        self.sinkQueue = queue
        logger.info("Successfully obtained buffer queue")
        
        // 2. Start the stream
        guard startStream(deviceID: deviceID, streamID: streamID) else {
            logger.error("Failed to start sink stream - attempt \(self.connectionRetryCount + 1)/\(self.maxRetryAttempts)")
            self.sinkQueue = nil  // Clear the queue since we couldn't start
            scheduleRetryIfNeeded(streamID: streamID, deviceID: deviceID)
            return false
        }
        
        // Success! Reset liveness/monotonicity state so a new session starts
        // from a clean slate -- otherwise the next session would see a stale
        // _lastPtsNs and nudge every frame, and a stale _lastSuccessfulSendUptimeNs
        // from a previous session could spuriously clear/trigger the watchdog.
        os_unfair_lock_lock(&livenessLock)
        _lastPtsNs = 0
        _lastSuccessfulSendUptimeNs = 0
        _nonMonotonicNudges = 0
        _sessionSendCount = 0
        _sessionFirstSendUptimeNs = 0
        os_unfair_lock_unlock(&livenessLock)

        isConnected = true
        stopConnectPolling()
        connectionRetryCount = 0  // Reset retry count on success
        logger.info("✅ Successfully connected to virtual camera sink stream via property listener!")
        
        // Notify callbacks
        onConnectionStateChanged?(true)

        return true
    }
    
    private func scheduleRetryIfNeeded(streamID: CMIOStreamID, deviceID: CMIODeviceID) {
        connectionRetryCount += 1
        
        if connectionRetryCount < maxRetryAttempts {
            logger.info("Scheduling retry #\(self.connectionRetryCount) in \(self.retryDelay) seconds...")
            
            connectionRetryTimer = Timer.scheduledTimer(withTimeInterval: retryDelay, repeats: false) { [weak self] _ in
                guard let self = self else { return }
                
                self.logger.info("Retrying connection to sink stream...")
                _ = self.connectToSinkStream(streamID: streamID, deviceID: deviceID)
            }
        } else {
            logger.error("❌ Max retry attempts reached. Failed to connect to sink stream.")
            connectionRetryCount = 0  // Reset for next time
            
            // Notify failure
            onConnectionStateChanged?(false)
        }
    }
    
    private func handleDisconnection() {
        guard isConnected else { return }
        
        logger.info("Handling disconnection...")
        
        // Stop the stream if we have the IDs
        if let deviceID = deviceID, let streamID = sinkStreamID {
            let result = CMIODeviceStopStream(deviceID, streamID)
            if result == kCMIOHardwareNoError {
                logger.info("Successfully stopped sink stream")
            } else {
                logger.error("Failed to stop sink stream: \(result)")
            }
        }
        
        // Clear references
        self.sinkQueue = nil
        self.sinkStreamID = nil
        self.deviceID = nil
        self.isConnected = false

        // Notify callbacks
        onConnectionStateChanged?(false)
        onSinkStreamAvailable?(false)
    }
    
    @discardableResult
    func sendFrame(_ pixelBuffer: CVPixelBuffer, timestamp: FrameTimestamp) -> Bool {
        guard isConnected, let queue = sinkQueue else {
            // Time-based throttle: at most one warning per second regardless of
            // frame rate. The race on `lastNotConnectedLogTime` is benign —
            // worst case is a duplicate log every now and then.
            let now = Date().timeIntervalSince1970
            if now - lastNotConnectedLogTime >= 1.0 {
                lastNotConnectedLogTime = now
                logger.warning("Cannot send frame - not connected to sink")
            }
            return false
        }

        // Convert BGRA to YUV420 for video streaming (also scales to HD if needed)
        guard let yuvBuffer = pixelBufferConverter.convertToHD(pixelBuffer) else {
            logger.error("Failed to convert pixel buffer to YUV")
            return false
        }

        // Create CMSampleBuffer from converted pixel buffer
        guard let sampleBuffer = createSampleBuffer(from: yuvBuffer, timestamp: timestamp) else {
            logger.error("Failed to create sample buffer from pixel buffer")
            return false
        }

        // Enqueue the buffer. `passRetained` produces a +1 reference that is
        // transferred to CMIO IF the enqueue succeeds; on failure we own the
        // reference and MUST release it or the sample buffer leaks. At a 6-
        // frame queue and 30 fps streaming, queue-full is not rare during
        // brief consumer stalls and the leak is observable in long sessions.
        //
        // Important: `Unmanaged` is a struct value type and `.toOpaque()`
        // does NOT consume it -- it just returns the opaque pointer. So
        // the `unmanaged` value below is still well-defined and safe to
        // `.release()` in the failure branch. A future refactor that
        // inlines `Unmanaged.passRetained(sampleBuffer).toOpaque()` and
        // tries to release a separately captured value would double-free.
        let unmanaged = Unmanaged.passRetained(sampleBuffer)
        let result = CMSimpleQueueEnqueue(queue, element: unmanaged.toOpaque())

        if result == noErr {
            frameCount += 1

            // Update liveness so the watchdog knows frames are flowing, and
            // bump the session send count so it can distinguish a true stall
            // from initial queue-fill with no consumer attached.
            let nowUptimeNs = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
            os_unfair_lock_lock(&livenessLock)
            _lastSuccessfulSendUptimeNs = nowUptimeNs
            if _sessionFirstSendUptimeNs == 0 {
                _sessionFirstSendUptimeNs = nowUptimeNs
            }
            _sessionSendCount &+= 1
            os_unfair_lock_unlock(&livenessLock)

            // Log periodically
            if frameCount % 30 == 0 {
                let width = CVPixelBufferGetWidth(yuvBuffer)
                let height = CVPixelBufferGetHeight(yuvBuffer)
                let pixelFormat = CVPixelBufferGetPixelFormatType(yuvBuffer)
                let formatString = pixelFormat == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange ? "YUV420v" : "Unknown(\(pixelFormat))"
                logger.info("📤 Sent frame #\(self.frameCount) to sink | \(width)x\(height) | Format: \(formatString)")
            }
        } else {
            // Balance the retain so the sample buffer doesn't leak.
            unmanaged.release()
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
    
    // MARK: - Private Methods
    
    private func getBufferQueue(streamID: CMIOStreamID) -> CMSimpleQueue? {
        var queueUnmanaged: Unmanaged<CMSimpleQueue>?
        
        let result = CMIOStreamCopyBufferQueue(
            streamID,
            { (streamID, token, refCon) in
                // Queue alteration callback - not needed for simple enqueueing
            },
            nil,
            &queueUnmanaged
        )
        
        guard result == kCMIOHardwareNoError, let queue = queueUnmanaged?.takeRetainedValue() else {
            logger.error("Failed to get buffer queue: \(result)")
            return nil
        }
        
        return queue
    }
    
    private func startStream(deviceID: CMIODeviceID, streamID: CMIOStreamID) -> Bool {
        let result = CMIODeviceStartStream(deviceID, streamID)
        
        if result == kCMIOHardwareNoError {
            logger.info("Successfully started sink stream")
            return true
        } else {
            logger.error("Failed to start sink stream: \(result)")
            return false
        }
    }
    
    private func createSampleBuffer(from pixelBuffer: CVPixelBuffer,
                                    timestamp: FrameTimestamp) -> CMSampleBuffer? {
        // Create format description
        var formatDescription: CMVideoFormatDescription?
        let formatResult = CMVideoFormatDescriptionCreateForImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: pixelBuffer,
            formatDescriptionOut: &formatDescription
        )
        
        guard formatResult == noErr, let format = formatDescription else {
            logger.error("Failed to create format description: \(formatResult)")
            return nil
        }
        
        // Use the capture-time host timestamp (CLOCK_UPTIME_RAW ns, same mach
        // timebase as the host time clock) so the presentation timeline reflects
        // when the frame was captured — not when it happened to be processed.
        //
        // Monotonicity guard: CMIO consumers freeze on non-monotonic PTS. If a
        // future regression (Aravis frame-ID reset, clock adjustment, duplicate)
        // produces a PTS <= the last one we sent, nudge it forward by 1ns rather
        // than dropping the frame. Track how often we have to do this so it can
        // surface in the manifest and debug logs.
        var ptsNs = timestamp.hostTimestampNs
        os_unfair_lock_lock(&livenessLock)
        if ptsNs <= _lastPtsNs {
            ptsNs = _lastPtsNs &+ 1
            _nonMonotonicNudges &+= 1
        }
        _lastPtsNs = ptsNs
        os_unfair_lock_unlock(&livenessLock)

        var timingInfo = CMSampleTimingInfo(
            duration: CMTime.invalid,
            presentationTimeStamp: CMTimeMake(value: Int64(bitPattern: ptsNs),
                                              timescale: 1_000_000_000),
            decodeTimeStamp: CMTime.invalid
        )
        
        // Create sample buffer
        var sampleBuffer: CMSampleBuffer?
        let sampleResult = CMSampleBufferCreateReadyWithImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: pixelBuffer,
            formatDescription: format,
            sampleTiming: &timingInfo,
            sampleBufferOut: &sampleBuffer
        )
        
        guard sampleResult == noErr else {
            logger.error("Failed to create sample buffer: \(sampleResult)")
            return nil
        }
        
        return sampleBuffer
    }
    
    // MARK: - Manual Discovery
    
    private func tryManualDiscovery() {
        logger.info("🔍 Attempting manual CMIO device discovery...")
        NSLog("🔍 CMIOSinkConnector - attempting manual discovery")
        
        // Get all devices
        var prop = CMIOObjectPropertyAddress(
            mSelector: CMIOObjectPropertySelector(kCMIOHardwarePropertyDevices),
            mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
            mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain)
        )
        
        var dataSize: UInt32 = 0
        var result = CMIOObjectGetPropertyDataSize(
            CMIOObjectID(kCMIOObjectSystemObject),
            &prop,
            0,
            nil,
            &dataSize
        )
        
        guard result == kCMIOHardwareNoError else {
            logger.error("Failed to get device list size: \(result)")
            return
        }
        
        let deviceCount = Int(dataSize) / MemoryLayout<CMIODeviceID>.size
        var deviceIDs = Array(repeating: CMIODeviceID(0), count: deviceCount)
        
        result = CMIOObjectGetPropertyData(
            CMIOObjectID(kCMIOObjectSystemObject),
            &prop,
            0,
            nil,
            dataSize,
            &dataSize,
            &deviceIDs
        )
        
        guard result == kCMIOHardwareNoError else {
            logger.error("Failed to get device list: \(result)")
            return
        }
        
        logger.info("Found \(deviceCount) CMIO devices")
        
        // Check each device
        for deviceID in deviceIDs {
            // Get device UID
            var uidProp = CMIOObjectPropertyAddress(
                mSelector: CMIOObjectPropertySelector(kCMIODevicePropertyDeviceUID),
                mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
                mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain)
            )
            
            var uidSize: UInt32 = 0
            result = CMIOObjectGetPropertyDataSize(deviceID, &uidProp, 0, nil, &uidSize)
            
            if result == kCMIOHardwareNoError {
                let uidPtr = UnsafeMutablePointer<CFString?>.allocate(capacity: 1)
                defer { uidPtr.deallocate() }
                
                result = CMIOObjectGetPropertyData(deviceID, &uidProp, 0, nil, uidSize, &uidSize, uidPtr)
                
                if result == kCMIOHardwareNoError, let uid = uidPtr.pointee as String? {
                    logger.info("Device \(deviceID): UID = \(uid)")
                    
                    if uid == virtualCameraName {
                        logger.info("🎯 Found target virtual camera device!")
                        NSLog("🎯 Found virtual camera - device ID: \(deviceID)")
                        
                        // Try to find sink stream
                        findSinkStream(on: deviceID)
                    }
                }
            }
        }
    }
    
    private func findSinkStream(on deviceID: CMIODeviceID) {
        logger.info("Looking for sink stream on device \(deviceID)...")
        
        var streamsProp = CMIOObjectPropertyAddress(
            mSelector: CMIOObjectPropertySelector(kCMIODevicePropertyStreams),
            mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
            mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain)
        )
        
        var dataSize: UInt32 = 0
        var result = CMIOObjectGetPropertyDataSize(deviceID, &streamsProp, 0, nil, &dataSize)
        
        guard result == kCMIOHardwareNoError else {
            logger.error("Failed to get stream list size: \(result)")
            return
        }
        
        let streamCount = Int(dataSize) / MemoryLayout<CMIOStreamID>.size
        var streamIDs = Array(repeating: CMIOStreamID(0), count: streamCount)
        
        result = CMIOObjectGetPropertyData(deviceID, &streamsProp, 0, nil, dataSize, &dataSize, &streamIDs)
        
        guard result == kCMIOHardwareNoError else {
            logger.error("Failed to get stream list: \(result)")
            return
        }
        
        logger.info("Found \(streamCount) streams")
        
        // Check each stream
        for streamID in streamIDs {
            // Get stream direction
            var dirProp = CMIOObjectPropertyAddress(
                mSelector: CMIOObjectPropertySelector(kCMIOStreamPropertyDirection),
                mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
                mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain)
            )
            
            var direction: UInt32 = 0
            let dirSize = UInt32(MemoryLayout<UInt32>.size)
            
            result = CMIOObjectGetPropertyData(streamID, &dirProp, 0, nil, dirSize, &dataSize, &direction)
            
            if result == kCMIOHardwareNoError && direction == 0 { // 0 = sink
                logger.info("🎯 Found sink stream! ID: \(streamID)")
                NSLog("🎯 Found sink stream - attempting connection to stream ID: \(streamID)")
                
                // Store the IDs and try to connect
                self.deviceID = deviceID
                self.sinkStreamID = streamID
                
                // Try to connect
                DispatchQueue.main.async {
                    _ = self.connectToSinkStream(streamID: streamID, deviceID: deviceID)
                }
                
                break
            }
        }
    }
}