# MRC MR-CAM-HR — Camera & Stream Reference

Captured 2026-06-07 from the live camera connected directly to the development
Mac, using Aravis 0.8.36 CLI tools (`arv-tool-0.8`, `arv-camera-test-0.8`). This
is the GigE Vision MRI-room camera the app bridges to a macOS virtual camera.
Preserved here so the hardware's exact configuration survives across sessions
and informs the streaming-reliability work (see the freeze investigation below).

**Last updated 2026-06-08** — added the link-local reconnect behavior, the
shipped fixes + field results (§8), and the hardware root cause (§10).

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

> The macOS interface name has varied across sessions (`en8`, `en11`, `en13`
> seen on different days). Don't hard-code it.

**Link-local re-negotiation (important for recovery).** Because addressing is
APIPA, the camera re-negotiates its 169.254.x address whenever the link comes
back up, and the host's ARP / interface bindings flush. Consequence: after a
cable/link bounce, a **direct unicast** reconnect to the *old* IP
(`arv_camera_new("169.254.x.x")`) keeps failing, but a **GVCP discovery
broadcast** (`arv_update_device_list()`, i.e. the "refresh camera list" action)
finds the camera at its current address. Recovery must therefore reconnect by
**device ID after a discovery**, not by cached IP — see §8 (v1.1.24).

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

## 8. Resolution — shipped fixes & field results

Investigation separated **two distinct failure modes**, fixed across three
releases (all in `AravisBridge.mm`, correctness-first, no blind watchdog):

**Mode 1 — packet-loss collapse** (fixed in **v1.1.22**)
- Cause: the GVSP receive socket ran at the macOS default (~768 KB, smaller than
  one 921,600 B frame); under the app's per-frame load the receive thread is
  delayed, the socket overflows, packets drop, and the stream eventually wedges.
- Fix: 8 MB fixed socket buffer (`ARV_GV_STREAM_SOCKET_BUFFER_FIXED` /
  `socket-buffer-size`), elevated receive-thread priority (stream created with a
  callback that calls `arv_make_thread_realtime`/`arv_make_thread_high_priority`
  on `ARV_STREAM_CALLBACK_TYPE_INIT`), deeper buffer pool (10 → 30), and the
  stats-API fix (`arv_stream_get_statistics` / `arv_gv_stream_get_statistics`).
- **Field result (v1.1.23 run, 2026-06-08):** ~3 min / 11,698 frames clean,
  `completed` tracking `frames` exactly, `missing` flat (a one-time ~632-packet
  start-up blip, then zero growth). Confirmed fixed.

**Mode 2 — physical link drop** (re-establishment added in **v1.1.23**,
completed in **v1.1.24**)
- Cause: a link drop (e.g. cable moved/unplugged → interface `Link` change)
  silences the stream; Aravis never recovers on its own, and the old health
  check `arv_camera_is_gv_device()` is a type predicate (always true), so the
  loop spun forever.
- v1.1.23: detect ~3 s of total silence (consecutive 1 s pop-timeouts, reset on
  any buffer; threshold matches the 3 s `GevHeartbeatTimeout`) → tear down and
  rebuild camera+stream while keeping `state == Streaming` so the CMIO
  sink/preview pipeline stays intact and frames just resume. **Field-confirmed
  detecting + retrying** on a real drop, but it retried the stale IP and so did
  not reconnect on its own (see below).
- v1.1.24: each recovery attempt now runs `arv_update_device_list()` (discovery)
  and reconnects via `arv_camera_new(<deviceId>)` (current address), falling
  back to the cached IP — mirroring the manual "refresh camera list" that was
  proven to recover. This closes the link-local re-negotiation gap from §2.

**Not pursued:** jumbo frames (would require raising host NIC MTU to 9000;
camera supports up to 9152 B packets). Left at MTU 1500 since the socket-buffer
fix already drove loss to 0.

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

## 10. Hardware root cause & field troubleshooting (the converter chain)

The connection path is: **camera → fiber → converter box → USB/Thunderbolt →
Mac**. Field instability that looked like software (intermittent freezes,
"camera not detected," users reporting **"only 3/6 lights on the USB
converter"**) was traced to a **damaged Thunderbolt cable**. A marginal/damaged
cable browns out or intermittently drops the link, which presents to the app as
exactly the Mode-2 link drop in §8.

Diagnostic signatures and what they mean:
- **Only some converter LEDs lit (e.g. 3/6):** partial initialization → power /
  cable problem, not the camera. A *fully* dead device shows no lights; a
  good-power/no-link device shows power LEDs but dark link LEDs. Half-and-half =
  the USB/TB host handoff isn't delivering enough (cable or port).
- **"Camera not detected" / `arv-tool` finds nothing:** the converter's network
  interface is absent or has no carrier. Check at the OS level:
  ```bash
  networksetup -listallhardwareports        # is a USB/TB Ethernet adapter present?
  ifconfig <enX>                            # status: active? a 169.254.x inet?
  ```
  When working, the camera's interface shows `1000baseT`, `status: active`, and
  a `169.254.x` link-local address; `arv-tool-0.8` lists the camera.
- **Two different converter models failing the same way:** the converter model
  is *not* the cause — look at the shared host side (the Mac's USB-C/TB port and
  power, macOS version, the cable, or a shared dongle/hub).

Recommendations:
- **Replace damaged cables.** v1.1.22–v1.1.24 make the app *recover gracefully*
  from a flaky link, but a sound cable means it rarely has to.
- For bus-powered converters on USB-C Macs, prefer a **self-powered USB hub** —
  rules out USB power-budget shortfalls (the "3/6 lights" class of problem).
- The app's automatic recovery (§8) now reconnects on its own when the link
  returns; users should no longer need to restart the app or manually refresh
  the camera list after a transient cable/link glitch.
