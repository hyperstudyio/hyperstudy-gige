//
//  CameraManager.swift
//  GigEVirtualCamera
//
//  Created on 6/24/25.
//

import Foundation
import SwiftUI
import Combine
import os.log
import FramePipelineKit

// UserDefaults extension for KVO
extension UserDefaults {
    @objc dynamic var StreamState: [String: Any]? {
        return dictionary(forKey: "StreamState")
    }
}

@MainActor
class CameraManager: NSObject, ObservableObject {
    static let shared = CameraManager()
    
    // MARK: - Published Properties
    @Published var isConnected = false
    @Published var cameraModel = "Unknown"
    @Published var connectionState = "Idle" // "Idle", "Connecting", "Connected", "Failed"
    @Published var connectionAttempts = 0
    @Published var currentFormat = "1920×1080 @ 30fps"
    @Published var availableFormats = [
        "Auto (Camera Native)",
        "1920×1080 @ 30fps",
        "1280×720 @ 30fps", 
        "640×480 @ 30fps",
        "512×512 @ 30fps"
    ]
    @Published var selectedFormatIndex = 0 {
        didSet {
            if selectedFormatIndex != oldValue {
                updateSelectedFormat()
            }
        }
    }
    @Published var availableCameras: [AravisCamera] = []
    @Published var currentPixelFormat = "Auto" {
        didSet {
            // Update the GigECameraManager when format changes
            if currentPixelFormat != oldValue {
                let gigEManager = GigECameraManager.shared
                gigEManager.setPixelFormat(currentPixelFormat)
                logger.info("Changed pixel format to: \(self.currentPixelFormat)")
            }
        }
    }
    @Published var availablePixelFormats = ["Auto", "Bayer GR8", "Bayer RG8", "Bayer GB8", "Bayer BG8", "Mono8", "RGB8"]
    
    // Camera controls
    @Published var exposureTime: Double = 10000 { // microseconds (10ms default)
        didSet {
            if exposureTime != oldValue && isConnected {
                updateExposureTime()
            }
        }
    }
    @Published var gain: Double = 1.0 { // 1.0 = no gain
        didSet {
            if gain != oldValue && isConnected {
                updateGain()
            }
        }
    }
    @Published var frameRate: Double = 30.0 {
        didSet {
            if frameRate != oldValue && isConnected {
                updateFrameRate()
            }
        }
    }
    
    // Camera capability flags
    @Published var exposureTimeAvailable = false
    @Published var exposureTimeMin: Double = 100
    @Published var exposureTimeMax: Double = 100000
    @Published var gainAvailable = false
    @Published var gainMin: Double = 0.5
    @Published var gainMax: Double = 16.0
    @Published var frameRateAvailable = false
    @Published var frameRateMin: Double = 1
    @Published var frameRateMax: Double = 60
    @Published var selectedCameraId: String? = nil {
        didSet {
            // Only connect if the selection actually changed and we're not already connected to this camera
            if selectedCameraId != oldValue {
                if let cameraId = selectedCameraId {
                    let gigEManager = GigECameraManager.shared
                    if gigEManager.currentCamera?.deviceId != cameraId {
                        // Reset status immediately to show we're trying
                        isConnected = false
                        cameraModel = "Connecting..."
                        connectToCamera(withId: cameraId)
                    }
                } else {
                    disconnectCamera()
                }
            }
        }
    }
    @Published var isShowingPreview = false
    @Published var isFrameSenderConnected = false  // Will be set true when sink connects
    
    // MARK: - Private Properties
    private let sinkConnector = CMIOSinkConnector()
    private var frameCount: Int = 0
    private var streamStateObserver: NSKeyValueObservation?
    private let appGroupDefaults = UserDefaults(suiteName: "group.S368GH6KF7.com.lukechang.GigEVirtualCamera")
    private let networkMonitor = NetworkInterfaceMonitor()
    private var lastDiscoveryTime = Date.distantPast
    
    // MARK: - Computed Properties
    var statusText: String {
        if isConnected {
            return "Connected"
        } else {
            return "No Camera"
        }
    }
    
    var statusColor: Color {
        if isConnected {
            return DesignSystem.Colors.statusGreen
        } else {
            return DesignSystem.Colors.statusOrange
        }
    }
    
    private let logger = Logger(subsystem: CameraConstants.BundleID.app, category: "CameraManager")
    
    // Format definitions matching the strings
    private let formatSpecs: [(width: Int, height: Int, fps: Int)] = [
        (0, 0, 0),  // Auto - will use camera native resolution
        (1920, 1080, 30),
        (1280, 720, 30),
        (640, 480, 30),
        (512, 512, 30)
    ]
    
    // MARK: - Initialization
    private override init() {
        super.init()
        logger.info("CameraManager init called")
        
        // Clear any saved camera preferences to ensure fresh start
        UserDefaults.standard.removeObject(forKey: CameraConstants.UserDefaultsKeys.lastConnectedCamera)
        UserDefaults.standard.removeObject(forKey: "LastConnectedCameraID")
        
        // Initialize format in shared UserDefaults
        if let groupDefaults = UserDefaults(suiteName: "group.S368GH6KF7.com.lukechang.GigEVirtualCamera") {
            // Set default format if not already set
            if groupDefaults.object(forKey: "SelectedFormatWidth") == nil {
                groupDefaults.set(1920, forKey: "SelectedFormatWidth")
                groupDefaults.set(1080, forKey: "SelectedFormatHeight") 
                groupDefaults.set(30, forKey: "SelectedFormatFPS")
                groupDefaults.synchronize()
            }
        }
        
        setupNotifications()
        setupFrameHandler()  // Set up frame handler for IOSurface writer
        
        // Start discovery immediately on init
        logger.info("Starting immediate camera discovery on init")
        GigECameraManager.shared.discoverCameras()
        
        // Also check connection status after a short delay
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            self.checkCameraConnection()
        }
        
        // Setup network monitoring for camera hot-plugging
        setupNetworkMonitoring()
    }
    
    deinit {
        streamStateObserver?.invalidate()
        networkMonitor.stop()
    }
    
    // MARK: - Private Methods
    private var cancellables = Set<AnyCancellable>()
    
    private func setupNetworkMonitoring() {
        networkMonitor.onNetworkChange = { [weak self] in
            guard let self = self else { return }
            
            // Debounce discovery calls - don't run more than once per 2 seconds
            let timeSinceLastDiscovery = Date().timeIntervalSince(self.lastDiscoveryTime)
            guard timeSinceLastDiscovery > 2.0 else {
                self.logger.info("Skipping discovery - too soon since last check (\(timeSinceLastDiscovery)s)")
                return
            }
            
            self.lastDiscoveryTime = Date()
            self.logger.info("Network change detected - triggering camera discovery")
            
            // Run discovery
            GigECameraManager.shared.discoverCameras()
            
            // If we lost connection, also check connection status
            if self.isConnected {
                self.checkCameraConnection()
            }
        }
    }
    
    
    private func checkCameraConnection() {
        print("CameraManager: checkCameraConnection() called")
        
        // Check actual camera connection through GigECameraManager
        let gigEManager = GigECameraManager.shared
        
        print("CameraManager: GigECameraManager.isConnected = \(gigEManager.isConnected)")
        print("CameraManager: GigECameraManager.availableCameras.count = \(gigEManager.availableCameras.count)")
        
        // Update available cameras
        availableCameras = gigEManager.availableCameras
        
        if gigEManager.isConnected, let camera = gigEManager.currentCamera {
            print("CameraManager: Connected to camera: \(camera.modelName)")
            cameraModel = camera.modelName
            isConnected = true
            selectedCameraId = camera.deviceId
            
            // Don't save camera selection - let user choose each time
        } else {
            print("CameraManager: Not connected, triggering camera discovery...")
            isConnected = false
            
            // Try to discover cameras
            gigEManager.discoverCameras()
            
            // Don't auto-reconnect - let user manually select camera
        }
        
        // Listen for camera list updates
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleCameraListUpdate),
            name: NSNotification.Name("GigECamerasDiscovered"),
            object: nil
        )
    }
    
    private func connectToCamera(withId cameraId: String) {
        let gigEManager = GigECameraManager.shared
        
        logger.info("Attempting to connect to camera: \(cameraId)")
        connectionState = "Connecting"
        connectionAttempts += 1
        
        if let camera = availableCameras.first(where: { $0.deviceId == cameraId }) {
            logger.info("Found camera in list: \(camera.modelName)")
            cameraModel = "Connecting to \(camera.modelName)..."
            
            // Move connection to background thread to avoid blocking UI
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                // Disconnect any existing camera first
                if gigEManager.isConnected {
                    self?.logger.info("Disconnecting current camera before connecting to new one")
                    gigEManager.disconnect()
                    Thread.sleep(forTimeInterval: 1.0) // Give more time for cleanup
                }
                
                // Add a small delay to let the network settle
                Thread.sleep(forTimeInterval: 0.5)
                
                // Attempt connection on background thread
                self?.logger.info("Calling connect for \(camera.modelName)")
                gigEManager.connect(to: camera)
                
                // Update UI on main thread
                DispatchQueue.main.async {
                    self?.checkConnectionStatus(for: camera, cameraId: cameraId)
                }
            }
        } else {
            logger.error("Camera not found in available cameras list")
            connectionState = "Failed"
            cameraModel = "Camera not found"
        }
    }
    
    private func checkConnectionStatus(for camera: AravisCamera, cameraId: String) {
        let gigEManager = GigECameraManager.shared
        
        // Schedule a check after a delay - GigE cameras need more time
        DispatchQueue.main.asyncAfter(deadline: .now() + 5.0) { [weak self] in
            if gigEManager.isConnected {
                self?.logger.info("✅ Connection successful!")
                self?.connectionState = "Connected"
                self?.cameraModel = camera.modelName
                self?.isConnected = true
                
                // Load camera settings
                self?.loadCameraSettings()
                
                // Apply current format if not Auto
                if let self = self, self.selectedFormatIndex != 0 {
                    let format = self.formatSpecs[self.selectedFormatIndex]
                    let resolution = CGSize(width: format.width, height: format.height)
                    if GigECameraManager.shared.setResolution(resolution) {
                        self.logger.info("Applied format on connection: \(format.width)×\(format.height)")
                    }
                    // Also apply frame rate
                    GigECameraManager.shared.setFrameRate(Double(format.fps))
                }
                
                // Ensure sink is connected before starting streaming
                if self?.isFrameSenderConnected == true {
                    if !gigEManager.isStreaming {
                        self?.logger.info("Starting streaming (sink already connected)...")
                        gigEManager.startStreaming()
                    }
                } else {
                    self?.logger.info("Camera connected but sink not ready - waiting for sink connection...")
                    // The sink connector callbacks will start streaming when ready
                }
            } else {
                self?.logger.warning("⚠️ First connection attempt failed, retrying...")
                self?.cameraModel = "Retrying connection..."
                
                // Retry connection on background thread
                DispatchQueue.global(qos: .userInitiated).async {
                    // Wait a bit before retry
                    Thread.sleep(forTimeInterval: 1.0)
                    
                    gigEManager.connect(to: camera)
                    
                    // Final check after retry - give more time
                    DispatchQueue.main.asyncAfter(deadline: .now() + 5.0) {
                        if gigEManager.isConnected {
                            self?.logger.info("✅ Connection successful after retry")
                            self?.connectionState = "Connected"
                            self?.cameraModel = camera.modelName
                            self?.isConnected = true
                            
                            // Load camera settings
                            self?.loadCameraSettings()
                            
                            // Apply current format if not Auto
                            if let self = self, self.selectedFormatIndex != 0 {
                                let format = self.formatSpecs[self.selectedFormatIndex]
                                let resolution = CGSize(width: format.width, height: format.height)
                                if GigECameraManager.shared.setResolution(resolution) {
                                    self.logger.info("Applied format on retry connection: \(format.width)×\(format.height)")
                                }
                                // Also apply frame rate
                                GigECameraManager.shared.setFrameRate(Double(format.fps))
                            }
                            
                            // Ensure sink is connected before starting streaming
                            if self?.isFrameSenderConnected == true {
                                if !gigEManager.isStreaming {
                                    self?.logger.info("Starting streaming after retry (sink already connected)...")
                                    gigEManager.startStreaming()
                                }
                            } else {
                                self?.logger.info("Camera connected after retry but sink not ready - waiting for sink connection...")
                                // The sink connector callbacks will start streaming when ready
                            }
                        } else {
                            self?.logger.error("❌ Failed to connect after \(self?.connectionAttempts ?? 0) attempts")
                            self?.connectionState = "Failed"
                            self?.cameraModel = "Connection failed"
                            self?.isConnected = false
                            
                            // Don't reset selection - let user retry manually
                            // self?.selectedCameraId = nil
                        }
                    }
                }
            }
        }
    }
    
    private func disconnectCamera() {
        let gigEManager = GigECameraManager.shared
        gigEManager.disconnect()
        isConnected = false
        cameraModel = "Unknown"
        connectionState = "Idle"
        connectionAttempts = 0
    }
    
    @objc private func handleCameraListUpdate() {
        let gigEManager = GigECameraManager.shared
        availableCameras = gigEManager.availableCameras
        
        logger.info("Camera list updated: \(self.availableCameras.count) cameras found")
        
        // Don't auto-select cameras - let user manually choose
    }
    
    private func setupNotifications() {
        // Listen for camera connection notifications from extension
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleCameraConnection(_:)),
            name: CameraConstants.Notifications.cameraDidConnect,
            object: nil
        )
        
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleCameraDisconnection(_:)),
            name: CameraConstants.Notifications.cameraDidDisconnect,
            object: nil
        )
        
        // Listen for GigECameraManager state changes
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleGigECameraStateChange),
            name: NSNotification.Name("GigECameraStateChanged"),
            object: nil
        )
        
        // Listen for connection failures
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleConnectionFailure),
            name: NSNotification.Name("GigECameraConnectionFailed"),
            object: nil
        )
        
        // Listen for manual trigger to connect frame sender
        DistributedNotificationCenter.default().addObserver(
            self,
            selector: #selector(handleManualTrigger),
            name: NSNotification.Name("TriggerFrameSenderConnection"),
            object: nil
        )
        
        // Monitor App Group UserDefaults for stream state changes
        if let defaults = appGroupDefaults {
            // Use KVO to monitor changes
            streamStateObserver = defaults.observe(\.StreamState, options: [.new, .initial]) { [weak self] _, _ in
                self?.handleStreamStateChange()
            }
            
            // Also use notification as backup
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(handleStreamStateChange),
                name: UserDefaults.didChangeNotification,
                object: defaults
            )
            
            // Check initial state
            handleStreamStateChange()
        }
    }
    
    @objc private func handleCameraConnection(_ notification: Notification) {
        if let info = notification.userInfo,
           let model = info["model"] as? String {
            cameraModel = model
            isConnected = true
            
            // Don't save camera selection - let user choose each time
        }
    }
    
    @objc private func handleCameraDisconnection(_ notification: Notification) {
        isConnected = false
    }
    
    @objc private func handleGigECameraStateChange() {
        let gigEManager = GigECameraManager.shared
        
        if gigEManager.isConnected, let camera = gigEManager.currentCamera {
            isConnected = true
            cameraModel = camera.modelName
            // Only update selectedCameraId if it's different to avoid triggering reconnection
            if selectedCameraId != camera.deviceId {
                selectedCameraId = camera.deviceId
            }
            
            // Auto-start streaming if connected but not streaming (producer model)
            if !gigEManager.isStreaming {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    if gigEManager.isConnected && !gigEManager.isStreaming {
                        self.logger.info("Auto-starting streaming on state change (producer model)...")
                        gigEManager.startStreaming()
                    }
                }
            }
        } else {
            isConnected = false
            // Don't clear selectedCameraId - keep user's selection even if disconnected
        }
    }
    
    @objc private func handleManualTrigger() {
        logger.info("Manual trigger received - starting streaming")
        
        // If connected to camera but not streaming, start streaming
        if isConnected && !GigECameraManager.shared.isStreaming {
            logger.info("Starting camera streaming...")
            GigECameraManager.shared.startStreaming()
        }
    }
    
    @objc private func handleConnectionFailure(_ notification: Notification) {
        logger.error("Camera connection failed")
        
        // Reset UI state
        isConnected = false
        cameraModel = "Unknown"
        
        // Optionally show error to user
        if let userInfo = notification.userInfo,
           let camera = userInfo["camera"] as? AravisCamera {
            logger.error("Failed to connect to: \(camera.modelName)")
        }
    }
    
    @objc private func handleStreamStateChange() {
        // Check if extension is requesting frames
        guard let defaults = UserDefaults(suiteName: "group.S368GH6KF7.com.lukechang.GigEVirtualCamera"),
              let state = defaults.dictionary(forKey: "StreamState") else {
            return
        }
        
        // Check for new client connection
        if let newClientConnected = state["newClientConnected"] as? Bool, newClientConnected {
            logger.info("New client connected - restarting camera stream to ensure frames flow")
            
            // Clear the flag
            var updatedState = state
            updatedState["newClientConnected"] = false
            defaults.set(updatedState, forKey: "StreamState")
            defaults.synchronize()
            
            // If camera is connected, ensure sink connection and restart streaming
            if isConnected {
                let gigEManager = GigECameraManager.shared
                
                // First ensure sink is connected
                if !isFrameSenderConnected {
                    logger.info("New client connected but sink not ready - reconnecting sink first...")
                    sinkConnector.disconnect()
                    let connected = sinkConnector.connect()
                    logger.info("Sink reconnection attempt returned: \(connected)")
                    
                    // Give sink time to connect before starting stream
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                        if self.isFrameSenderConnected {
                            self.logger.info("Sink connected, starting stream for new client...")
                            gigEManager.startStreaming()
                        } else {
                            self.logger.warning("Sink still not connected after reconnection attempt")
                            // Try streaming anyway
                            gigEManager.startStreaming()
                        }
                    }
                } else {
                    // Sink already connected, just restart streaming
                    if gigEManager.isStreaming {
                        logger.info("Stopping current stream...")
                        gigEManager.stopStreaming()
                        
                        // Small delay before restarting
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                            self.logger.info("Restarting stream for new client...")
                            gigEManager.startStreaming()
                        }
                    } else {
                        logger.info("Starting stream for new client...")
                        gigEManager.startStreaming()
                    }
                }
            }
        }
        
        // Check if streaming is active
        if let isActive = state["streamActive"] as? Bool {
            if isActive {
                logger.info("Extension requesting frames")
                
                // The property listener will handle sink connection automatically
                // We just need to ensure Aravis is streaming
                if isConnected && !GigECameraManager.shared.isStreaming {
                    logger.info("Starting Aravis streaming in response to extension request")
                    GigECameraManager.shared.startStreaming()
                }
            } else {
                logger.info("Extension stopped requesting frames")
                // Optionally stop streaming
                if GigECameraManager.shared.isStreaming {
                    logger.info("Stopping Aravis streaming")
                    GigECameraManager.shared.stopStreaming()
                }
            }
        }
    }
    
    // MARK: - Preview Methods
    func togglePreview() {
        if isShowingPreview {
            hidePreview()
        } else {
            showPreview()
        }
    }
    
    // MARK: - Public Methods
    
    func refreshCameraList() {
        logger.info("Manual camera refresh requested")
        GigECameraManager.shared.discoverCameras()
    }
    
    func retryConnection() {
        guard let cameraId = selectedCameraId else { return }
        logger.info("Manual connection retry requested")
        connectionAttempts = 0 // Reset counter for manual retry
        connectToCamera(withId: cameraId)
    }
    
    func resetConnection() {
        logger.info("Resetting connection state")
        let gigEManager = GigECameraManager.shared
        
        // Force disconnect
        gigEManager.disconnect()
        
        // Reset state
        isConnected = false
        connectionState = "Idle"
        cameraModel = "Unknown"
        
        // Clear and re-discover
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            self.refreshCameraList()
        }
    }
    
    
    // MARK: - Public Methods for Frame Sender
    func retryFrameSenderConnection() {
        logger.info("Retrying CMIO sink connection...")
        
        // With property listeners, we just need to restart the listener
        sinkConnector.disconnect()
        
        // The property listener will automatically detect and connect when sink stream is available
        logger.info("Property listener will automatically reconnect when sink stream is available")
    }
    
    func testSinkStreamConnection() {  // Keep method name for compatibility
        logger.info("Testing CMIO sink stream connection...")
        
        // The property listener handles connection automatically
        if isFrameSenderConnected {
            logger.info("✅ Already connected to sink stream via property listener")
            sendTestFrame()
        } else {
            logger.info("⏳ Waiting for sink stream discovery via property listener...")
        }
    }
    
    private func sendTestFrame() {
        // Create a test pixel buffer
        let width = 640
        let height = 480
        guard let testBuffer = PixelBufferHelpers.createIOSurfaceBackedPixelBuffer(
            width: width,
            height: height,
            pixelFormat: kCVPixelFormatType_32BGRA
        ) else {
            logger.error("Failed to create test pixel buffer")
            return
        }
        
        // Fill with test pattern
        CVPixelBufferLockBaseAddress(testBuffer, [])
        if let baseAddress = CVPixelBufferGetBaseAddress(testBuffer) {
            let bytesPerRow = CVPixelBufferGetBytesPerRow(testBuffer)
            let pixelData = baseAddress.assumingMemoryBound(to: UInt8.self)
            
            for y in 0..<height {
                for x in 0..<width {
                    let offset = y * bytesPerRow + x * 4
                    pixelData[offset] = 255     // B
                    pixelData[offset + 1] = 0   // G  
                    pixelData[offset + 2] = 0   // R
                    pixelData[offset + 3] = 255 // A
                }
            }
        }
        CVPixelBufferUnlockBaseAddress(testBuffer, [])
        
        logger.info("Sending test frame...")
        let hostNs = DispatchTime.now().uptimeNanoseconds
        let testTimestamp = FrameTimestamp(frameID: 0, cameraTimestampNs: 0, hostTimestampNs: hostNs)
        sinkConnector.sendFrame(testBuffer, timestamp: testTimestamp)
    }
    
    private func showPreview() {
        guard isConnected else { 
            logger.warning("Cannot show preview: Not connected to camera")
            return 
        }
        
        isShowingPreview = true
        logger.info("Showing embedded preview for camera: \(self.cameraModel)")
        
        // The actual preview is handled by the CameraPreviewSection in ContentView
        // We just need to set the flag here
    }
    
    func hidePreview() {
        isShowingPreview = false
        logger.info("Hiding embedded preview")
        
        // The actual cleanup is handled by the CameraPreviewSection's onDisappear
    }
    
    // MARK: - Frame Handler Setup
    private func setupFrameHandler() {
        // Stream consumer: runs on GigECameraManager.streamQueue (background).
        // Capture the connector locally to avoid main-actor isolation in the
        // closure; `sendFrame` self-guards on its own connection state and
        // returns whether the frame was actually enqueued to the sink.
        let gigEManager = GigECameraManager.shared
        let connector = self.sinkConnector
        gigEManager.onStreamFrame = { frame in
            return connector.sendFrame(frame.pixelBuffer, timestamp: frame.timestamp)
        }
        
        // Set up callbacks for automatic sink connection
        setupSinkConnectorCallbacks()
        
        // Start the connection process
        logger.info("Starting sink connector connection...")
        let connected = sinkConnector.connect()
        logger.info("Initial sink connector connect returned: \(connected)")
        
        // If initial connection fails, set up automatic retry
        if !connected {
            logger.info("Initial sink connection failed - setting up automatic retry...")
            var retryCount = 0
            let maxRetries = 5
            
            func attemptConnection() {
                guard retryCount < maxRetries else {
                    self.logger.warning("Max sink connection retries reached (\(maxRetries))")
                    return
                }
                
                retryCount += 1
                DispatchQueue.main.asyncAfter(deadline: .now() + Double(retryCount) * 1.5) { [weak self] in
                    guard let self = self else { return }
                    
                    // Don't retry if already connected
                    guard !self.isFrameSenderConnected else {
                        self.logger.info("Sink already connected, stopping retry")
                        return
                    }
                    
                    self.logger.info("Sink connection retry \(retryCount)/\(maxRetries)...")
                    let retryConnected = self.sinkConnector.connect()
                    
                    if retryConnected {
                        self.logger.info("✅ Sink connected on retry \(retryCount)")
                    } else if retryCount < maxRetries {
                        attemptConnection() // Try again
                    }
                }
            }
            
            attemptConnection()
        }
        
        logger.info("Frame handler setup complete - waiting for sink stream discovery")
    }
    
    private func setupSinkConnectorCallbacks() {
        // Called when sink stream becomes available
        sinkConnector.onSinkStreamAvailable = { [weak self] available in
            guard let self = self else { return }
            
            self.logger.info("Sink stream availability changed: \(available)")
            
            if available && self.isConnected && !GigECameraManager.shared.isStreaming {
                self.logger.info("Sink stream available - starting Aravis streaming automatically")
                GigECameraManager.shared.startStreaming()
            }
        }
        
        // Called when connection state changes
        sinkConnector.onConnectionStateChanged = { [weak self] connected in
            guard let self = self else { return }
            
            self.isFrameSenderConnected = connected

            if connected {
                GigECameraManager.shared.startManifest()
                self.logger.info("✅ Sink connector connected via property listener callback!")

                // Start Aravis streaming if camera is connected but not streaming
                if self.isConnected && !GigECameraManager.shared.isStreaming {
                    self.logger.info("Starting Aravis streaming after sink connection")
                    GigECameraManager.shared.startStreaming()
                }
            } else {
                GigECameraManager.shared.stopManifest()
                self.logger.warning("⚠️ Sink connector disconnected")
            }
        }
    }
    
    func getPerformanceMetrics() -> (fps: Double, framesTotal: UInt64, framesDropped: UInt64) {
        // For now, return basic metrics from frame count
        return (30.0, UInt64(frameCount), 0)
    }
    
    // MARK: - Format Management
    
    private func updateSelectedFormat() {
        guard selectedFormatIndex < availableFormats.count else { return }
        
        currentFormat = availableFormats[selectedFormatIndex]
        let format = formatSpecs[selectedFormatIndex]
        
        // Handle Auto format
        var width = format.width
        var height = format.height
        var fps = format.fps
        
        if selectedFormatIndex == 0 { // Auto
            // Get camera native resolution if available
            if let resolution = GigECameraManager.shared.getCurrentResolution() {
                width = Int(resolution.width)
                height = Int(resolution.height)
                fps = 30 // Default FPS for now
                currentFormat = "\(width)×\(height) @ \(fps)fps (Native)"
                logger.info("Using camera native resolution: \(width)×\(height)")
            } else {
                // Fallback to default if camera not connected
                width = 1920
                height = 1080
                fps = 30
            }
        }
        
        // Save to shared UserDefaults for extension
        if let groupDefaults = UserDefaults(suiteName: "group.S368GH6KF7.com.lukechang.GigEVirtualCamera") {
            groupDefaults.set(width, forKey: "SelectedFormatWidth")
            groupDefaults.set(height, forKey: "SelectedFormatHeight")
            groupDefaults.set(fps, forKey: "SelectedFormatFPS")
            groupDefaults.synchronize()
            
            logger.info("Updated format to \(width)×\(height) @ \(fps)fps")
            
            // Notify extension about format change
            var streamState = groupDefaults.dictionary(forKey: "StreamState") ?? [:]
            streamState["formatChanged"] = true
            streamState["formatChangeTime"] = Date().timeIntervalSince1970
            groupDefaults.set(streamState, forKey: "StreamState")
            groupDefaults.synchronize()
        }
        
        // Apply resolution to camera if connected
        if isConnected && selectedFormatIndex != 0 { // Not Auto
            let resolution = CGSize(width: width, height: height)
            if GigECameraManager.shared.setResolution(resolution) {
                logger.info("Successfully set camera resolution to \(width)×\(height)")
            } else {
                logger.warning("Failed to set camera resolution")
            }
        }
        
        // If streaming, we might need to restart
        if isConnected && GigECameraManager.shared.isStreaming {
            logger.info("Format changed while streaming - restarting stream")
            
            GigECameraManager.shared.stopStreaming()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                GigECameraManager.shared.startStreaming()
            }
        }
    }
    
    // MARK: - Camera Control Methods
    
    private func updateExposureTime() {
        guard isConnected else {
            logger.warning("Cannot update exposure time - not connected")
            return
        }
        let gigEManager = GigECameraManager.shared
        gigEManager.setExposureTime(exposureTime)
        logger.info("Updated exposure time to \(self.exposureTime) µs")
        
        // Verify the change was applied
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            if let actualExposure = gigEManager.getExposureTime() {
                self?.logger.info("Verified exposure time: \(actualExposure) µs")
            }
        }
    }
    
    private func updateGain() {
        guard isConnected else {
            logger.warning("Cannot update gain - not connected")
            return
        }
        let gigEManager = GigECameraManager.shared
        gigEManager.setGain(gain)
        logger.info("Updated gain to \(self.gain)")
        
        // Verify the change was applied
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            if let actualGain = gigEManager.getGain() {
                self?.logger.info("Verified gain: \(actualGain)")
            }
        }
    }
    
    private func updateFrameRate() {
        guard isConnected else {
            logger.warning("Cannot update frame rate - not connected")
            return
        }
        let gigEManager = GigECameraManager.shared
        gigEManager.setFrameRate(frameRate)
        logger.info("Updated frame rate to \(self.frameRate) fps")
        
        // Verify the change was applied
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            if let actualFPS = gigEManager.getFrameRate() {
                self?.logger.info("Verified frame rate: \(actualFPS) fps")
            }
        }
    }
    
    func loadCameraSettings() {
        guard isConnected else { return }
        
        let gigEManager = GigECameraManager.shared
        
        // First, get camera capabilities
        let capabilities = gigEManager.getCameraCapabilities()
        logger.info("Loading camera capabilities...")
        
        // Update exposure time capabilities
        if let expAvailable = capabilities["exposureTimeAvailable"] as? Bool {
            self.exposureTimeAvailable = expAvailable
            if expAvailable {
                if let min = capabilities["exposureTimeMin"] as? Double {
                    self.exposureTimeMin = min
                }
                if let max = capabilities["exposureTimeMax"] as? Double {
                    self.exposureTimeMax = max
                }
                logger.info("Exposure time available: \(self.exposureTimeMin) - \(self.exposureTimeMax) µs")
            } else {
                logger.warning("Exposure time control not available on this camera")
            }
        }
        
        // Update gain capabilities
        if let gainAvail = capabilities["gainAvailable"] as? Bool {
            self.gainAvailable = gainAvail
            if gainAvail {
                if let min = capabilities["gainMin"] as? Double {
                    self.gainMin = min
                }
                if let max = capabilities["gainMax"] as? Double {
                    self.gainMax = max
                }
                logger.info("Gain available: \(self.gainMin) - \(self.gainMax)")
            } else {
                logger.warning("Gain control not available on this camera")
            }
        }
        
        // Update frame rate capabilities
        if let fpsAvail = capabilities["frameRateAvailable"] as? Bool {
            self.frameRateAvailable = fpsAvail
            if fpsAvail {
                if let min = capabilities["frameRateMin"] as? Double {
                    self.frameRateMin = min
                }
                if let max = capabilities["frameRateMax"] as? Double {
                    self.frameRateMax = max
                }
                logger.info("Frame rate available: \(self.frameRateMin) - \(self.frameRateMax) fps")
            } else {
                logger.warning("Frame rate control not available on this camera")
            }
        }
        
        // Get current values from camera only if we haven't set them yet
        // This prevents overriding user's manual settings
        if self.exposureTimeAvailable, let currentExposure = gigEManager.getExposureTime() {
            // Only update if significantly different (avoid floating point issues)
            if abs(self.exposureTime - currentExposure) > 1.0 {
                self.exposureTime = currentExposure
                logger.info("Loaded exposure from camera: \(currentExposure) µs")
            }
        }
        
        if self.gainAvailable, let currentGain = gigEManager.getGain() {
            // Only update if significantly different
            if abs(self.gain - currentGain) > 0.01 {
                self.gain = currentGain
                logger.info("Loaded gain from camera: \(currentGain)")
            }
        }
        
        if self.frameRateAvailable, let currentFPS = gigEManager.getFrameRate() {
            // Only update if significantly different
            if abs(self.frameRate - currentFPS) > 0.1 {
                self.frameRate = currentFPS
                logger.info("Loaded frame rate from camera: \(currentFPS) fps")
            }
        }
        
        logger.info("Camera settings - Exposure: \(self.exposureTime)µs, Gain: \(self.gain), FPS: \(self.frameRate)")
    }
}