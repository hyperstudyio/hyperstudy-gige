//
//  ContentView.swift
//  GigEVirtualCamera
//
//  Created on 6/24/25.
//

import SwiftUI
import IOSurface

struct ContentView: View {
    @EnvironmentObject var cameraManager: CameraManager
    @State private var previewImage: NSImage?
    @StateObject private var extensionManager = ExtensionManager.shared
    @State private var isDiscoveringCameras = false
    
    var selectedCameraText: String {
        if let selectedId = cameraManager.selectedCameraId,
           let camera = cameraManager.availableCameras.first(where: { $0.deviceId == selectedId }) {
            return "\(camera.name) (\(camera.ipAddress))"
        }
        return "Select Camera"
    }
    
    var connectionStateText: String {
        switch cameraManager.connectionState {
        case "Connecting":
            let attempts = cameraManager.connectionAttempts
            if attempts > 1 {
                return "Connecting... (attempt \(attempts))"
            } else {
                return "Connecting..."
            }
        case "Connected":
            return "Connected"
        case "Failed":
            return "Connection failed"
        default:
            return "No Camera"
        }
    }
    
    var connectionStateIcon: String {
        switch cameraManager.connectionState {
        case "Connected":
            return "circle.fill"
        case "Failed":
            return "exclamationmark.circle.fill"
        default:
            return "circle"
        }
    }
    
    var connectionStateColor: Color {
        switch cameraManager.connectionState {
        case "Connecting":
            return DesignSystem.Colors.statusOrange
        case "Connected":
            return DesignSystem.Colors.statusGreen
        case "Failed":
            return .red
        default:
            return DesignSystem.Colors.textSecondary
        }
    }
    
    var body: some View {
        ZStack {
            // Background
            VisualEffectBackground()
            
            VStack(spacing: DesignSystem.Spacing.medium) {
                // Header with camera icon
                HeaderView(isConnected: cameraManager.isConnected)
                    .padding(.top, DesignSystem.Spacing.large)
                
                // Extension Status and Controls
                VStack(spacing: DesignSystem.Spacing.medium) {
                    HStack {
                        Text("Camera Extension Status:")
                            .font(DesignSystem.Typography.callout)
                            .foregroundColor(DesignSystem.Colors.textSecondary)
                        Spacer()
                        Text(extensionManager.extensionStatus)
                            .font(DesignSystem.Typography.callout)
                            .fontWeight(.medium)
                            .foregroundColor(extensionManager.extensionStatus == "Installed" ? .green : DesignSystem.Colors.textSecondary)
                    }
                    
                    HStack(spacing: DesignSystem.Spacing.medium) {
                        Button(action: {
                            extensionManager.installExtension()
                        }) {
                            Label("Install Extension", systemImage: "plus.circle")
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(extensionManager.isInstalling || extensionManager.extensionStatus == "Installed")
                        
                        Button(action: {
                            extensionManager.uninstallExtension()
                        }) {
                            Label("Uninstall Extension", systemImage: "minus.circle")
                        }
                        .buttonStyle(.bordered)
                        .disabled(extensionManager.isInstalling || extensionManager.extensionStatus != "Installed")
                    }
                    
                    if extensionManager.extensionStatus == "Needs Approval" {
                        HStack(spacing: DesignSystem.Spacing.small) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundColor(.orange)
                            Text("Please approve in System Settings > Privacy & Security")
                                .font(DesignSystem.Typography.caption)
                                .foregroundColor(.orange)
                        }
                    }
                    
                    // No need for connection button - IOSurface writer is always ready
                    
                    // Debug feedback area
                    if !extensionManager.statusMessage.isEmpty {
                        VStack(alignment: .leading, spacing: DesignSystem.Spacing.small) {
                            Text("Debug Output:")
                                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                                .foregroundColor(.gray)
                            
                            Text(extensionManager.statusMessage)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundColor(.blue)
                                .multilineTextAlignment(.leading)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            
                            if !extensionManager.errorDetail.isEmpty {
                                Text("Error Detail: \(extensionManager.errorDetail)")
                                    .font(.system(size: 11, design: .monospaced))
                                    .foregroundColor(.red)
                                    .multilineTextAlignment(.leading)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                        .padding(DesignSystem.Spacing.small)
                        .background(
                            RoundedRectangle(cornerRadius: 4)
                                .fill(Color.black.opacity(0.05))
                        )
                    }
                }
                .padding(.horizontal, DesignSystem.Spacing.large)
                .padding(.vertical, DesignSystem.Spacing.small)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color.gray.opacity(0.1))
                )
                .padding(.horizontal, DesignSystem.Spacing.large)
                
                Divider()
                    .padding(.horizontal, DesignSystem.Spacing.large)
                    .padding(.vertical, DesignSystem.Spacing.small)
                
                // Camera selection section
                if !cameraManager.availableCameras.isEmpty {
                    VStack(spacing: DesignSystem.Spacing.small) {
                        HStack {
                            Image(systemName: "camera.on.rectangle")
                                .font(DesignSystem.Typography.callout)
                                .foregroundColor(DesignSystem.Colors.textSecondary)
                            Text("Select Camera")
                                .font(DesignSystem.Typography.callout)
                                .foregroundColor(DesignSystem.Colors.textSecondary)
                            Spacer()
                        }
                        
                        Menu {
                            Button("None") {
                                cameraManager.selectedCameraId = nil
                            }
                            
                            Divider()
                            
                            if isDiscoveringCameras {
                                HStack {
                                    ProgressView()
                                        .progressViewStyle(CircularProgressViewStyle())
                                        .scaleEffect(0.8)
                                    Text("Searching for cameras...")
                                        .foregroundColor(.gray)
                                }
                            } else if cameraManager.availableCameras.isEmpty {
                                Text("No cameras found")
                                    .foregroundColor(.gray)
                            } else {
                                ForEach(cameraManager.availableCameras, id: \.deviceId) { camera in
                                    Button("\(camera.name) (\(camera.ipAddress))") {
                                        cameraManager.selectedCameraId = camera.deviceId
                                    }
                                }
                            }
                            
                            Divider()
                            
                            Button("Refresh Camera List") {
                                isDiscoveringCameras = true
                                cameraManager.refreshCameraList()
                                DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
                                    isDiscoveringCameras = false
                                }
                            }
                            .foregroundColor(.blue)
                            .disabled(isDiscoveringCameras)
                        } label: {
                            HStack {
                                if isDiscoveringCameras {
                                    ProgressView()
                                        .progressViewStyle(CircularProgressViewStyle())
                                        .scaleEffect(0.7)
                                        .frame(width: 14, height: 14)
                                    Text("Searching...")
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                } else {
                                    Text(selectedCameraText)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                }
                                Image(systemName: isDiscoveringCameras ? "arrow.triangle.2.circlepath" : "chevron.down")
                                    .font(.caption)
                                    .foregroundColor(.gray)
                                    .rotationEffect(.degrees(isDiscoveringCameras ? 360 : 0))
                                    .animation(isDiscoveringCameras ? .linear(duration: 1).repeatForever(autoreverses: false) : .default, value: isDiscoveringCameras)
                            }
                            .padding(8)
                            .background(
                                RoundedRectangle(cornerRadius: 6)
                                    .stroke(Color.gray.opacity(0.3), lineWidth: 1)
                                    .background(
                                        RoundedRectangle(cornerRadius: 6)
                                            .fill(Color.gray.opacity(0.05))
                                    )
                            )
                        }
                        .onTapGesture {
                            // Refresh camera list when menu is about to open
                            isDiscoveringCameras = true
                            cameraManager.refreshCameraList()
                            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
                                isDiscoveringCameras = false
                            }
                        }
                    }
                    .padding(.horizontal, DesignSystem.Spacing.large)
                }
                
                
                // Status section
                VStack(spacing: DesignSystem.Spacing.medium) {
                    // Show connection state with appropriate icon and animation
                    HStack {
                        HStack(spacing: DesignSystem.Spacing.small) {
                            if cameraManager.connectionState == "Connecting" {
                                ProgressView()
                                    .progressViewStyle(CircularProgressViewStyle())
                                    .scaleEffect(0.8)
                            } else {
                                Image(systemName: connectionStateIcon)
                                    .foregroundColor(connectionStateColor)
                            }
                            
                            Text("Status")
                                .font(DesignSystem.Typography.callout)
                                .foregroundColor(DesignSystem.Colors.textSecondary)
                        }
                        
                        Spacer()
                        
                        Text(connectionStateText)
                            .font(DesignSystem.Typography.callout)
                            .fontWeight(.medium)
                            .foregroundColor(connectionStateColor)
                    }
                    
                    // Add sink connection status
                    if cameraManager.isConnected {
                        HStack {
                            StatusRow(
                                icon: "arrow.triangle.2.circlepath",
                                title: "CMIO Sink",
                                value: cameraManager.isFrameSenderConnected ? "Connected" : "Waiting...",
                                valueColor: cameraManager.isFrameSenderConnected ? .green : .orange
                            )
                            
                            // Add retry button if sink is not connected
                            if !cameraManager.isFrameSenderConnected {
                                Button(action: {
                                    cameraManager.retryFrameSenderConnection()
                                }) {
                                    Image(systemName: "arrow.clockwise")
                                        .font(.system(size: 12))
                                        .foregroundColor(.orange)
                                }
                                .buttonStyle(PlainButtonStyle())
                                .help("Retry sink connection")
                            }
                        }
                    }
                    
                    // Show camera info during connection attempts too
                    if cameraManager.connectionState == "Connecting" || cameraManager.isConnected {
                        StatusRow(
                            icon: "camera.fill",
                            title: "Camera",
                            value: cameraManager.cameraModel
                        )
                    }
                    
                    // Show retry button if connection failed
                    if cameraManager.connectionState == "Failed" {
                        Button(action: {
                            cameraManager.retryConnection()
                        }) {
                            HStack {
                                Image(systemName: "arrow.clockwise")
                                Text("Retry Connection")
                            }
                            .font(DesignSystem.Typography.callout)
                            .foregroundColor(.white)
                            .padding(.horizontal, DesignSystem.Spacing.medium)
                            .padding(.vertical, DesignSystem.Spacing.small)
                            .background(DesignSystem.Colors.statusOrange)
                            .cornerRadius(DesignSystem.CornerRadius.medium)
                        }
                        .buttonStyle(PlainButtonStyle())
                        .padding(.top, DesignSystem.Spacing.small)
                    }
                    
                    if cameraManager.isConnected {
                        
                        // Format selector
                        HStack {
                            Label("Format", systemImage: "video.fill")
                                .font(DesignSystem.Typography.callout)
                                .foregroundColor(DesignSystem.Colors.textSecondary)
                            
                            Spacer()
                            
                            Picker("", selection: $cameraManager.selectedFormatIndex) {
                                ForEach(0..<cameraManager.availableFormats.count, id: \.self) { index in
                                    Text(cameraManager.availableFormats[index]).tag(index)
                                }
                            }
                            .pickerStyle(MenuPickerStyle())
                            .frame(width: 150)
                        }
                        
                        // Pixel format selector
                        HStack {
                            Label("Pixel Format", systemImage: "square.grid.3x3.fill")
                                .font(DesignSystem.Typography.callout)
                                .foregroundColor(DesignSystem.Colors.textSecondary)
                            
                            Spacer()
                            
                            Picker("", selection: $cameraManager.currentPixelFormat) {
                                ForEach(cameraManager.availablePixelFormats, id: \.self) { format in
                                    Text(format).tag(format)
                                }
                            }
                            .pickerStyle(MenuPickerStyle())
                            .frame(width: 120)
                        }
                        
                        Divider()
                            .padding(.vertical, DesignSystem.Spacing.xSmall)
                        
                        // Camera Controls Section
                        VStack(spacing: DesignSystem.Spacing.medium) {
                            // Exposure Time Control
                            if cameraManager.exposureTimeAvailable {
                                VStack(alignment: .leading, spacing: DesignSystem.Spacing.xSmall) {
                                    HStack {
                                        Label("Exposure", systemImage: "timer")
                                            .font(DesignSystem.Typography.callout)
                                            .foregroundColor(DesignSystem.Colors.textSecondary)
                                        Spacer()
                                        Text("\(Int(cameraManager.exposureTime)) µs")
                                            .font(DesignSystem.Typography.callout)
                                            .foregroundColor(DesignSystem.Colors.textPrimary)
                                            .monospacedDigit()
                                    }
                                    
                                    Slider(value: $cameraManager.exposureTime, 
                                           in: cameraManager.exposureTimeMin...cameraManager.exposureTimeMax,
                                           onEditingChanged: { editing in
                                               if !editing {
                                                   // Log final value when user releases slider
                                                   print("Exposure set to: \(cameraManager.exposureTime)")
                                               }
                                           })
                                        .controlSize(.small)
                                        .disabled(!cameraManager.exposureTimeAvailable)
                                }
                            
                            }
                            
                            // Gain Control
                            if cameraManager.gainAvailable {
                                VStack(alignment: .leading, spacing: DesignSystem.Spacing.xSmall) {
                                    HStack {
                                        Label("Gain", systemImage: "dial.high")
                                            .font(DesignSystem.Typography.callout)
                                            .foregroundColor(DesignSystem.Colors.textSecondary)
                                        Spacer()
                                        Text(String(format: "%.1fx", cameraManager.gain))
                                            .font(DesignSystem.Typography.callout)
                                            .foregroundColor(DesignSystem.Colors.textPrimary)
                                            .monospacedDigit()
                                    }
                                    
                                    Slider(value: $cameraManager.gain,
                                           in: cameraManager.gainMin...cameraManager.gainMax,
                                           onEditingChanged: { editing in
                                               if !editing {
                                                   print("Gain set to: \(cameraManager.gain)")
                                               }
                                           })
                                        .controlSize(.small)
                                        .disabled(!cameraManager.gainAvailable)
                                }
                            }
                            
                            // Frame Rate Control
                            if cameraManager.frameRateAvailable && cameraManager.selectedFormatIndex != 0 {
                                VStack(alignment: .leading, spacing: DesignSystem.Spacing.xSmall) {
                                    HStack {
                                        Label("Frame Rate", systemImage: "speedometer")
                                            .font(DesignSystem.Typography.callout)
                                            .foregroundColor(DesignSystem.Colors.textSecondary)
                                        Spacer()
                                        Text("\(Int(cameraManager.frameRate)) fps")
                                            .font(DesignSystem.Typography.callout)
                                            .foregroundColor(DesignSystem.Colors.textPrimary)
                                            .monospacedDigit()
                                    }
                                    
                                    Slider(value: $cameraManager.frameRate,
                                           in: cameraManager.frameRateMin...cameraManager.frameRateMax,
                                           step: 1,
                                           onEditingChanged: { editing in
                                               if !editing {
                                                   print("Frame rate set to: \(cameraManager.frameRate)")
                                               }
                                           })
                                        .controlSize(.small)
                                        .disabled(!cameraManager.frameRateAvailable)
                                }
                            }
                            
                            // Show message if no controls are available
                            if !cameraManager.exposureTimeAvailable && !cameraManager.gainAvailable && !cameraManager.frameRateAvailable {
                                HStack {
                                    Image(systemName: "info.circle")
                                        .foregroundColor(.orange)
                                    Text("Camera controls not available for this device")
                                        .font(DesignSystem.Typography.caption)
                                        .foregroundColor(.orange)
                                }
                                .padding(DesignSystem.Spacing.small)
                            }
                        }
                        
                        // Preview toggle button
                        Button(action: {
                            cameraManager.togglePreview()
                            
                            // Animate window resize
                            DispatchQueue.main.async {
                                if let window = NSApplication.shared.windows.first {
                                    NSAnimationContext.runAnimationGroup({ context in
                                        context.duration = 0.3
                                        context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                                        
                                        let targetHeight: CGFloat = cameraManager.isShowingPreview ? 900 : 680
                                        var frame = window.frame
                                        let heightDiff = targetHeight - frame.height
                                        frame.size.height = targetHeight
                                        frame.origin.y -= heightDiff // Keep window top edge in place
                                        
                                        window.animator().setFrame(frame, display: true)
                                    })
                                }
                            }
                        }) {
                            HStack {
                                Image(systemName: cameraManager.isShowingPreview ? "eye.slash.fill" : "eye.fill")
                                Text(cameraManager.isShowingPreview ? "Hide Preview" : "Show Preview")
                            }
                            .font(DesignSystem.Typography.callout)
                            .foregroundColor(.white)
                            .padding(.horizontal, DesignSystem.Spacing.medium)
                            .padding(.vertical, DesignSystem.Spacing.small)
                            .background(DesignSystem.Colors.statusGreen)
                            .cornerRadius(DesignSystem.CornerRadius.medium)
                        }
                        .buttonStyle(PlainButtonStyle())
                        .padding(.top, DesignSystem.Spacing.small)
                        
                        // Embedded preview
                        if cameraManager.isShowingPreview {
                            CameraPreviewSection(previewImage: $previewImage)
                                .environmentObject(cameraManager)
                                .frame(height: 300)
                                .padding(.top, DesignSystem.Spacing.medium)
                                .transition(.asymmetric(
                                    insertion: .opacity.combined(with: .move(edge: .top)),
                                    removal: .opacity.combined(with: .scale)
                                ))
                                .animation(.easeInOut(duration: 0.3), value: cameraManager.isShowingPreview)
                        }
                    }
                }
                .padding(.horizontal, DesignSystem.Spacing.large)
                
                Spacer(minLength: DesignSystem.Spacing.medium)
            }
            .padding(.bottom, DesignSystem.Spacing.medium)
        }
        .frame(minHeight: cameraManager.isShowingPreview ? 900 : 680)
        .animation(.easeInOut(duration: 0.3), value: cameraManager.isShowingPreview)
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("GigECamerasDiscovered"))) { _ in
            // Clear loading state when discovery completes
            isDiscoveringCameras = false
        }
    }
    
}

// MARK: - Header View

struct HeaderView: View {
    let isConnected: Bool
    @State private var iconRotation: Double = 0
    
    var body: some View {
        VStack(spacing: DesignSystem.Spacing.small) {
            // Animated camera icon
            Image(systemName: isConnected ? "camera.fill" : "camera")
                .font(.system(size: 48))
                .foregroundColor(isConnected ? DesignSystem.Colors.statusGreen : DesignSystem.Colors.textSecondary)
                .rotationEffect(.degrees(iconRotation))
                .animation(DesignSystem.Animation.spring, value: iconRotation)
                .onAppear {
                    if isConnected {
                        withAnimation(.easeInOut(duration: 1).repeatForever(autoreverses: true)) {
                            iconRotation = 5
                        }
                    }
                }
            
            Text("GigE Virtual Camera")
                .font(DesignSystem.Typography.title)
                .foregroundColor(DesignSystem.Colors.textPrimary)
        }
    }
}

// MARK: - Status Row

struct StatusRow: View {
    let icon: String
    let title: String
    let value: String
    var valueColor: Color = DesignSystem.Colors.textPrimary
    
    var body: some View {
        HStack {
            Label(title, systemImage: icon)
                .font(DesignSystem.Typography.callout)
                .foregroundColor(DesignSystem.Colors.textSecondary)
            
            Spacer()
            
            Text(value)
                .font(DesignSystem.Typography.callout)
                .fontWeight(.medium)
                .foregroundColor(valueColor)
        }
    }
}


// MARK: - Visual Effect Background

struct VisualEffectBackground: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.blendingMode = .behindWindow
        view.material = .hudWindow
        view.state = .active
        return view
    }
    
    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}

// MARK: - Camera Preview Section

struct CameraPreviewSection: View {
    @Binding var previewImage: NSImage?
    @EnvironmentObject var cameraManager: CameraManager
    @StateObject private var frameHandler = PreviewFrameHandler()
    @State private var hasAppeared = false
    
    var body: some View {
        ZStack {
            // Background
            RoundedRectangle(cornerRadius: DesignSystem.CornerRadius.medium)
                .fill(Color.black)
            
            if let image = frameHandler.currentImage {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxHeight: 280)
                    .cornerRadius(DesignSystem.CornerRadius.medium)
            } else {
                VStack {
                    ProgressView()
                        .progressViewStyle(CircularProgressViewStyle(tint: .white))
                        .scaleEffect(1.2)
                    Text("Waiting for camera feed...")
                        .font(DesignSystem.Typography.caption)
                        .foregroundColor(.white)
                        .padding(.top, DesignSystem.Spacing.small)
                }
            }
        }
        .frame(height: 300)
        .onAppear {
            print("CameraPreviewSection: ===== VIEW APPEARED =====")
            hasAppeared = true
            // Delay to ensure view is stable
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                frameHandler.startReceivingFrames()
            }
        }
        .onDisappear {
            print("CameraPreviewSection: ===== VIEW DISAPPEARED =====")
            hasAppeared = false
            frameHandler.stopReceivingFrames()
        }
    }
}

// MARK: - Preview Frame Handler

class PreviewFrameHandler: ObservableObject {
    @Published var currentImage: NSImage?
    private let gigEManager = GigECameraManager.shared
    private var frameCount = 0
    
    
    func startReceivingFrames() {
        print("PreviewFrameHandler: Starting to receive frames")
        
        // Check if camera is connected first
        guard gigEManager.isConnected else {
            print("PreviewFrameHandler: Camera not connected, cannot start preview")
            return
        }
        
        // Start streaming if not already
        if !gigEManager.isStreaming {
            print("PreviewFrameHandler: Starting streaming...")
            gigEManager.startStreaming()
            
            // Give it a moment to start
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                self?.setupFrameHandler()
            }
        } else {
            print("PreviewFrameHandler: Already streaming")
            setupFrameHandler()
        }
    }
    
    private func setupFrameHandler() {
        print("PreviewFrameHandler: Setting up frame handler")

        // Use the preview slot callback (drop-to-latest, independent of stream path).
        gigEManager.onPreviewFrame = { [weak self] frame in
            guard let self = self else { return }

            self.frameCount += 1

            // Only log every 30th frame
            if self.frameCount % 30 == 1 {
                print("PreviewFrameHandler: Got frame #\(self.frameCount)")
            }

            // Simple CIImage to NSImage conversion (runs on previewQueue)
            let ciImage = CIImage(cvPixelBuffer: frame.pixelBuffer)
            let rep = NSCIImageRep(ciImage: ciImage)
            let nsImage = NSImage(size: rep.size)
            nsImage.addRepresentation(rep)

            // Update on main thread
            DispatchQueue.main.async {
                self.currentImage = nsImage
                if self.frameCount % 30 == 1 {
                    print("PreviewFrameHandler: Updated UI with frame #\(self.frameCount)")
                }
            }
        }

        print("PreviewFrameHandler: Frame handler added")
    }

    func stopReceivingFrames() {
        print("PreviewFrameHandler: Stopping frame reception after \(frameCount) frames")
        gigEManager.stopStreaming()
        gigEManager.onPreviewFrame = nil
        frameCount = 0
    }
}

// MARK: - Preview

struct ContentView_Previews: PreviewProvider {
    static var previews: some View {
        ContentView()
            .environmentObject(CameraManager.shared)
            .frame(width: 400)
    }
}