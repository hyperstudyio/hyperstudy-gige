# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

This is a native macOS application that creates a virtual camera from GigE Vision cameras. The app uses:
- Swift and SwiftUI for the main application
- macOS Camera Extension API for virtual camera functionality
- Aravis library (via Objective-C++ bridge) for GigE Vision camera support

## Common Development Commands

### Building the Application

```bash
# Build debug version
cd macos
xcodebuild -project GigEVirtualCamera.xcodeproj -scheme GigECameraApp -configuration Debug

# Build release version
xcodebuild -project GigEVirtualCamera.xcodeproj -scheme GigECameraApp -configuration Release

# Or use the convenience scripts:
./Scripts/build_debug.sh
./Scripts/build_release.sh
```

**IMPORTANT**: DO NOT run `xcodegen` as it breaks the manual provision profile settings. Use the existing project file and build directly.

### Installing and Testing

```bash
# Install the built app
./Scripts/install_app.sh

# Reinstall camera extension (if virtual camera not appearing)
./Scripts/reinstall_extension.sh

# Run the app from command line (for debugging)
open /Applications/GigEVirtualCamera.app
```

### Development in Xcode

```bash
# Open project in Xcode
open macos/GigEVirtualCamera.xcodeproj
```

## Architecture Overview

### Project Structure

```
macos/
├── GigECameraApp/          # Main application
│   ├── ContentView.swift   # Main UI
│   ├── AppDelegate.swift   # App lifecycle
│   └── Info.plist         # App configuration
├── GigECameraExtension/    # Camera Extension
│   ├── ExtensionProvider.swift  # Camera extension implementation
│   └── Info.plist         # Extension configuration
├── Shared/                 # Shared code
│   ├── AravisBridge/      # Objective-C++ Aravis wrapper
│   ├── CameraManager.swift # Camera discovery and management
│   └── CameraFrameSender.swift # Frame passing between app and extension
├── Scripts/               # Build and utility scripts
└── Resources/            # Assets and licenses
```

### Key Components

1. **AravisBridge** (`Shared/AravisBridge/`)
   - Objective-C++ wrapper around Aravis C library
   - Handles GigE Vision camera discovery and frame acquisition
   - Converts Aravis frames to CVPixelBuffer for macOS

2. **Camera Extension** (`GigECameraExtension/`)
   - Implements CMIOExtension protocol
   - Receives frames from main app via XPC
   - Provides virtual camera to macOS system

3. **Main Application** (`GigECameraApp/`)
   - SwiftUI interface for camera selection and preview
   - Manages camera connection and streaming
   - Sends frames to extension via XPC

### Key Design Patterns

- **XPC Communication**: Main app communicates with extension using XPC for frame data
- **Singleton Pattern**: CameraManager uses singleton for camera state
- **Bridge Pattern**: AravisBridge wraps C++ Aravis API for Swift consumption
- **Delegation**: Camera events handled via delegate pattern

### Common Tasks

#### Adding New Camera Features

1. Update AravisBridge to expose new Aravis functionality
2. Add Swift wrapper methods in CameraManager
3. Update UI in ContentView to expose controls

#### Debugging Camera Issues

```bash
# Check if Aravis can see cameras
brew install aravis
arv-camera-test-0.8

# Check system logs for extension issues
log stream --predicate 'subsystem == "com.hyperstudy.GigEVirtualCamera"'

# Debug extension loading
systemextensionsctl list
```

#### Modifying Frame Processing

Frame pipeline:
1. Aravis captures frame → `AravisBridge::getFrame()`
2. Convert to CVPixelBuffer → `AravisBridge` 
3. Send via XPC → `CameraFrameSender`
4. Receive in extension → `ExtensionProvider`
5. Provide to macOS → `CMIOExtension` stream

### Testing

```bash
# Test virtual camera appears in system
system_profiler SPCameraDataType | grep "GigE Virtual Camera"

# Test in QuickTime
open -a "QuickTime Player"
# File → New Movie Recording → Select "GigE Virtual Camera"
```

#### Using the Test Camera

When no real GigE camera is available:
1. Launch the app
2. Select "Test Camera (Aravis Simulator)" from the dropdown
3. Click Connect and Start Streaming
4. The app uses Aravis's built-in fake camera for testing

### Common Issues and Solutions

1. **Virtual camera not appearing**
   - Restart System Extension: `systemextensionsctl reset`
   - Check extension is approved in System Settings
   - Reinstall: `./Scripts/reinstall_extension.sh`

2. **Camera discovery fails**
   - Check network connectivity to camera
   - Verify firewall allows GigE Vision traffic
   - Test with `arv-camera-test-0.8`

3. **Build errors**
   - Ensure Aravis is installed: `brew install aravis`
   - Clean build folder: `rm -rf macos/build`
   - Reset package cache: `rm -rf ~/Library/Developer/Xcode/DerivedData`

### Code Style Guidelines

- Use Swift style guide conventions
- Keep Objective-C++ code minimal in AravisBridge
- Prefer Swift native types over Foundation when possible
- Use async/await for asynchronous operations
- Add documentation comments for public APIs

## Environment Configuration

### Environment Variables

This project uses environment variables for code signing and distribution configuration:

**Local Development (.env file)**:
```bash
# Create .env from template
cp .env.example .env

# Edit .env with your values
APPLE_TEAM_ID=YOUR_10_CHAR_TEAM_ID
CODE_SIGN_IDENTITY=Developer ID Application
NOTARIZATION_APPLE_ID=your@email.com
NOTARIZATION_PASSWORD=xxxx-xxxx-xxxx-xxxx
```

**Using environment variables in builds**:
```bash
# Source .env file
source .env

# Build with environment variables
export APPLE_TEAM_ID=YOUR_TEAM_ID
xcodebuild -project GigEVirtualCamera.xcodeproj \
  -scheme GigEVirtualCamera \
  -configuration Release \
  DEVELOPMENT_TEAM="$APPLE_TEAM_ID"
```

**Default values**: If environment variables are not set, the project uses defaults from the original configuration for backward compatibility.

### GitHub Actions CI/CD

The project includes automated builds and releases via GitHub Actions.

**Workflow file**: `.github/workflows/build-and-release.yml`

**Trigger**: Push a version tag to automatically build, sign, notarize, and release:
```bash
git tag v1.0.0
git push origin v1.0.0
```

**Required GitHub Secrets** (for maintainers):
- `MACOS_CERTIFICATE_BASE64` - Developer ID certificate (p12, base64 encoded)
- `MACOS_CERTIFICATE_PASSWORD` - Password for the certificate
- `MACOS_PROVISIONING_PROFILE_APP_BASE64` - App provisioning profile (base64)
- `MACOS_PROVISIONING_PROFILE_EXT_BASE64` - Extension provisioning profile (base64)
- `APPLE_TEAM_ID` - Apple Developer Team ID
- `NOTARIZATION_APPLE_ID` - Apple ID for notarization
- `NOTARIZATION_PASSWORD` - App-specific password

See [SECRETS_SETUP.md](SECRETS_SETUP.md) for detailed setup instructions.

**Build process**:
1. Install dependencies (Aravis via Homebrew)
2. Import code signing certificates from secrets
3. Build Release configuration
4. Sign app and extension
5. Notarize with Apple
6. Create DMG
7. Create GitHub Release with DMG attachment

**Debugging workflow failures**:
```bash
# View workflow runs
# GitHub → Actions tab

# Check logs for:
# - Certificate import errors
# - Build failures
# - Notarization issues
# - DMG creation problems
```

### Code Signing Notes

**For Local Development**:
- Use "Apple Development" certificates
- Xcode handles signing automatically for Debug builds
- No manual configuration needed for basic testing

**For Distribution**:
- Requires "Developer ID Application" certificate
- Requires provisioning profiles for app and extension
- Build scripts check for `APPLE_TEAM_ID` environment variable
- Notarization requires app-specific password (not Apple ID password!)

**Important**: Never commit certificates, provisioning profiles, or passwords to git. Use .env file (gitignored) or GitHub Secrets.

## Creating Releases

### Automated Release Process (Recommended)

The project uses GitHub Actions to automatically build, sign, notarize, and publish releases.

**Step 1: Prepare for Release**

```bash
# Ensure you're on main branch with latest changes
git checkout main
git pull origin main

# Verify build is working locally (optional)
xcodebuild -project GigEVirtualCamera.xcodeproj \
  -scheme GigEVirtualCamera \
  -configuration Release \
  clean build
```

**Step 2: Create and Push Version Tag**

```bash
# Create a version tag (semantic versioning: vMAJOR.MINOR.PATCH)
git tag v1.0.0

# Push the tag to GitHub
git push origin v1.0.0
```

**Step 3: Monitor the Build**

```bash
# Watch the GitHub Actions workflow
gh run list --limit 1

# Or view in browser
open https://github.com/hyperstudyio/hyperstudy-gige/actions
```

**Step 4: Verify the Release**

The workflow automatically:
1. ✅ Builds the Release configuration
2. ✅ Signs app and extension with Developer ID
3. ✅ Notarizes app with Apple (~10 minutes)
4. ✅ Creates DMG installer
5. ✅ Notarizes DMG with Apple (~5 minutes)
6. ✅ Creates GitHub Release with DMG attached
7. ✅ Generates release notes from commits

**View the release:**
```bash
# List releases
gh release list

# View specific release
gh release view v1.0.0

# Or in browser
open https://github.com/hyperstudyio/hyperstudy-gige/releases
```

**Total time:** ~15-20 minutes from tag push to published release

### Manual Release Process (Advanced)

If you need to build a release manually:

```bash
# 1. Set up environment variables
source .env  # Contains APPLE_TEAM_ID, CODE_SIGN_IDENTITY, etc.

# 2. Run the complete distribution script
./Scripts/build_and_distribute.sh

# This will:
# - Build Release configuration
# - Sign with Developer ID
# - Notarize with Apple
# - Create DMG
# - Notarize DMG

# 3. Find the DMG at:
ls -lh build/distribution/*.dmg

# 4. Manually create GitHub release
gh release create v1.0.0 \
  build/distribution/GigEVirtualCamera-v1.0.0.dmg \
  --title "GigE Virtual Camera v1.0.0" \
  --notes "Release notes here"
```

### Version Numbering

Follow [Semantic Versioning](https://semver.org/):

- **v1.0.0** - Major release (breaking changes, new architecture)
- **v1.1.0** - Minor release (new features, backward compatible)
- **v1.0.1** - Patch release (bug fixes, small improvements)

**Examples:**
- `v1.0.0` - First stable release
- `v1.0.1` - Bug fix for v1.0.0
- `v1.1.0` - Added new camera format support
- `v2.0.0` - Complete UI redesign (breaking change)

**Test releases:**
- Use `-test` suffix for testing: `v0.9.0-test`
- These can be deleted after verification
- Don't use for production releases

### Troubleshooting Releases

**Build fails during notarization:**
```bash
# Check notarization status
xcrun notarytool history \
  --apple-id "your@email.com" \
  --password "xxxx-xxxx-xxxx-xxxx" \
  --team-id "YOUR_TEAM_ID"

# View specific notarization log
xcrun notarytool log SUBMISSION_ID \
  --apple-id "your@email.com" \
  --password "xxxx-xxxx-xxxx-xxxx" \
  --team-id "YOUR_TEAM_ID"
```

**GitHub Actions fails:**
```bash
# View failed workflow logs
gh run view --log-failed

# Re-run workflow
gh run rerun <run-id>
```

**DMG not appearing in release:**
- Check GitHub Actions logs for upload errors
- Verify `permissions: contents: write` in workflow
- Ensure DMG was created: check "Create DMG" step logs

### Release Checklist

Before creating a production release:

- [ ] All tests passing locally
- [ ] Version number updated (if hardcoded anywhere)
- [ ] CHANGELOG.md updated with changes
- [ ] README.md reflects latest features
- [ ] No debug code or TODOs in critical paths
- [ ] Tested with both test camera and real GigE camera
- [ ] Verified virtual camera works in QuickTime/Zoom
- [ ] All GitHub secrets are configured correctly

**After release:**
- [ ] Download and test the DMG
- [ ] Verify installation on a clean Mac (if possible)
- [ ] Test system extension approval process
- [ ] Update documentation if needed
- [ ] Announce release (if applicable)