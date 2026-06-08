## Version 1.1.24 - 2026-06-08

### Release Notes
Fixes automatic recovery so it actually reconnects after a link drop. Field
testing v1.1.23 showed recovery correctly detected the drop and retried, but
never reconnected on its own — yet a manual "refresh camera list" did. Cause:
the camera uses link-local (169.254.x) addressing, which it re-negotiates when
the link returns, so retrying the old IP directly kept failing. Recovery now
runs a discovery broadcast and reconnects by device ID (its current address) on
each attempt — exactly what the manual refresh does — so the stream re-establishes
on its own once the cable/link comes back.

### Changes
- Recovery re-discovers (arv_update_device_list) and reconnects by device ID each attempt, instead of retrying a stale link-local IP
- Falls back to the last-known IP if discovery-by-id doesn't resolve

---

## Version 1.1.23 - 2026-06-08

### Release Notes
Adds automatic GVSP stream re-establishment to handle physical link drops
(e.g. the fiberoptic cable being moved/unplugged). Field testing of v1.1.22
confirmed it eliminated the packet-loss freeze (live logs: `missing=0`,
`completed` climbing), but exposed a separate, real failure: when the camera's
interface link dropped, the stream went silent and never recovered. The app now
detects sustained silence (~3 s with no buffers) and rebuilds camera+stream in
place — the same recovery a manual camera switch performs — without tearing down
the virtual camera, so frames resume automatically when the link returns.

### Changes
- Auto re-establish the GVSP stream after ~3 s of silence (link-drop recovery), with backoff while the cable is out
- Keep CMIO sink/preview pipeline intact across recovery (state stays Streaming; frames just pause and resume)
- Extract shared openStreamLocked so startup and recovery use identical stream config
- Replace the useless arv_camera_is_gv_device "health check" (a type predicate, always true) with real silence detection

---

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

