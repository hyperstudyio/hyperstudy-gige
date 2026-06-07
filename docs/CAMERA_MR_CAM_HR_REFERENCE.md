# MRC MR-CAM-HR — Camera & Stream Reference

Captured 2026-06-07 from the live camera connected directly to the development
Mac, using Aravis 0.8.36 CLI tools (`arv-tool-0.8`, `arv-camera-test-0.8`). This
is the GigE Vision MRI-room camera the app bridges to a macOS virtual camera.
Preserved here so the hardware's exact configuration survives across sessions
and informs the streaming-reliability work (see the freeze investigation below).

## 1. Device identity

| Field | Value |
|---|---|
| Vendor | MRC Systems GmbH |
| Model | GVRD-MRC MR-CAM-HR |
| Device version | 1.2.3-B10233 |
| Device ID | MR_CAM_HR_0020 |
| Aravis device id | `MRC Systems GmbH-GVRD-MRC MR-CAM-HR-MR_CAM_HR_0020` |
| GenICam scan type | Areascan (Linescan also offered) |

## 2. Network configuration

The camera connects **directly** to the Mac (no DHCP server), so both ends use
IPv4 **link-local (LLA / APIPA)** addressing.

| Field | Value |
|---|---|
| Camera IP (GevCurrentIPAddress) | 169.254.18.138 |
| Camera subnet (GevCurrentSubnetMask) | 255.255.0.0 (0xFFFF0000) |
| Camera persistent IP | 169.254.100.100 (not currently active) |
| IP config modes supported | LLA, DHCP, PersistentIP |
| IP config mode in use | **LLA (link-local)** |
| Host interface | **en11** |
| Host IP | 169.254.177.80 |
| Host link | 1000baseT, full-duplex, flow-control ON, status active |
| Host MTU | **1500** (jumbo NOT configured on the host) |
| Host MAC (en11) | 00:23:a4:0d:3d:2d |

> The macOS interface name has varied across sessions (the v1.1.21 freeze logs
> showed `en8`; on 2026-06-07 it enumerated as `en11`). Don't hard-code it.

## 3. Pixel format & geometry

| Field | Value |
|---|---|
| PixelFormat (current) | **BayerGR8** |
| PixelFormat options | Mono12, BayerGR8, Mono8 |
| Width × Height | 1280 × 720 (Width max 1280, Height max 960) |
| PayloadSize | **921600 bytes** (= 1280 × 720 × 1, matches BayerGR8 exactly) |
| Measured frame rate | ~60 fps |
| Measured throughput | ~55.3 MiB/s (~442 Mbit/s) |
| AcquisitionMode | Continuous (free-run; no trigger mode exposed) |
| ExposureTime | register present (read 2497–10000 µs); standard GenICam node reports "Not available" |
| Gain / ExposureAuto / GainAuto | **not exposed** by this camera |
| PixelMappingFormat (for Mono12) | HighBits, Shiftleft3Bits, MiddleBits, Shiftleft1Bit, LowBits, All12Bits |
| Per-channel gain | GainGreen / GainRed / GainBlue (RW), GlobalGain not available |

## 4. GigE Vision stream channel (GVSP/GVCP)

| Field | Value | Notes |
|---|---|---|
| Packet resend supported | **true** (GevSupportedOptionalCommandsPACKETRESEND) | |
| GevSCPSPacketSize (current) | **1500** | min 512, **max 9152**, inc 4 |
| Jumbo frames | camera supports up to 9152 B, **but host MTU 1500 blocks it** | would need en11 MTU 9000 |
| GevSCPSDoNotFragment | true | |
| GevSCPSBigEndian | false | |
| GevSCPD (packet delay) | 56 (timestamp ticks) | app sets ~750 ns via `arv_camera_gv_set_packet_delay` |
| **GevHeartbeatTimeout** | **3000 ms** | camera tears down the stream if GVCP heartbeat lapses >3 s — relevant to hypothesis H-B |
| GevTimestampTickFrequency | 75,000,000 (75 MHz) | |
| Stream channel count | 1 (selector 0..0) | |
| Optional commands | EVENT/EVENTDATA, PACKETRESEND, WRITEMEM, Concatenation | |
| Message channel | present (GevMC*) | |

## 5. macOS host networking limits (relevant to packet loss)

| sysctl | Value | Meaning |
|---|---|---|
| `net.inet.udp.recvspace` | 786,896 (~768 KB) | **default UDP socket buffer — smaller than ONE 921,600 B frame** |
| `kern.ipc.maxsockbuf` | 8,388,608 (8 MB) | ceiling for a tuned socket buffer (~9 frames of headroom) |
| `net.inet.udp.maxdgram` | 9,216 | |

The app currently sets **no** GVSP socket buffer, so it runs at the ~768 KB
default — too small to hold a single frame. This is the root cause of the
packet loss documented below.

## 6. Stream-reliability experiment (2026-06-07)

Two 90-second `arv-camera-test-0.8` runs against this camera, comparing the
app's current configuration against the proposed fix.

Command shape:
```bash
arv-camera-test-0.8 -n "MRC Systems GmbH-GVRD-MRC MR-CAM-HR-MR_CAM_HR_0020" \
  -i 1500 [-a --high-priority]
```

| Metric | Baseline (app-like: default buf, 1500 B) | Fix (`-a` auto buf + `--high-priority`) |
|---|---|---|
| n_completed_buffers | 5435 | 5435 |
| n_missing_packets | **575** | **0** |
| n_failures | 2 | 0 |
| n_timeouts (incomplete frames) | 2 | 0 |
| n_resend_requests | 126 | 0 |
| n_error_packets | 14 | 0 |
| n_received_packets | 3,447,036 | 3,445,869 |
| n_size_mismatch_errors | 5437 (≈ every frame) | 5435 (≈ every frame) |
| n_ignored_packets | 10,856 | 10,870 |

**Conclusion:** raising the GVSP socket buffer + elevating the receive-thread
priority eliminated packet loss entirely. The `size_mismatch` and
`ignored_packets` counters are constant in both runs (PayloadSize exactly
matches geometry), so they are benign per-frame/leader-trailer accounting, not
the freeze driver.

`arv-camera-test` only discards frames; the real app additionally debayers,
converts BGRA→YUV, enqueues to CMIO, and renders preview per frame, which
starves the receive thread far more — so the app's loss escalates until the
GVSP stream collapses (the freeze).

## 7. Freeze signature (from v1.1.21 instrumented capture, 2026-06-07)

- Frames flowed normally to #7529, then `arv_stream_timeout_pop_buffer`
  returned NULL every second for 68+ consecutive seconds (timeouts #1→#68),
  never recovering — a hard, permanent GVSP stall.
- Preceded by accelerating `ARV_BUFFER_STATUS_TIMEOUT` (status 2 = incomplete
  frame / missing packets) events; NOT preceded by any network change (the only
  "Network configuration changed" arrived 64 s AFTER the freeze).
- The loop never recovers because its only health check,
  `arv_camera_is_gv_device()`, is a *type predicate* (always true).
- Note: the v1.1.21 `AravisStream` stat logging reads all zeros because it used
  `g_object_get(_stream,"n-completed-buffers",…)`; the correct API is
  `arv_stream_get_statistics()` / `arv_gv_stream_get_statistics()`.

## 8. Validated fix direction (correctness, no watchdog)

1. Set a large fixed GVSP socket buffer in `AravisBridge` stream setup:
   `g_object_set(_stream, "socket-buffer", ARV_GV_STREAM_SOCKET_BUFFER_FIXED,
   "socket-buffer-size", 8*1024*1024, NULL);`
2. Elevate the receive thread: create the stream with a callback that calls
   `arv_make_thread_high_priority()` on `ARV_STREAM_CALLBACK_TYPE_INIT`.
3. Fix the stats instrumentation to use `arv_stream_get_statistics()` /
   `arv_gv_stream_get_statistics()` so future captures show real numbers.

Jumbo frames are an optional further lever but require raising the host NIC MTU
to 9000 first (camera supports up to 9152 B packets). Stream re-establishment on
confirmed silence (hypothesis H-B / heartbeat) is held in reserve pending
results from steps 1–3.

## 9. How to reproduce these probes

```bash
CAM="MRC Systems GmbH-GVRD-MRC MR-CAM-HR-MR_CAM_HR_0020"
arv-tool-0.8                                  # discover (prints IP)
arv-tool-0.8 -n "$CAM" features               # full GenICam feature tree
arv-tool-0.8 -n "$CAM" control Width Height PixelFormat PayloadSize GevSCPSPacketSize GevHeartbeatTimeout
# 90 s streaming test with stats (baseline vs fix):
arv-camera-test-0.8 -n "$CAM" -i 1500                    # baseline
arv-camera-test-0.8 -n "$CAM" -i 1500 -a --high-priority # fix candidate
sysctl kern.ipc.maxsockbuf net.inet.udp.recvspace        # host socket limits
```
