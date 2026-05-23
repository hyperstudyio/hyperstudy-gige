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

// MARK: - Stream State Monitor

class StreamStateMonitor {
    private let logger = Logger(subsystem: "com.lukechang.GigEVirtualCamera", category: "StreamStateMonitor")
    private let appGroupID = "group.S368GH6KF7.com.lukechang.GigEVirtualCamera"
    private var observer: NSObjectProtocol?
    private var timer: Timer?
    
    private var groupDefaults: UserDefaults? {
        UserDefaults(suiteName: appGroupID)
    }
    
    func startMonitoring(onStreamStateChange: @escaping (Bool) -> Void) {
        // Monitor UserDefaults changes
        observer = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: groupDefaults,
            queue: .main
        ) { [weak self] _ in
            self?.checkStreamState(onStreamStateChange: onStreamStateChange)
        }
        
        // Also poll periodically as backup
        timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            self?.checkStreamState(onStreamStateChange: onStreamStateChange)
        }
        
        // Check initial state
        checkStreamState(onStreamStateChange: onStreamStateChange)
    }
    
    func stopMonitoring() {
        if let observer = observer {
            NotificationCenter.default.removeObserver(observer)
        }
        timer?.invalidate()
        timer = nil
    }
    
    private func checkStreamState(onStreamStateChange: @escaping (Bool) -> Void) {
        guard let state = groupDefaults?.dictionary(forKey: "StreamState"),
              let isActive = state["streamActive"] as? Bool else {
            return
        }
        
        onStreamStateChange(isActive)
    }
}

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

    // Mach-uptime ns of last successful CMSimpleQueueEnqueue. Read by the
    // stream-stall watchdog in CameraManager. Protected by `livenessLock`.
    private var _lastSuccessfulSendUptimeNs: UInt64 = 0

    // Last PTS (uptime ns) actually delivered to the sink queue, used for the
    // monotonicity guard. Protected by `livenessLock`.
    private var _lastPtsNs: UInt64 = 0

    // Monotonic-nudge counter for the manifest / debug logs.
    private var _nonMonotonicNudges: UInt64 = 0

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

    // Stream state monitoring
    private let streamStateMonitor = StreamStateMonitor()

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
        propertyListener?.stopListening()
        streamStateMonitor.stopMonitoring()
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
    
    func connect() -> Bool {
        logger.info("Connect called - waiting for sink stream discovery via property listener...")
        
        // The actual connection will happen automatically when the sink stream is discovered
        // via the property listener callback. This method now just ensures the listener is active.
        
        if propertyListener == nil {
            setupPropertyListener()
        }
        
        // If we already have a discovered sink stream, connect to it
        if let streamID = sinkStreamID, let deviceID = deviceID {
            return connectToSinkStream(streamID: streamID, deviceID: deviceID)
        }
        
        // Otherwise, connection will happen automatically when sink is discovered
        logger.info("Waiting for sink stream to be discovered...")
        return false
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
        os_unfair_lock_unlock(&livenessLock)

        isConnected = true
        connectionRetryCount = 0  // Reset retry count on success
        logger.info("✅ Successfully connected to virtual camera sink stream via property listener!")
        
        // Notify callbacks
        onConnectionStateChanged?(true)
        
        // Start monitoring stream state
        startStreamStateMonitoring()
        
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
        
        // Stop monitoring
        streamStateMonitor.stopMonitoring()
        
        // Notify callbacks
        onConnectionStateChanged?(false)
        onSinkStreamAvailable?(false)
    }
    
    @discardableResult
    func sendFrame(_ pixelBuffer: CVPixelBuffer, timestamp: FrameTimestamp) -> Bool {
        guard isConnected, let queue = sinkQueue else {
            if frameCount % 30 == 0 {
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

        // Enqueue the buffer
        let result = CMSimpleQueueEnqueue(queue, element: Unmanaged.passRetained(sampleBuffer).toOpaque())

        if result == noErr {
            frameCount += 1

            // Update liveness so the watchdog knows frames are flowing.
            let nowUptimeNs = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
            os_unfair_lock_lock(&livenessLock)
            _lastSuccessfulSendUptimeNs = nowUptimeNs
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
    
    // MARK: - Stream State Monitoring
    
    private func startStreamStateMonitoring() {
        streamStateMonitor.startMonitoring { [weak self] isActive in
            if isActive {
                self?.logger.info("Extension signaled it needs frames")
                // Notify CameraManager to handle the stream state change
                NotificationCenter.default.post(name: NSNotification.Name("StreamStateChanged"), object: nil)
            } else {
                self?.logger.info("Extension signaled to stop frames")
                NotificationCenter.default.post(name: NSNotification.Name("StreamStateChanged"), object: nil)
            }
        }
    }
}