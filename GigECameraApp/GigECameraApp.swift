//
//  GigECameraApp.swift
//  GigEVirtualCamera
//
//  Created on 6/24/25.
//

import SwiftUI

@main
struct GigECameraApp: App {
    @StateObject private var cameraManager = CameraManager.shared
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    // Fixed window footprint. The two-column layout in ContentView is sized
    // around this; resizing leaves dead space or clips. Long content (the
    // diagnostics log) scrolls inside the Diagnostics drawer.
    private static let windowWidth: CGFloat = 960
    private static let windowHeight: CGFloat = 680

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(cameraManager)
                .frame(width: Self.windowWidth, height: Self.windowHeight)
                .onAppear {
                    DispatchQueue.main.async {
                        guard let window = NSApplication.shared.windows.first else { return }
                        let size = NSSize(width: Self.windowWidth, height: Self.windowHeight)
                        window.setContentSize(size)
                        window.contentMinSize = size
                        window.contentMaxSize = size
                        window.styleMask.remove(.resizable)
                        window.center()
                    }
                }
        }
        
        // Menu bar commands
        .commands {
            CommandGroup(replacing: .appInfo) {
                Button("About GigE Virtual Camera") {
                    NSApp.orderFrontStandardAboutPanel(options: [
                        NSApplication.AboutPanelOptionKey.applicationName: "GigE Virtual Camera",
                        NSApplication.AboutPanelOptionKey.applicationVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0",
                        NSApplication.AboutPanelOptionKey.version: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1",
                        NSApplication.AboutPanelOptionKey(rawValue: "Copyright"): "© 2025 Luke Chang"
                    ])
                }
            }
        }
    }
}

class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Set activation policy
        NSApp.setActivationPolicy(.regular)
        
        // Bring to front
        NSApp.activate(ignoringOtherApps: true)
        
        // Extension installation is now handled manually via UI buttons
    }
    
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return true
    }
    
    func applicationWillTerminate(_ notification: Notification) {
        // Clean up preview if open
        CameraManager.shared.hidePreview()
    }
}