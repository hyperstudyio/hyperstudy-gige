//
//  GigECameraManager.swift
//  GigEVirtualCamera
//
//  Swift wrapper for Aravis bridge
//

import Foundation
import CoreVideo
import Combine
import os.signpost
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
    private var lastDiscoveryTime = Date.distantPast
    private var connectionRetryCount = 0

    private static let signpostLog = OSLog(subsystem: "com.lukechang.GigEVirtualCamera",
                                           category: "FramePipeline")

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
            os_signpost(.begin, log: Self.signpostLog, name: "preview-render")
            self.onPreviewFrame?(latest)
            os_signpost(.end, log: Self.signpostLog, name: "preview-render")
        }

        // Stream: bounded buffer; a displaced frame is a logged buffer-drop.
        if let dropped = streamRing.push(frame) {
            recordManifest(dropped.timestamp, status: .droppedBuffer)
        }
        streamQueue.async { [weak self] in
            guard let self, let next = self.streamRing.pop() else { return }
            os_signpost(.begin, log: Self.signpostLog, name: "stream-send")
            let delivered = self.onStreamFrame?(next) ?? false
            os_signpost(.end, log: Self.signpostLog, name: "stream-send")
            self.recordManifest(next.timestamp,
                                status: delivered ? .delivered : .droppedQueue)
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
