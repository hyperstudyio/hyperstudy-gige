## Version 1.1.22 - 2026-06-07

### Release Notes
Fixes the recurring stream freeze. Root cause (confirmed against the live MRC
MR-CAM-HR): the GVSP receive socket buffer was left at the macOS default
(~768 KB, smaller than one 921,600-byte frame), so under the app's per-frame
load the socket overflowed and dropped packets until the stream collapsed —
with no recovery. In a live 90 s test the fix took packet loss from 575 to 0.

### Changes
- Set an 8 MB fixed GVSP socket-buffer (was the OS default, too small for one frame)
- Run the GVSP receive thread at elevated priority so app processing can't starve packet draining
- Deepen the buffer pool 10 → 30 for more headroom during per-frame processing
- Fix AravisStream diagnostics stats to use arv_stream_get_statistics / arv_gv_stream_get_statistics (were reading zeros)
- Add docs/CAMERA_MR_CAM_HR_REFERENCE.md preserving the camera/stream configuration and experiments
- Fix a misleading "8228 jumbo" packet-size log (actual size is 1500)

---

## Version 1.0.5 - 2025-07-05

### Release Notes
Fixed entitlements for system extension installation

### Changes
- Fix entitlements in release distribution script
- Fix code signing - switch to automatic signing for both targets
- Fix extension code signing - remove provisioning profiles from Release config
- finally got video stream working!
- SurfaceIO no CMIOSink stream
- added simulated fake gige camera stream for testing
- Finally got camera extension to install
- updated documentation
- Fix CMIO extension implementation and add Developer ID signing/notarization
- Implement CMIO sink/source architecture and fix bundle identifier issue

---

