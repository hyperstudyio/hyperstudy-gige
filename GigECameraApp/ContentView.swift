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
import FramePipelineKit

struct ContentView: View {
    @EnvironmentObject var cameraManager: CameraManager
    // ExtensionManager is a singleton (static let shared); wrap as
    // @ObservedObject so SwiftUI subscribes to its @Published changes
    // without taking ownership of its lifecycle. The previous @StateObject
    // matched the anti-pattern that was fixed for CameraManager.
    @ObservedObject private var extensionManager = ExtensionManager.shared
    @State private var isDiscoveringCameras = false
    /// Brief "✓ Refreshed" indicator next to the camera refresh button.
    /// Cleared via a cancellable work item so rapid clicks don't queue
    /// overlapping `asyncAfter` blocks that fight to set/clear the label.
    @State private var refreshFeedback: String?
    @State private var refreshFeedbackClearWork: DispatchWorkItem?
    @State private var refreshFinishWork: DispatchWorkItem?
    /// Collapsed state for the Camera Controls sliders. Expanded by default
    /// so power users see them; researchers running a long scan can collapse
    /// to keep the right column tidy.
    @State private var slidersExpanded = true
    
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
            return DesignSystem.Colors.statusSuccess
        case "Failed":
            return DesignSystem.Colors.statusError
        default:
            return DesignSystem.Colors.textSecondary
        }
    }
    
    var body: some View {
        // The OS window title bar already reads "GigEVirtualCamera"; the
        // previous in-app HeaderView ("GigE Virtual Camera" + animated camera
        // icon) duplicated that and ate ~100 px of fixed-height vertical
        // space without adding information.
        ZStack {
            VisualEffectBackground()

            HStack(spacing: 0) {
                previewColumn
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                Divider()

                controlsColumn
                    .frame(width: 360)
            }
        }
        .frame(minWidth: 820, idealWidth: 960, minHeight: 560, idealHeight: 680)
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("GigECamerasDiscovered"))) { _ in
            isDiscoveringCameras = false
        }
    }

    // MARK: - Left column (preview + live status)

    private var previewColumn: some View {
        VStack(spacing: DesignSystem.Spacing.small) {
            CameraPreviewSection()
                .environmentObject(cameraManager)
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            if cameraManager.streamStalled {
                StreamStalledBanner(
                    durationSec: cameraManager.streamStallDurationSec,
                    onRecover: { cameraManager.retryFrameSenderConnection() }
                )
            }

            liveStatusFooter
        }
        .padding(DesignSystem.Spacing.medium)
    }

    private var liveStatusFooter: some View {
        HStack(spacing: DesignSystem.Spacing.medium) {
            HStack(spacing: 4) {
                if cameraManager.connectionState == "Connecting" {
                    ProgressView()
                        .progressViewStyle(CircularProgressViewStyle())
                        .scaleEffect(0.55)
                        .frame(width: 12, height: 12)
                } else {
                    Image(systemName: connectionStateIcon)
                        .foregroundColor(connectionStateColor)
                        .font(.system(size: 12))
                }
                Text(connectionStateText)
                    .font(DesignSystem.Typography.callout)
                    .fontWeight(.medium)
                    .foregroundColor(connectionStateColor)
            }

            if cameraManager.isConnected {
                Divider().frame(height: 14)

                HStack(spacing: 4) {
                    Image(systemName: "arrow.triangle.2.circlepath")
                        .foregroundColor(cameraManager.isFrameSenderConnected
                                         ? DesignSystem.Colors.statusSuccess
                                         : DesignSystem.Colors.statusOrange)
                        .font(.system(size: 11))
                    Text(cameraManager.isFrameSenderConnected ? "Sink connected" : "Sink waiting…")
                        .font(DesignSystem.Typography.caption)
                        .foregroundColor(DesignSystem.Colors.textSecondary)
                }

                Divider().frame(height: 14)

                Text(cameraManager.cameraModel)
                    .font(DesignSystem.Typography.caption)
                    .foregroundColor(DesignSystem.Colors.textSecondary)
                    .lineLimit(1)
            } else if cameraManager.connectionState == "Failed" {
                Button {
                    cameraManager.retryConnection()
                } label: {
                    Label("Retry", systemImage: "arrow.clockwise")
                        .font(DesignSystem.Typography.caption)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }

            Spacer()
        }
    }

    // MARK: - Right column (controls + diagnostics)

    private var controlsColumn: some View {
        ScrollView {
            VStack(spacing: DesignSystem.Spacing.medium) {
                extensionStatusSection
                cameraSelectorSection
                if cameraManager.isConnected {
                    formatSection
                    slidersSection
                }
                DiagnosticsDrawer()
                    .environmentObject(cameraManager)
            }
            .padding(DesignSystem.Spacing.medium)
        }
    }

    /// Compact extension card. When the extension is not yet installed the
    /// "Install Extension" action is surfaced as a prominent inline button
    /// so first-launch users can't miss it; once installed, the ellipsis
    /// menu hosts the rare Uninstall path. Debug output (when present)
    /// hides behind a "Details" disclosure rather than dumping monospaced
    /// text into the main UI.
    private var extensionStatusSection: some View {
        let status = extensionManager.extensionStatus
        let isInstalled = status == "Installed"
        let needsApproval = status == "Needs Approval"
        let hasDebug = !extensionManager.statusMessage.isEmpty || !extensionManager.errorDetail.isEmpty
        let statusColor: Color = isInstalled
            ? DesignSystem.Colors.statusSuccess
            : (needsApproval ? DesignSystem.Colors.statusOrange : DesignSystem.Colors.textSecondary)

        return VStack(alignment: .leading, spacing: DesignSystem.Spacing.xSmall) {
            HStack(spacing: DesignSystem.Spacing.xSmall) {
                Image(systemName: "puzzlepiece.extension")
                    .foregroundColor(DesignSystem.Colors.textSecondary)
                Text("Camera Extension")
                    .font(DesignSystem.Typography.callout)
                    .foregroundColor(DesignSystem.Colors.textSecondary)
                Spacer()
                Circle()
                    .fill(statusColor)
                    .frame(width: 7, height: 7)
                Text(status)
                    .font(DesignSystem.Typography.caption)
                    .fontWeight(.medium)
                    .foregroundColor(statusColor)
                // Ellipsis menu is only useful once installed (for Uninstall).
                // Hide it on the first-launch path so the prominent Install
                // button below is the only thing competing for attention.
                if isInstalled {
                    Menu {
                        Button {
                            extensionManager.uninstallExtension()
                        } label: {
                            Label("Uninstall Extension", systemImage: "minus.circle")
                        }
                        .disabled(extensionManager.isInstalling)
                    } label: {
                        Image(systemName: "ellipsis.circle")
                            .foregroundColor(DesignSystem.Colors.textSecondary)
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .help("Manage extension")
                }
            }

            // Primary call-to-action when the extension isn't installed.
            // Lab techs setting up a new machine see this immediately
            // instead of having to discover an ellipsis menu.
            if !isInstalled {
                Button {
                    extensionManager.installExtension()
                } label: {
                    HStack(spacing: 4) {
                        if extensionManager.isInstalling {
                            ProgressView()
                                .progressViewStyle(CircularProgressViewStyle(tint: DesignSystem.Colors.textOnAccent))
                                .scaleEffect(0.55)
                                .frame(width: 12, height: 12)
                            Text("Installing…")
                        } else {
                            Image(systemName: "plus.circle.fill")
                            Text("Install Extension")
                        }
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(extensionManager.isInstalling)
            }

            if needsApproval {
                HStack(spacing: DesignSystem.Spacing.xSmall) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundColor(DesignSystem.Colors.statusOrange)
                    Text("Approve in System Settings → Privacy & Security")
                        .font(DesignSystem.Typography.caption)
                        .foregroundColor(DesignSystem.Colors.statusOrange)
                }
            }

            if hasDebug {
                DisclosureGroup {
                    VStack(alignment: .leading, spacing: 4) {
                        if !extensionManager.statusMessage.isEmpty {
                            Text(extensionManager.statusMessage)
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundColor(DesignSystem.Colors.statusInfo)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        if !extensionManager.errorDetail.isEmpty {
                            Text(extensionManager.errorDetail)
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundColor(DesignSystem.Colors.statusError)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    .padding(DesignSystem.Spacing.xSmall)
                    .background(DesignSystem.Colors.logSurface)
                    .cornerRadius(DesignSystem.CornerRadius.small)
                } label: {
                    Text("Details")
                        .font(DesignSystem.Typography.caption)
                        .foregroundColor(DesignSystem.Colors.textSecondary)
                }
            }
        }
        .padding(DesignSystem.Spacing.small)
        .background(
            RoundedRectangle(cornerRadius: DesignSystem.CornerRadius.medium)
                .fill(DesignSystem.Colors.backgroundSecondary.opacity(0.6))
        )
    }

    private var cameraSelectorSection: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.xSmall) {
            HStack {
                Label("Camera", systemImage: "camera.on.rectangle")
                    .font(DesignSystem.Typography.callout)
                    .foregroundColor(DesignSystem.Colors.textSecondary)
                Spacer()
                // "Refreshing…" appears immediately on click and is replaced
                // by "✓ Refreshed" when discovery completes -- single
                // continuous phase instead of the previous "click, wait 2.5
                // s with no feedback, then briefly flash a checkmark".
                if isDiscoveringCameras {
                    HStack(spacing: 4) {
                        ProgressView()
                            .progressViewStyle(CircularProgressViewStyle())
                            .scaleEffect(0.55)
                            .frame(width: 11, height: 11)
                        Text("Refreshing…")
                            .font(DesignSystem.Typography.caption)
                            .foregroundColor(DesignSystem.Colors.textSecondary)
                    }
                    .transition(.opacity)
                } else if let feedback = refreshFeedback {
                    Text(feedback)
                        .font(DesignSystem.Typography.caption)
                        .foregroundColor(DesignSystem.Colors.statusSuccess)
                        .transition(.opacity)
                }
                Button {
                    triggerCameraRefresh()
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 11))
                }
                .buttonStyle(.borderless)
                .help("Refresh camera list")
                .disabled(isDiscoveringCameras)
            }

            Menu {
                Button("None") {
                    cameraManager.selectedCameraId = nil
                }
                Divider()
                if isDiscoveringCameras {
                    Text("Searching for cameras…")
                } else if cameraManager.availableCameras.isEmpty {
                    Text("No cameras found")
                } else {
                    ForEach(cameraManager.availableCameras, id: \.deviceId) { camera in
                        Button("\(camera.name) (\(camera.ipAddress))") {
                            cameraManager.selectedCameraId = camera.deviceId
                        }
                    }
                }
            } label: {
                HStack {
                    if isDiscoveringCameras {
                        ProgressView()
                            .progressViewStyle(CircularProgressViewStyle())
                            .scaleEffect(0.6)
                            .frame(width: 12, height: 12)
                        Text("Searching…")
                            .frame(maxWidth: .infinity, alignment: .leading)
                    } else {
                        Text(selectedCameraText)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .lineLimit(1)
                    }
                    Image(systemName: "chevron.down")
                        .font(.caption)
                        .foregroundColor(DesignSystem.Colors.textSecondary)
                }
                .padding(.horizontal, DesignSystem.Spacing.small)
                .padding(.vertical, DesignSystem.Spacing.xSmall)
                .background(
                    RoundedRectangle(cornerRadius: DesignSystem.CornerRadius.small)
                        .stroke(DesignSystem.Colors.border, lineWidth: 1)
                        .background(
                            RoundedRectangle(cornerRadius: DesignSystem.CornerRadius.small)
                                .fill(DesignSystem.Colors.backgroundSecondary.opacity(0.4))
                        )
                )
            }
            .menuStyle(.borderlessButton)
        }
    }

    /// Kicks the camera-discovery flow and drives a single piece of UI
    /// feedback: a "Refreshing…" spinner appears immediately, then is
    /// replaced by "✓ Refreshed" when discovery completes, then fades.
    /// All transitions are driven by cancellable `DispatchWorkItem`s so
    /// rapid clicks can't race overlapping `asyncAfter` blocks.
    private func triggerCameraRefresh() {
        refreshFinishWork?.cancel()
        refreshFeedbackClearWork?.cancel()

        withAnimation {
            isDiscoveringCameras = true
            refreshFeedback = nil
        }
        cameraManager.refreshCameraList()

        let finish = DispatchWorkItem {
            withAnimation {
                isDiscoveringCameras = false
                refreshFeedback = "✓ Refreshed"
            }
            let clear = DispatchWorkItem {
                withAnimation { refreshFeedback = nil }
            }
            refreshFeedbackClearWork = clear
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: clear)
        }
        refreshFinishWork = finish
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5, execute: finish)
    }

    private var formatSection: some View {
        VStack(spacing: DesignSystem.Spacing.xSmall) {
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
                .pickerStyle(.menu)
                .labelsHidden()
                .frame(maxWidth: 210)
            }
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
                .pickerStyle(.menu)
                .labelsHidden()
                .frame(maxWidth: 180)
            }
        }
    }

    @ViewBuilder
    private var slidersSection: some View {
        let anyAvailable = cameraManager.exposureTimeAvailable
            || cameraManager.gainAvailable
            || (cameraManager.frameRateAvailable && cameraManager.selectedFormatIndex != 0)

        if anyAvailable {
            DisclosureGroup(isExpanded: $slidersExpanded) {
                VStack(spacing: DesignSystem.Spacing.small) {
                    if cameraManager.exposureTimeAvailable {
                        // No `step:` here: exposure ranges span ~100 µs to
                        // ~100 ms (default 100…100000). With step:1 SwiftUI
                        // asks AppKit to lay out ~99,900 tick marks, and
                        // NSSlider's tick-mark rebuild allocates ~1M tiny
                        // CoreUI objects and freezes the main thread for many
                        // seconds. The displayed value is rounded to Int µs
                        // anyway, and the camera API takes a Double, so we
                        // lose nothing by leaving the slider continuous.
                        sliderRow(
                            label: "Exposure",
                            icon: "timer",
                            value: "\(Int(cameraManager.exposureTime)) µs",
                            binding: $cameraManager.exposureTime,
                            range: cameraManager.exposureTimeMin...cameraManager.exposureTimeMax
                        )
                    }
                    if cameraManager.gainAvailable {
                        sliderRow(
                            label: "Gain",
                            icon: "dial.high",
                            value: String(format: "%.1fx", cameraManager.gain),
                            binding: $cameraManager.gain,
                            range: cameraManager.gainMin...cameraManager.gainMax,
                            step: 0.1
                        )
                    }
                    if cameraManager.frameRateAvailable && cameraManager.selectedFormatIndex != 0 {
                        sliderRow(
                            label: "Frame Rate",
                            icon: "speedometer",
                            value: "\(Int(cameraManager.frameRate)) fps",
                            binding: $cameraManager.frameRate,
                            range: cameraManager.frameRateMin...cameraManager.frameRateMax,
                            step: 1
                        )
                    }
                }
                .padding(.top, DesignSystem.Spacing.xSmall)
            } label: {
                Label("Camera Controls", systemImage: "slider.horizontal.3")
                    .font(DesignSystem.Typography.callout)
                    .foregroundColor(DesignSystem.Colors.textSecondary)
            }
        } else {
            HStack {
                Image(systemName: "info.circle")
                    .foregroundColor(DesignSystem.Colors.statusOrange)
                Text("Camera controls not available")
                    .font(DesignSystem.Typography.caption)
                    .foregroundColor(DesignSystem.Colors.statusOrange)
            }
        }
    }

    private func sliderRow(label: String, icon: String, value: String,
                           binding: Binding<Double>, range: ClosedRange<Double>,
                           step: Double? = nil) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Label(label, systemImage: icon)
                    .font(DesignSystem.Typography.caption)
                    .foregroundColor(DesignSystem.Colors.textSecondary)
                Spacer()
                Text(value)
                    .font(DesignSystem.Typography.caption)
                    .foregroundColor(DesignSystem.Colors.textPrimary)
                    .monospacedDigit()
            }
            // Passing `step:` to SwiftUI's Slider asks AppKit to draw
            // `(max-min)/step + 1` tick marks. For wide ranges this freezes
            // the main thread (NSSliderTickMarks._rebuildTickMarkRectCache is
            // O(N) with per-tick CoreUI rendering). Callers with wide ranges
            // pass `step: nil` to opt out.
            Group {
                if let step {
                    Slider(value: binding, in: range, step: step)
                } else {
                    Slider(value: binding, in: range)
                }
            }
            .controlSize(.small)
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
                .foregroundColor(DesignSystem.Colors.textOnAccent)
            VStack(alignment: .leading, spacing: 2) {
                Text("Stream stalled — frames not flowing")
                    .font(DesignSystem.Typography.callout)
                    .fontWeight(.semibold)
                    .foregroundColor(DesignSystem.Colors.textOnAccent)
                Text("No frame has been delivered in \(durationText)s. Recording may be losing data.")
                    .font(DesignSystem.Typography.caption)
                    .foregroundColor(DesignSystem.Colors.textOnAccent.opacity(0.9))
            }
            Spacer()
            // Bold filled button so the recovery action reads as the primary
            // CTA even on a saturated red banner -- the previous "white pill
            // with red text" was visually muted on a red surface.
            Button(action: onRecover) {
                HStack(spacing: 4) {
                    Image(systemName: "arrow.clockwise")
                    Text("Reconnect")
                        .fontWeight(.semibold)
                }
                .font(DesignSystem.Typography.caption)
                .foregroundColor(DesignSystem.Colors.statusError)
                .padding(.horizontal, DesignSystem.Spacing.small)
                .padding(.vertical, 5)
                .background(DesignSystem.Colors.textOnAccent)
                .cornerRadius(DesignSystem.CornerRadius.small)
                .shadow(color: .black.opacity(0.2), radius: 1, y: 1)
            }
            .buttonStyle(.plain)
        }
        .padding(DesignSystem.Spacing.medium)
        .background(DesignSystem.Colors.statusError)
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
    @EnvironmentObject var cameraManager: CameraManager
    @StateObject private var frameHandler = PreviewFrameHandler()

    var body: some View {
        ZStack {
            // True-black surface (intentionally non-adaptive -- pro video apps
            // use black so colour grading isn't confused by ambient tint).
            RoundedRectangle(cornerRadius: DesignSystem.CornerRadius.medium)
                .fill(DesignSystem.Colors.videoSurface)

            if let image = frameHandler.currentImage {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .cornerRadius(DesignSystem.CornerRadius.medium)
                    .padding(DesignSystem.Spacing.xSmall)
            } else {
                emptyPreviewState
            }

            // Stall overlay. We deliberately keep `currentImage` visible
            // beneath this so the user sees the last good frame, not black.
            if frameHandler.previewStalled {
                VStack {
                    HStack(spacing: DesignSystem.Spacing.xSmall) {
                        Image(systemName: "exclamationmark.triangle.fill")
                        Text("Preview stalled — last frame frozen")
                            .font(DesignSystem.Typography.caption)
                            .fontWeight(.semibold)
                    }
                    .foregroundColor(.black)
                    .padding(.horizontal, DesignSystem.Spacing.small)
                    .padding(.vertical, DesignSystem.Spacing.xSmall)
                    .background(DesignSystem.Colors.statusWarning)
                    .cornerRadius(DesignSystem.CornerRadius.small)
                    .padding(.top, DesignSystem.Spacing.small)
                    Spacer()
                }
            }

            // Thin inner stroke gives the preview the feel of a pro monitor
            // frame instead of "raw black rectangle".
            RoundedRectangle(cornerRadius: DesignSystem.CornerRadius.medium)
                .stroke(DesignSystem.Colors.border.opacity(0.6), lineWidth: 1)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .frame(minHeight: 280)
        // No onAppear/onDisappear: the preview is always rendered in the new
        // two-column layout, so SwiftUI never fires those callbacks. The
        // frame-handler closure is wired in PreviewFrameHandler.init() and
        // lives for the WindowGroup's lifetime.
    }

    /// State-aware preview empty state. The previous design always showed a
    /// spinning ProgressView, which made the app feel "busy" before the user
    /// had even done anything. Now we read `cameraManager` state and only
    /// animate when something is actually happening:
    ///
    /// - No camera selected → static camera icon + "Select a camera to begin"
    /// - Connecting          → spinner + "Connecting…"
    /// - Connected, no frame → spinner + "Waiting for first frame…"
    @ViewBuilder
    private var emptyPreviewState: some View {
        if cameraManager.connectionState == "Connecting" {
            VStack(spacing: DesignSystem.Spacing.small) {
                ProgressView()
                    .progressViewStyle(CircularProgressViewStyle(tint: DesignSystem.Colors.textOnAccent))
                Text("Connecting to camera…")
                    .font(DesignSystem.Typography.caption)
                    .foregroundColor(DesignSystem.Colors.textOnAccent)
            }
        } else if cameraManager.isConnected {
            // Camera reports connected but no frame has been rendered yet --
            // briefly true at startup between connect and the first frame
            // arriving via the preview slot.
            VStack(spacing: DesignSystem.Spacing.small) {
                ProgressView()
                    .progressViewStyle(CircularProgressViewStyle(tint: DesignSystem.Colors.textOnAccent))
                Text("Waiting for first frame…")
                    .font(DesignSystem.Typography.caption)
                    .foregroundColor(DesignSystem.Colors.textOnAccent)
            }
        } else {
            VStack(spacing: DesignSystem.Spacing.small) {
                Image(systemName: "camera")
                    .font(.system(size: 36, weight: .light))
                    .foregroundColor(DesignSystem.Colors.textOnAccent.opacity(0.45))
                Text(cameraManager.availableCameras.isEmpty
                     ? "No cameras found on the network"
                     : "Select a camera to begin")
                    .font(DesignSystem.Typography.caption)
                    .foregroundColor(DesignSystem.Colors.textOnAccent.opacity(0.7))
            }
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

    // Drop-to-latest slot for the main-thread image hop. Without this, the
    // preview callback was scheduling a `DispatchQueue.main.async` per frame
    // and capturing the rendered NSImage by value; when SwiftUI fell even
    // slightly behind 30 fps, the pending closures piled up unbounded — each
    // retaining a multi-MB NSImage — and the process grew at hundreds of
    // MB/sec until the machine OOMed. The slot bounds image retention to 1.
    //
    // The slot pairs the image with its render-time uptime so the main thread
    // assignment uses the latest frame's timestamp (not the stale one captured
    // when scheduling was first triggered).
    private struct PendingPreview {
        let image: NSImage
        let renderUptimeNs: UInt64
    }
    private let mainImageSlot = LatestFrameSlot<PendingPreview>()
    // Coalesces main-thread scheduling: at most one main-async is in flight
    // at a time, so the dispatch queue itself cannot accumulate either.
    private let mainScheduleLock = NSLock()
    private var mainUpdatePending = false

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

            // Drop-to-latest hop to main. Setting the slot displaces (and
            // releases) any prior NSImage that the main thread hasn't picked
            // up yet, so memory never grows beyond a single pending image
            // regardless of how backlogged main is. We schedule at most one
            // main-async update at a time so the dispatch queue itself can't
            // accumulate either.
            //
            // Both the producer (set + needs-schedule decision) and the
            // consumer (take + pending clear) run under `mainScheduleLock`
            // so they are atomic with respect to each other. Without this
            // serialisation a producer could observe pending=true while the
            // consumer was mid-render (between take and pending-clear), skip
            // scheduling, and the consumer would then clear pending without
            // ever rendering the producer's frame — leaving the frame
            // stranded in the slot until the next producer arrived.
            self.mainScheduleLock.lock()
            self.mainImageSlot.set(PendingPreview(image: nsImage, renderUptimeNs: nowUptime))
            let needsSchedule = !self.mainUpdatePending
            if needsSchedule { self.mainUpdatePending = true }
            self.mainScheduleLock.unlock()

            if needsSchedule {
                DispatchQueue.main.async { [weak self] in
                    guard let self = self else { return }
                    self.mainScheduleLock.lock()
                    let latest = self.mainImageSlot.take()
                    self.mainUpdatePending = false
                    self.mainScheduleLock.unlock()
                    guard let latest = latest else { return }
                    self.currentImage = latest.image
                    self.lastPreviewUptimeNs = latest.renderUptimeNs
                    if self.previewStalled { self.previewStalled = false }
                }
            }
        }

        print("PreviewFrameHandler: Frame handler added")
    }

    // No public start/stop API: the preview is always rendered in the new
    // two-column layout and the frame-handler closure is wired in init(),
    // so SwiftUI lifecycle callbacks never need to attach/detach it. The
    // closure is torn down when the @StateObject deinits at WindowGroup
    // close, which is the only path that matters.
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
    /// Brief "✓ Copied" / "✓ Saved" indicator shown next to the export
    /// toolbar after a successful action. Cleared via a cancellable work
    /// item so rapid Copy/Export clicks don't queue overlapping
    /// `asyncAfter` blocks that fight to set/clear the label.
    @State private var feedback: String?
    @State private var feedbackClearWork: DispatchWorkItem?
    /// Pending scroll-to-bottom work item. Replaced on each entries.count
    /// change so 20 entries arriving in one second produce one animation,
    /// not 20 -- the previous always-on `onChange { withAnimation { ... } }`
    /// thrashed the main thread during heavy logging.
    @State private var scrollDebounce: DispatchWorkItem?

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            VStack(alignment: .leading, spacing: DesignSystem.Spacing.small) {
                Toggle(isOn: liveBinding) {
                    HStack(spacing: DesignSystem.Spacing.xSmall) {
                        Image(systemName: log.isLive ? "dot.radiowaves.left.and.right" : "pause.circle")
                            .foregroundColor(log.isLive ? DesignSystem.Colors.statusSuccess : DesignSystem.Colors.textSecondary)
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

                // Two primary actions (Copy / Save), two secondary
                // (Refresh / Clear) -- the previous 5-button toolbar made
                // it hard to tell what was the canonical export action.
                HStack(spacing: DesignSystem.Spacing.small) {
                    Button("Refresh") { log.loadInitialSnapshot() }
                    Button("Clear") { log.clear() }
                    Spacer()
                    if let feedback = feedback {
                        Text(feedback)
                            .font(DesignSystem.Typography.caption)
                            .foregroundColor(DesignSystem.Colors.statusSuccess)
                            .transition(.opacity)
                    }
                    Button("Copy") { copyToPasteboard() }
                    Menu("Save…") {
                        Button("Save as .txt") { exportTxt() }
                        Button("Save as .json") { exportJson() }
                    }
                    .fixedSize()
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
                        .foregroundColor(DesignSystem.Colors.textOnAccent)
                        .padding(.horizontal, DesignSystem.Spacing.xSmall)
                        .padding(.vertical, 2)
                        .background(DesignSystem.Colors.statusSuccess)
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
        // Intentionally NO .onAppear { loadInitialSnapshot() }. The
        // AravisBridge logs ~50 entries/sec while the camera is streaming;
        // auto-loading recent history on the very first app launch made the
        // drawer freeze when expanded. Users now explicitly opt in by
        // clicking Refresh (small bounded fetch) or toggling Live.
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
                            .foregroundColor(DesignSystem.Colors.textSecondary)
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
            .background(DesignSystem.Colors.logSurface)
            .cornerRadius(DesignSystem.CornerRadius.small)
            .onChange(of: log.entries.count) { _ in
                scheduleScrollToBottom(proxy: proxy)
            }
        }
    }

    /// Coalesce scroll-to-bottom updates: replace any pending work item with
    /// a new one that fires after a short delay, so bursts of log entries
    /// (e.g., 20 in one polling tick) produce a single animation instead of
    /// twenty overlapping ones.
    private func scheduleScrollToBottom(proxy: ScrollViewProxy) {
        scrollDebounce?.cancel()
        let item = DispatchWorkItem {
            guard let last = log.entries.last else { return }
            withAnimation(.easeOut(duration: 0.15)) {
                proxy.scrollTo(last.id, anchor: .bottom)
            }
        }
        scrollDebounce = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: item)
    }

    private func flashFeedback(_ text: String) {
        feedbackClearWork?.cancel()
        withAnimation { feedback = text }
        let clear = DispatchWorkItem {
            withAnimation { feedback = nil }
        }
        feedbackClearWork = clear
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: clear)
    }

    // MARK: - Export

    private func copyToPasteboard() {
        let snapshot = log.captureSnapshot(from: cameraManager)
        let text = log.renderTxt(snapshot: snapshot)
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
        flashFeedback("✓ Copied")
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
        // Default to ~/Downloads (where users expect to find exports). macOS
        // will still remember the last-used location across saves within a
        // session, so picking a different folder once "sticks".
        if let downloads = try? FileManager.default.url(
            for: .downloadsDirectory, in: .userDomainMask,
            appropriateFor: nil, create: false
        ) {
            panel.directoryURL = downloads
        }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try data.write(to: url)
            flashFeedback("✓ Saved")
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
        case "ERROR", "FAULT": return DesignSystem.Colors.logError
        case "NOTICE":         return DesignSystem.Colors.logWarning
        case "INFO":           return DesignSystem.Colors.logInfo
        case "DEBUG":          return DesignSystem.Colors.logDebug
        default:               return DesignSystem.Colors.logDebug
        }
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(Self.timeFormatter.string(from: entry.timestamp))
                .foregroundColor(DesignSystem.Colors.textSecondary)
            Text(entry.level)
                .foregroundColor(levelColor)
                .frame(width: 56, alignment: .leading)
            Text(entry.category)
                .foregroundColor(DesignSystem.Colors.logCategory)
                .frame(width: 110, alignment: .leading)
                .lineLimit(1)
            Text(entry.message)
                .foregroundColor(DesignSystem.Colors.logInfo)
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