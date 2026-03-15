# GigE Virtual Camera for macOS

[![Build and Release](https://github.com/hyperstudyio/hyperstudy-gige/actions/workflows/build-and-release.yml/badge.svg)](https://github.com/hyperstudyio/hyperstudy-gige/actions/workflows/build-and-release.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)
[![macOS](https://img.shields.io/badge/macOS-12.3+-blue.svg)](https://www.apple.com/macos/)
[![Platform](https://img.shields.io/badge/platform-Apple%20Silicon-lightgrey.svg)](https://support.apple.com/en-us/HT211814)

A native macOS application that creates virtual cameras from GigE Vision industrial cameras, making them available to any macOS application (Zoom, Teams, OBS, QuickTime, Photo Booth, etc.).

## Features

- **System Extension Architecture**: Implements a proper CMIO System Extension for virtual camera functionality
- **Native macOS Integration**: Appears as a standard camera in all macOS apps
- **Universal GigE Support**: Works with any GigE Vision compliant camera via Aravis library
- **Real-time Preview**: Built-in preview with camera status and controls
- **Professional Features**: Designed for industrial and professional camera integration
- **Notarized & Signed**: Properly signed with Developer ID for secure distribution

## Requirements

- macOS 12.3 (Monterey) or later  
- ARM64 (Apple Silicon) Mac
- GigE Vision compliant camera on the same network
- System Extension approval (first launch only)

## Installation

### Download Release

**[Download the latest release →](https://github.com/hyperstudyio/hyperstudy-gige/releases/latest)**

### Step-by-Step Installation

1. **Download the DMG**
   - Go to the [Releases page](https://github.com/hyperstudyio/hyperstudy-gige/releases)
   - Download the latest `GigEVirtualCamera-vX.X.X.dmg` file
   - The app is fully signed and notarized by Apple

2. **Install the Application**
   - Double-click the downloaded DMG file to open it
   - Drag `GigEVirtualCamera.app` into your `Applications` folder
   - Eject the DMG

3. **First Launch**
   - Open the `Applications` folder
   - Double-click `GigEVirtualCamera.app` to launch
   - If you see a warning about an unidentified developer (shouldn't happen with notarization), right-click the app and select "Open"

4. **Grant System Extension Permission** ⚠️ **Important**

   When you first launch the app, macOS will display a notification:

   > **"System Extension Blocked"**
   > A program tried to load new system extension(s) signed by "Luke Chang"

   **To approve the extension:**
   - Click on the notification, or go to **System Settings** (System Preferences on older macOS)
   - Navigate to **Privacy & Security**
   - Scroll down to the **Security** section
   - You'll see a message: *"System software from developer 'Luke Chang' was blocked from loading"*
   - Click the **"Allow"** button next to this message
   - Enter your administrator password if prompted
   - **Restart the app** after approving

5. **Grant Camera Permissions**

   The app needs permission to access your GigE cameras:
   - Go to **System Settings** → **Privacy & Security** → **Camera**
   - Find **GigEVirtualCamera** in the list
   - Toggle it **ON** to grant camera access

6. **Verify Installation**

   After granting permissions, the virtual camera extension should be active:
   ```bash
   systemextensionsctl list
   ```

   You should see an entry for `com.lukechang.GigEVirtualCamera.Extension`

### Troubleshooting Installation

**System Extension not appearing:**
- Make sure you clicked "Allow" in System Settings → Privacy & Security
- Try restarting your Mac after allowing the extension
- Check the logs: `log stream --predicate 'subsystem == "com.lukechang.GigEVirtualCamera"'`

**"App is damaged" error:**
- The app should be notarized, so this shouldn't happen
- If it does, verify the download wasn't corrupted
- Try downloading again from the official releases page

**Permission dialogs not appearing:**
- Launch the app from Applications folder (not from the DMG)
- Check System Settings → Privacy & Security manually
- Restart the app after granting permissions

## For Developers

### Building from Source

**Prerequisites:**
- macOS 12.3+ (Apple Silicon recommended)
- Xcode 15.0+
- Homebrew

**Quick Start:**

```bash
# Clone the repository
git clone https://github.com/hyperstudyio/hyperstudy-gige.git
cd hyperstudy-gige

# Install dependencies
brew install aravis

# Open in Xcode
open GigEVirtualCamera.xcodeproj

# Build and run (Cmd+R)
```

The project will build with default settings. For development, code signing is handled automatically by Xcode.

**Detailed Build Instructions:**

See **[BUILDING.md](BUILDING.md)** for comprehensive information on:
- Environment configuration
- Code signing for distribution
- Building release versions
- Troubleshooting build issues
- Project architecture

### Development Workflow

**Project Structure:**
```
GigEVirtualCamera.xcodeproj    # Main Xcode project
├── GigECameraApp/             # Main application (SwiftUI)
├── GigEVirtualCameraExtension/# System extension (CMIO provider)
├── Shared/                    # Shared code and Aravis bridge
├── Scripts/                   # Build and distribution scripts
└── Resources/                 # Assets and licenses
```

**Key Files:**
- `Shared/AravisBridge/` - Objective-C++ wrapper for Aravis GigE library
- `Shared/CameraManager.swift` - Camera discovery and management
- `GigECameraApp/ContentView.swift` - Main UI
- `GigEVirtualCameraExtension/ExtensionProvider.swift` - Virtual camera implementation

**Development Tips:**

1. **Testing Without a GigE Camera:**
   - Use the built-in "Test Camera (Aravis Simulator)"
   - No physical hardware required for basic testing

2. **Debugging the Extension:**
   ```bash
   # View extension logs
   log stream --predicate 'subsystem == "com.lukechang.GigEVirtualCamera"'

   # Check extension status
   systemextensionsctl list
   ```

3. **Testing Virtual Camera:**
   - Use QuickTime Player for quick verification
   - Check `system_profiler SPCameraDataType` to see if camera is registered

### Running Tests

```bash
# Build debug version
xcodebuild -project GigEVirtualCamera.xcodeproj \
  -scheme GigEVirtualCamera \
  -configuration Debug \
  build

# Test in QuickTime
open -a "QuickTime Player"
# File → New Movie Recording → Select "GigE Virtual Camera"
```

### CI/CD

The project uses **GitHub Actions** for automated builds and releases:

**Automated Release Process:**
1. Push a version tag: `git tag v1.0.0 && git push origin v1.0.0`
2. GitHub Actions automatically:
   - Builds Release configuration
   - Signs with Developer ID
   - Notarizes with Apple
   - Creates DMG installer
   - Publishes GitHub Release

**Workflow Configuration:**
- **File**: `.github/workflows/build-and-release.yml`
- **Runner**: macOS 14 (Apple Silicon)
- **Secrets**: See [SECRETS_SETUP.md](SECRETS_SETUP.md)

**For Maintainers:**

To set up CI/CD secrets for your own fork:
1. Follow instructions in [SECRETS_SETUP.md](SECRETS_SETUP.md)
2. Configure GitHub repository secrets
3. Test with a version tag

### Contributing

We welcome contributions! Here's how to get started:

1. **Fork the repository**
2. **Create a feature branch**: `git checkout -b feature/amazing-feature`
3. **Make your changes** (follow Swift style guidelines)
4. **Test thoroughly** (including with real GigE cameras if possible)
5. **Submit a Pull Request**

**Read [CONTRIBUTING.md](CONTRIBUTING.md) for:**
- Coding standards
- Testing requirements
- Pull request guidelines
- Development best practices

**Good First Issues:**
- Look for issues tagged `good first issue`
- Documentation improvements
- Adding support for new pixel formats
- UI enhancements

### Architecture Overview

**System Extension Architecture:**

```
┌─────────────────────────────────────────────────────┐
│ GigE Camera (Network)                               │
└────────────┬────────────────────────────────────────┘
             │
             ▼
┌─────────────────────────────────────────────────────┐
│ Aravis Library (C++)                                │
│ ├─ Camera Discovery                                 │
│ ├─ Frame Acquisition                                │
│ └─ Protocol Handling                                │
└────────────┬────────────────────────────────────────┘
             │
             ▼
┌─────────────────────────────────────────────────────┐
│ AravisBridge (Objective-C++)                        │
│ └─ C++ to Swift Bridge                              │
└────────────┬────────────────────────────────────────┘
             │
             ▼
┌─────────────────────────────────────────────────────┐
│ Main App (GigECameraApp)                            │
│ ├─ SwiftUI Interface                                │
│ ├─ Camera Management                                │
│ ├─ Preview Display                                  │
│ └─ Frame Sender                                     │
└────────────┬────────────────────────────────────────┘
             │ (XPC / CMIO Sink)
             ▼
┌─────────────────────────────────────────────────────┐
│ System Extension (GigEVirtualCameraExtension)       │
│ ├─ CMIO Extension Provider                          │
│ ├─ Virtual Camera Device                            │
│ └─ Frame Stream Management                          │
└────────────┬────────────────────────────────────────┘
             │
             ▼
┌─────────────────────────────────────────────────────┐
│ macOS Camera System                                 │
│ └─ Available to all apps (Zoom, QuickTime, etc.)    │
└─────────────────────────────────────────────────────┘
```

**Key Technologies:**
- **CMIO (Core Media I/O)**: macOS camera extension framework
- **System Extensions**: Privileged extension architecture
- **Aravis**: GigE Vision camera library
- **SwiftUI**: Modern declarative UI framework
- **XPC**: Inter-process communication

### Resources for Developers

**Documentation:**
- [BUILDING.md](BUILDING.md) - Detailed build instructions
- [CONTRIBUTING.md](CONTRIBUTING.md) - Contribution guidelines
- [SECRETS_SETUP.md](SECRETS_SETUP.md) - CI/CD setup for maintainers
- [CLAUDE.md](CLAUDE.md) - Developer commands and tips

**Apple Documentation:**
- [Camera Extensions with Core Media I/O](https://developer.apple.com/documentation/coremediaio/creating_a_camera_extension_with_core_media_i_o)
- [System Extensions](https://developer.apple.com/documentation/systemextensions)
- [Hardened Runtime](https://developer.apple.com/documentation/security/hardened_runtime)

**External Libraries:**
- [Aravis Project](https://github.com/AravisProject/aravis) - GigE Vision implementation
- [GigE Vision Standard](https://www.visiononline.org/vision-standards-details.cfm?type=5) - Protocol specification

## Usage

### Using the App

1. **Launch GigEVirtualCamera**
   - Open from your Applications folder
   - The app window shows camera controls and preview

2. **Connect to a GigE Camera**

   **Option A: Automatic Discovery**
   - Your GigE Vision cameras on the network will appear in the dropdown menu
   - Select your camera from the list
   - Click **"Connect"** button
   - The app will establish connection and start streaming

   **Option B: Using Test Camera**
   - Select **"Test Camera (Aravis Simulator)"** from dropdown
   - This is useful for testing without a physical camera
   - Click **"Connect"** to start the simulated feed

3. **Start Streaming**
   - Once connected, the preview window shows the camera feed
   - The virtual camera is now active and available system-wide
   - You should see frame rate and status information

### Using Virtual Camera in Other Apps

The virtual camera appears as **"GigE Virtual Camera"** in all macOS applications:

**QuickTime Player:**
1. Open QuickTime Player
2. File → New Movie Recording
3. Click the dropdown arrow next to the record button
4. Select **"GigE Virtual Camera"**
5. Your GigE camera feed appears in QuickTime

**Zoom / Teams / Google Meet:**
1. Open your video conferencing app
2. Go to video settings
3. Select **"GigE Virtual Camera"** as your camera source
4. Your GigE camera feed is now your video source

**OBS Studio:**
1. Add a new Video Capture Device source
2. Select **"GigE Virtual Camera"** from device list
3. Your GigE camera feed appears in OBS

**Photo Booth / FaceTime:**
- Simply open the app
- Go to camera selection
- Choose **"GigE Virtual Camera"**

### Camera Controls

The app provides basic camera controls:
- **Connect/Disconnect**: Establish or close connection to camera
- **Start/Stop Streaming**: Begin or pause frame streaming
- **Frame Rate Display**: Shows current FPS
- **Status Indicator**: Shows connection and streaming status

### Network Requirements for GigE Cameras

For physical GigE Vision cameras:

1. **Network Setup**
   - Camera must be on the same network as your Mac
   - Use wired Ethernet connection for best performance
   - Configure camera IP (DHCP or static)

2. **Firewall Settings**
   - GigE Vision uses UDP port 3956
   - Ensure macOS firewall allows GigEVirtualCamera
   - System Settings → Network → Firewall → Options

3. **Test Camera Detection**
   ```bash
   # Install Aravis tools
   brew install aravis

   # List detected cameras
   arv-camera-test-0.8
   ```

### Tips for Best Performance

- **Use Gigabit Ethernet**: GigE cameras require high bandwidth
- **Direct Connection**: Connect camera directly to Mac when possible
- **Adjust Frame Rate**: Lower frame rates reduce network load
- **Check Network Load**: Use Activity Monitor to check network usage

## Troubleshooting

### System Extension Issues

```bash
# Check if extension is installed
systemextensionsctl list

# Reset system extensions (requires SIP disabled)
systemextensionsctl reset

# View logs
log stream --predicate 'subsystem == "com.apple.cmio"'
```

### Camera Not Detected

- Verify camera is powered and connected to network
- Check if camera appears in: `arv-camera-test-0.8`
- Ensure firewall allows UDP port 3956 (GigE Vision)
- Try using camera's IP address directly

### Virtual Camera Not Appearing

1. Check System Settings → Privacy & Security → Camera
2. Ensure GigEVirtualCamera has permission
3. Restart the app or your Mac
4. For developers: Verify SIP is disabled for testing

### Build Issues

- Clean build: `xcodebuild clean`
- Reset derived data: `rm -rf ~/Library/Developer/Xcode/DerivedData`
- Regenerate project: `xcodegen generate`

## License

MIT License - see LICENSE file for details

## Acknowledgments

- [Aravis](https://github.com/AravisProject/aravis) - GigE Vision library
- Apple's Camera Extension sample code