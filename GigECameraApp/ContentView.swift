//
//  ContentView.swift
//  GigEVirtualCamera
//
//  Created on 6/24/25.
//

import SwiftUI
import IOSurface
import CoreImage
import AppKit
import UniformTypeIdentifiers

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

                    // Loud banner when the stream-stall watchdog detects frames
                    // have stopped flowing. This is the signal that says "your
                    // run is silently losing data right now" -- visually
                    // unmissable on purpose.
                    if cameraManager.streamStalled {
                        StreamStalledBanner(
                            durationSec: cameraManager.streamStallDurationSec,
                            onRecover: { cameraManager.retryFrameSenderConnection() }
                        )
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

                        // Diagnostics drawer: lets users turn on live debug
                        // logging and export a txt/json report for us to triage.
                        DiagnosticsDrawer()
                            .environmentObject(cameraManager)
                            .padding(.top, DesignSystem.Spacing.medium)
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

// MARK: - Stream Stalled Banner

/// Surfaces the stream-stall watchdog state. The user MUST see this if frames
/// have stopped flowing -- silent failure during an fMRI scan invalidates data.
struct StreamStalledBanner: View {
    let durationSec: Double
    let onRecover: () -> Void

    private var durationText: String {
        String(format: "%.1f", durationSec)
    }

    var body: some View {
        HStack(spacing: DesignSystem.Spacing.small) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 18, weight: .bold))
                .foregroundColor(.white)
            VStack(alignment: .leading, spacing: 2) {
                Text("Stream stalled — frames not flowing")
                    .font(DesignSystem.Typography.callout)
                    .fontWeight(.semibold)
                    .foregroundColor(.white)
                Text("No frame has been delivered in \(durationText)s. Recording may be losing data.")
                    .font(DesignSystem.Typography.caption)
                    .foregroundColor(.white.opacity(0.9))
            }
            Spacer()
            Button(action: onRecover) {
                Text("Reconnect")
                    .font(DesignSystem.Typography.caption)
                    .fontWeight(.semibold)
                    .foregroundColor(.red)
                    .padding(.horizontal, DesignSystem.Spacing.small)
                    .padding(.vertical, 4)
                    .background(Color.white)
                    .cornerRadius(DesignSystem.CornerRadius.small)
            }
            .buttonStyle(PlainButtonStyle())
        }
        .padding(DesignSystem.Spacing.medium)
        .background(Color.red)
        .cornerRadius(DesignSystem.CornerRadius.medium)
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

            // Stall overlay. We deliberately keep `currentImage` visible
            // beneath this so the user sees the last good frame, not black.
            if frameHandler.previewStalled {
                VStack {
                    HStack(spacing: DesignSystem.Spacing.xSmall) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundColor(.black)
                        Text("Preview stalled — last frame frozen")
                            .font(DesignSystem.Typography.caption)
                            .fontWeight(.semibold)
                            .foregroundColor(.black)
                    }
                    .padding(.horizontal, DesignSystem.Spacing.small)
                    .padding(.vertical, DesignSystem.Spacing.xSmall)
                    .background(Color.yellow)
                    .cornerRadius(DesignSystem.CornerRadius.small)
                    .padding(.top, DesignSystem.Spacing.small)
                    Spacer()
                }
            }
        }
        .frame(height: 300)
        .onAppear {
            print("CameraPreviewSection: ===== VIEW APPEARED =====")
            hasAppeared = true
            frameHandler.startReceivingFrames()
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
    /// True when the preview has gone stale (no new frame for >2s while the
    /// camera reports it is streaming) but the camera previously delivered at
    /// least one frame. Surfaces a banner over the last good image instead of
    /// silently going black.
    @Published var previewStalled = false
    /// Mach-uptime ns of the last successful image assignment. 0 until the
    /// first frame is rendered.
    private var lastPreviewUptimeNs: UInt64 = 0
    private var stallWatchdog: Timer?
    private static let previewStallTimeoutNs: UInt64 = 2_000_000_000

    private let gigEManager = GigECameraManager.shared
    private var frameCount = 0

    // Reused once; color management disabled (a live preview needs no colorimetric
    // accuracy). Reusing the CIContext is Apple's #1 Core Image performance rule.
    private let ciContext = CIContext(options: [.workingColorSpace: NSNull()])
    private let maxPreviewWidth: CGFloat = 1280

    init() {
        // Wire onPreviewFrame at construction time, BEFORE any frame can arrive.
        // The previous design only assigned the callback after an asyncAfter
        // delay (and only if the camera was already connected); if the preview
        // view appeared during camera reconnect, the callback was never set and
        // the preview stayed black until the user toggled Hide/Show.
        setupFrameHandler()
        startStallWatchdog()
    }

    deinit {
        stallWatchdog?.invalidate()
    }

    private func startStallWatchdog() {
        stallWatchdog?.invalidate()
        stallWatchdog = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.tickStallWatchdog()
        }
    }

    private func tickStallWatchdog() {
        // Only meaningful while we've previously rendered at least one frame
        // AND the camera reports it should be streaming. Otherwise the absence
        // of frames is expected (e.g. preview hidden, camera not connected) and
        // surfacing a "stalled" banner would be misleading.
        guard lastPreviewUptimeNs != 0, gigEManager.isStreaming else {
            if previewStalled { previewStalled = false }
            return
        }
        let now = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
        let stale = (now &- lastPreviewUptimeNs) > Self.previewStallTimeoutNs
        if stale != previewStalled {
            previewStalled = stale
        }
    }

    func startReceivingFrames() {
        print("PreviewFrameHandler: Starting to receive frames")
        // The callback is already registered from init(). All we do here is
        // make sure the camera is streaming so frames actually flow.
        if !gigEManager.isStreaming {
            print("PreviewFrameHandler: Starting streaming...")
            gigEManager.startStreaming()
        } else {
            print("PreviewFrameHandler: Already streaming")
        }
    }
    
    private func setupFrameHandler() {
        print("PreviewFrameHandler: Setting up frame handler")

        // Use the preview slot callback (drop-to-latest, independent of stream path).
        gigEManager.onPreviewFrame = { [weak self] frame in
            guard let self = self else { return }
            self.frameCount += 1

            // Runs on GigECameraManager.previewQueue (background serial queue).
            // Render at preview size with the reused context; only the image
            // assignment touches the main thread.
            let source = CIImage(cvPixelBuffer: frame.pixelBuffer)
            let width = source.extent.width
            let scale = width > self.maxPreviewWidth ? self.maxPreviewWidth / width : 1.0
            let scaled = scale < 1.0
                ? source.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
                : source
            guard let cgImage = self.ciContext.createCGImage(scaled, from: scaled.extent) else { return }
            let nsImage = NSImage(cgImage: cgImage,
                                  size: NSSize(width: cgImage.width, height: cgImage.height))

            let nowUptime = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
            DispatchQueue.main.async {
                self.currentImage = nsImage
                self.lastPreviewUptimeNs = nowUptime
                if self.previewStalled { self.previewStalled = false }
            }
        }

        print("PreviewFrameHandler: Frame handler added")
    }

    func stopReceivingFrames() {
        print("PreviewFrameHandler: Stopping frame reception after \(frameCount) frames")
        // Detach the preview only. The stream path is independent and must keep
        // running for any recording consumer, so do NOT stop streaming here.
        gigEManager.onPreviewFrame = nil
        frameCount = 0
    }
}

// MARK: - Diagnostics Drawer

/// Collapsible drawer showing recent in-process log entries and a state
/// snapshot. Two export buttons write the same data to `.txt` or `.json` so
/// users can email us a report when something goes wrong during a scan.
///
/// Live mode is OFF by default. When ON, the underlying `DiagnosticsLog`
/// polls `OSLogStore` every 1 s. When OFF, the drawer still shows the most
/// recent snapshot, but it doesn't keep growing.
struct DiagnosticsDrawer: View {
    @EnvironmentObject var cameraManager: CameraManager
    @ObservedObject private var log = DiagnosticsLog.shared
    @State private var isExpanded = false

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            VStack(alignment: .leading, spacing: DesignSystem.Spacing.small) {
                Toggle(isOn: liveBinding) {
                    HStack(spacing: DesignSystem.Spacing.xSmall) {
                        Image(systemName: log.isLive ? "dot.radiowaves.left.and.right" : "pause.circle")
                            .foregroundColor(log.isLive ? .green : .gray)
                        Text("Live debugging")
                            .font(DesignSystem.Typography.callout)
                        Text(log.isLive ? "(polling this app's log every 1 s)" : "(off)")
                            .font(DesignSystem.Typography.caption)
                            .foregroundColor(DesignSystem.Colors.textSecondary)
                    }
                }
                .toggleStyle(.switch)

                // Scope disclosure: OSLogStore(.currentProcessIdentifier) only
                // returns this process's log entries. The Camera Extension is
                // a separate process and its log isn't captured here. The
                // state-snapshot section of the export DOES reflect extension
                // health (sink connected, stream stalled, PTS nudges) via the
                // app/extension shared state, so reports remain triageable.
                Text("Captures this app only — Camera Extension runs in a separate process and its log isn't included. The state snapshot section of the export still reflects extension health.")
                    .font(DesignSystem.Typography.caption)
                    .foregroundColor(DesignSystem.Colors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)

                logScroll

                HStack(spacing: DesignSystem.Spacing.small) {
                    Button("Refresh") { log.loadInitialSnapshot() }
                    Button("Clear") { log.clear() }
                    Spacer()
                    Button("Copy to clipboard") { copyToPasteboard() }
                    Button("Export .txt") { exportTxt() }
                    Button("Export .json") { exportJson() }
                }
                .font(DesignSystem.Typography.caption)
            }
            .padding(.top, DesignSystem.Spacing.small)
        } label: {
            HStack(spacing: DesignSystem.Spacing.xSmall) {
                Image(systemName: "stethoscope")
                Text("Diagnostics")
                    .font(DesignSystem.Typography.callout)
                    .fontWeight(.medium)
                if log.isLive {
                    Text("LIVE")
                        .font(DesignSystem.Typography.caption)
                        .fontWeight(.semibold)
                        .foregroundColor(.white)
                        .padding(.horizontal, DesignSystem.Spacing.xSmall)
                        .padding(.vertical, 2)
                        .background(Color.green)
                        .cornerRadius(DesignSystem.CornerRadius.small)
                }
                Spacer()
                if !log.entries.isEmpty {
                    Text("\(log.entries.count) entries")
                        .font(DesignSystem.Typography.caption)
                        .foregroundColor(DesignSystem.Colors.textSecondary)
                }
            }
        }
        .onAppear { log.loadInitialSnapshot() }
    }

    private var liveBinding: Binding<Bool> {
        Binding(
            get: { log.isLive },
            set: { newValue in
                if newValue { log.startLive() } else { log.stopLive() }
            }
        )
    }

    private var logScroll: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1) {
                    if log.entries.isEmpty {
                        Text("No log entries yet. Turn on Live debugging to start capturing, or click Refresh to load the last 5 minutes.")
                            .font(DesignSystem.Typography.caption)
                            .foregroundColor(.gray)
                            .padding(DesignSystem.Spacing.small)
                    } else {
                        ForEach(log.entries) { entry in
                            DiagnosticsLogRow(entry: entry).id(entry.id)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(height: 220)
            .background(Color.black.opacity(0.35))
            .cornerRadius(DesignSystem.CornerRadius.small)
            .onChange(of: log.entries.count) { _ in
                guard let last = log.entries.last else { return }
                withAnimation(.easeOut(duration: 0.15)) {
                    proxy.scrollTo(last.id, anchor: .bottom)
                }
            }
        }
    }

    // MARK: - Export

    private func copyToPasteboard() {
        let snapshot = log.captureSnapshot(from: cameraManager)
        let text = log.renderTxt(snapshot: snapshot)
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
    }

    private func exportTxt() {
        let snapshot = log.captureSnapshot(from: cameraManager)
        let text = log.renderTxt(snapshot: snapshot)
        saveToFile(data: Data(text.utf8), suggestedExt: "txt", contentType: .plainText)
    }

    private func exportJson() {
        let snapshot = log.captureSnapshot(from: cameraManager)
        let data = log.renderJson(snapshot: snapshot)
        saveToFile(data: data, suggestedExt: "json", contentType: .json)
    }

    private func saveToFile(data: Data, suggestedExt: String, contentType: UTType) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [contentType]
        let stamp = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
        panel.nameFieldStringValue = "gige-diagnostics-\(stamp).\(suggestedExt)"
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try data.write(to: url)
        } catch {
            // Surface the failure visibly. The previous version only NSLog'd
            // it; users assumed the file was saved and would email us with
            // no attachment.
            NSLog("Diagnostics export failed: \(error.localizedDescription)")
            let alert = NSAlert()
            alert.messageText = "Could not save diagnostics report"
            alert.informativeText = "\(error.localizedDescription)\n\nTry saving to a different location (e.g. your Desktop) and then send us the file."
            alert.alertStyle = .warning
            alert.addButton(withTitle: "OK")
            alert.runModal()
        }
    }
}

struct DiagnosticsLogRow: View {
    let entry: DiagnosticsLog.Entry

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    private var levelColor: Color {
        switch entry.level {
        case "ERROR", "FAULT": return .red
        case "NOTICE": return .yellow
        case "INFO": return .white
        case "DEBUG": return .gray
        default: return .gray
        }
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(Self.timeFormatter.string(from: entry.timestamp))
                .foregroundColor(.gray)
            Text(entry.level)
                .foregroundColor(levelColor)
                .frame(width: 56, alignment: .leading)
            Text(entry.category)
                .foregroundColor(.cyan)
                .frame(width: 110, alignment: .leading)
                .lineLimit(1)
            Text(entry.message)
                .foregroundColor(.white)
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(.system(size: 10.5, design: .monospaced))
        .padding(.horizontal, DesignSystem.Spacing.xSmall)
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