//
//  CameraPreviewView.swift
//  GigEVirtualCamera
//
//  Camera preview window
//
// NOTE: UNUSED. The live preview is `CameraPreviewSection` / `PreviewFrameHandler`
// in ContentView.swift. This view is compiled but never instantiated. Do not wire
// it up without first resolving that both it and PreviewFrameHandler assign the
// single GigECameraManager.onPreviewFrame closure (they would clobber each other).

import SwiftUI
import CoreVideo

struct CameraPreviewView: View {
    @ObservedObject var cameraManager: CameraManager
    @StateObject private var frameHandler = FrameHandler()
    
    var body: some View {
        ZStack {
            // Camera feed
            if let image = frameHandler.currentImage {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            } else {
                // Placeholder when no feed
                Rectangle()
                    .fill(Color.black)
                    .overlay(
                        VStack {
                            ProgressView()
                                .progressViewStyle(CircularProgressViewStyle(tint: .white))
                                .scaleEffect(1.5)
                            Text("Waiting for camera feed...")
                                .foregroundColor(.white)
                                .padding(.top)
                        }
                    )
            }
            
            // Overlay with camera info
            VStack {
                HStack {
                    Text(cameraManager.cameraModel)
                        .font(.caption)
                        .padding(8)
                        .background(Color.black.opacity(0.7))
                        .foregroundColor(.white)
                        .cornerRadius(4)
                    
                    Spacer()
                    
                    Text("FPS: \(frameHandler.fps, specifier: "%.1f")")
                        .font(.caption)
                        .padding(8)
                        .background(Color.black.opacity(0.7))
                        .foregroundColor(.white)
                        .cornerRadius(4)
                }
                .padding()
                
                Spacer()
            }
        }
        .frame(minWidth: 320, minHeight: 240)
        .onAppear {
            frameHandler.startReceivingFrames()
        }
        .onDisappear {
            frameHandler.stopReceivingFrames()
        }
    }
}

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