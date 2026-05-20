//
//  GigECameraManager.swift
//  GigEVirtualCamera
//
//  Swift wrapper for Aravis bridge
//

import Foundation
import CoreVideo
import Combine
import FramePipelineKit

// Using stub implementation for now
// When Aravis is properly integrated, remove the stub

@objc class GigECameraManager: NSObject, ObservableObject {
    static let shared = GigECameraManager()
    
    @Published var isConnected = false
    @Published var isStreaming = false
    @Published var availableCameras: [AravisCamera] = []
    @Published var currentCamera: AravisCamera?
    @Published var frameRate: Double = 30.0
    @Published var lastError: Error?
    @Published var preferredPixelFormat: String = "Auto"
    
    private let aravisBridge = AravisBridge()
    private var frameHandlers: [(CVPixelBuffer) -> Void] = []
    private var lastDiscoveryTime = Date.distantPast
    private var connectionRetryCount = 0
    private var frameDistributionCount = 0
    
    
    override init() {
        super.init()
        aravisBridge.delegate = self
        print("GigECameraManager: Set aravisBridge delegate to self")
        discoverCameras()
    }
    
    // MARK: - Camera Discovery
    
    func discoverCameras() {
        print("GigECameraManager: Starting camera discovery...")
        print("GigECameraManager: Current thread: \(Thread.current)")
        print("GigECameraManager: AravisBridge instance: \(aravisBridge)")
        
        let workItem = DispatchWorkItem(block: { [weak self] in
            print("GigECameraManager: Calling AravisBridge.discoverCameras()...")
            var cameras = AravisBridge.discoverCameras()
            print("GigECameraManager: AravisBridge returned \(cameras.count) cameras")
            
            // Rename any Aravis fake cameras to have a cleaner name
            cameras = cameras.map { camera in
                if camera.modelName.contains("Fake") || 
                   camera.deviceId.contains("Fake") || 
                   camera.ipAddress == "0.0.0.0" ||
                   camera.ipAddress == "00:00:00:00:00:00" {
                    return AravisCamera(
                        deviceId: camera.deviceId,
                        name: "Test Camera",
                        modelName: "Test Camera",
                        ipAddress: camera.ipAddress
                    )
                }
                return camera
            }
            
            if cameras.isEmpty {
                print("GigECameraManager: No cameras found")
            }
            
            for camera in cameras {
                print("  - \(camera.name) at \(camera.ipAddress)")
            }
            
            var allCameras = cameras
            
            // Only add our test camera if Aravis didn't find a fake camera already
            let hasFakeCamera = cameras.contains { camera in
                camera.modelName.contains("Fake") || 
                camera.deviceId.contains("Fake") || 
                camera.ipAddress == "0.0.0.0" ||
                camera.ipAddress == "00:00:00:00:00:00"
            }
            
            if !hasFakeCamera {
                let fakeCamera = AravisCamera(
                    deviceId: "aravis-fake-camera",
                    name: "Test Camera (Aravis Simulator)",
                    modelName: "Aravis Fake GV Camera",
                    ipAddress: "127.0.0.1"
                )
                allCameras.append(fakeCamera)
                print("  - \(fakeCamera.name) (Virtual)")
            }
            
            DispatchQueue.main.async {
                self?.availableCameras = allCameras
                
                // Post notification about discovered cameras
                NotificationCenter.default.post(name: NSNotification.Name("GigECamerasDiscovered"), object: nil)
                
                // Don't auto-connect - let user manually select camera
            }
        })
        
        DispatchQueue.global(qos: .userInitiated).async(execute: workItem)
    }
    
    // MARK: - Connection
    
    func connect(to camera: AravisCamera) {
        // Check if this is the fake camera
        if camera.deviceId == "aravis-fake-camera" {
            print("GigECameraManager: Starting fake camera for connection...")
            
            // Start the fake camera
            if AravisBridge.startFakeCamera() {
                // Now discover and connect to the actual fake camera
                let cameras = AravisBridge.discoverCameras()
                if let fakeCamera = cameras.first(where: { $0.modelName.contains("Fake") || $0.deviceId.contains("Fake") }) {
                    print("GigECameraManager: Found running fake camera, connecting...")
                    guard aravisBridge.connect(to: fakeCamera) else {
                        print("GigECameraManager: Failed to connect to fake camera")
                        AravisBridge.stopFakeCamera()
                        return
                    }
                    currentCamera = camera // Keep the UI camera reference
                } else {
                    print("GigECameraManager: Fake camera started but not found in discovery")
                    AravisBridge.stopFakeCamera()
                    return
                }
            } else {
                print("GigECameraManager: Failed to start fake camera")
                return
            }
        } else {
            // Normal camera connection
            print("GigECameraManager: Connecting to \(camera.modelName) at \(camera.ipAddress)")
            
            if !aravisBridge.connect(to: camera) {
                print("GigECameraManager: ❌ Failed to connect to camera \(camera.modelName)")
                // Post notification about connection failure
                DispatchQueue.main.async {
                    NotificationCenter.default.post(
                        name: NSNotification.Name("GigECameraConnectionFailed"),
                        object: nil,
                        userInfo: ["camera": camera, "error": "Connection failed"]
                    )
                }
                return
            }
            
            print("GigECameraManager: ✅ Successfully connected to \(camera.modelName)")
            currentCamera = camera
        }
    }
    
    func connectToIP(_ ipAddress: String) {
        guard aravisBridge.connectToCamera(atAddress: ipAddress) else {
            return
        }
    }
    
    func disconnect() {
        // Stop fake camera if it was running
        if currentCamera?.deviceId == "aravis-fake-camera" {
            print("GigECameraManager: Stopping fake camera...")
            AravisBridge.stopFakeCamera()
        }
        
        aravisBridge.disconnect()
        currentCamera = nil
    }
    
    // MARK: - Streaming
    
    func startStreaming() {
        print("GigECameraManager: startStreaming called, isConnected=\(isConnected)")
        guard isConnected else {
            print("GigECameraManager: Cannot start streaming - not connected")
            return
        }
        
        guard aravisBridge.startStreaming() else {
            print("GigECameraManager: aravisBridge.startStreaming() failed")
            return
        }
        print("GigECameraManager: Streaming started successfully")
    }
    
    func stopStreaming() {
        aravisBridge.stopStreaming()
    }
    
    // MARK: - Frame Handling
    
    func addFrameHandler(_ handler: @escaping (CVPixelBuffer) -> Void) {
        frameHandlers.append(handler)
    }
    
    func removeAllFrameHandlers() {
        frameHandlers.removeAll()
    }
    
    // MARK: - Camera Settings
    
    func setFrameRate(_ fps: Double) {
        if aravisBridge.setFrameRate(fps) {
            frameRate = fps
        }
    }
    
    func setExposureTime(_ microseconds: Double) {
        _ = aravisBridge.setExposureTime(microseconds)
    }
    
    func setGain(_ gain: Double) {
        _ = aravisBridge.setGain(gain)
    }
    
    func setPixelFormat(_ format: String) {
        preferredPixelFormat = format
        // Notify the bridge about format preference
        aravisBridge.setPreferredPixelFormat(format)
    }
    
    func setResolution(_ resolution: CGSize) -> Bool {
        return aravisBridge.setResolution(resolution)
    }
    
    func getCurrentResolution() -> CGSize? {
        guard isConnected else { return nil }
        return aravisBridge.currentResolution()
    }
    
    func getExposureTime() -> Double? {
        guard isConnected else { return nil }
        return aravisBridge.exposureTime()
    }
    
    func getGain() -> Double? {
        guard isConnected else { return nil }
        return aravisBridge.gain()
    }
    
    func getFrameRate() -> Double? {
        guard isConnected else { return nil }
        return aravisBridge.frameRate()
    }
    
    func getCameraCapabilities() -> [String: Any] {
        guard isConnected else { return [:] }
        return aravisBridge.getCameraCapabilities() as? [String: Any] ?? [:]
    }
}

// MARK: - AravisBridgeDelegate

extension GigECameraManager: AravisBridgeDelegate {
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
    
    @objc func aravisBridge(_ bridge: Any, didChange state: AravisCameraState) {
        DispatchQueue.main.async { [weak self] in
            switch state {
            case .disconnected:
                self?.isConnected = false
                self?.isStreaming = false
            case .connected:
                self?.isConnected = true
                self?.isStreaming = false
            case .streaming:
                self?.isConnected = true
                self?.isStreaming = true
            case .error:
                self?.isConnected = false
                self?.isStreaming = false
            default:
                break
            }
            
            // Post state change notification
            NotificationCenter.default.post(name: NSNotification.Name("GigECameraStateChanged"), object: nil)
        }
    }
    
    @objc func aravisBridge(_ bridge: Any, didEncounterError error: Error) {
        DispatchQueue.main.async { [weak self] in
            self?.lastError = error
            print("Camera error: \(error.localizedDescription)")
        }
    }
}
