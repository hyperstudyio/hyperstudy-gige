//
//  AravisBridge.mm
//  GigEVirtualCamera
//
//  Objective-C++ implementation bridging Aravis to Swift
//

#import "AravisBridge.h"
#import <dispatch/dispatch.h>
#import <IOSurface/IOSurface.h>
#import <os/log.h>
#import "GigEVirtualCamera-Swift.h"

extern "C" {
#include <arv.h>
}

// Structured logger for the GigE stream. AravisBridge historically logged via
// NSLog, which carries no subsystem and is therefore invisible to the in-app
// Diagnostics drawer / JSON export (that query filters OSLogStore by
// subsystem == "com.lukechang.GigEVirtualCamera"). Routing the frame-loop
// signals through os_log on the app's subsystem makes them show up in the
// exported diagnostics, so a GVSP stream wedge is observable post-hoc rather
// than only in a live `log stream` session. Category "AravisStream" so it can
// be filtered apart from the Swift components.
static os_log_t AravisStreamLog(void) {
    static os_log_t log;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        log = os_log_create("com.lukechang.GigEVirtualCamera", "AravisStream");
    });
    return log;
}

// GVSP receive-thread priority hook. Aravis invokes this on its own stream
// receive thread; on INIT we elevate that thread so the app's per-frame work
// (debayer → BGRA→YUV → CMIO enqueue → preview) cannot starve packet draining.
// A starved receive thread lets the kernel UDP socket buffer overflow and drops
// GVSP packets — the measured root cause of the stream freeze. Try realtime
// scheduling first; fall back to an elevated nice level if RT isn't permitted
// (e.g. without the entitlement). See docs/CAMERA_MR_CAM_HR_REFERENCE.md.
static void AravisStreamThreadInit(void *user_data, ArvStreamCallbackType type, ArvBuffer *buffer) {
    (void)user_data; (void)buffer;
    if (type == ARV_STREAM_CALLBACK_TYPE_INIT) {
        if (!arv_make_thread_realtime(20)) {
            arv_make_thread_high_priority(-10);
        }
    }
}

// Consecutive 1 s pop-timeouts with no buffer at all before we treat the GVSP
// stream as dead and re-establish it. ~3 s matches the camera's
// GevHeartbeatTimeout — long enough to ride out a brief hiccup, short enough to
// recover quickly after a physical link drop (e.g. the fiber being moved).
static const int kStreamSilenceRecoveryTimeouts = 3;

@implementation AravisCamera {
    NSString *_name;
    NSString *_modelName;
    NSString *_deviceId;
    NSString *_ipAddress;
}

- (instancetype)initWithDeviceId:(NSString *)deviceId 
                            name:(NSString *)name 
                       modelName:(NSString *)modelName 
                       ipAddress:(NSString *)ipAddress {
    self = [super init];
    if (self) {
        _deviceId = deviceId;
        _name = name;
        _modelName = modelName;
        _ipAddress = ipAddress;
    }
    return self;
}

@end

@interface AravisBridge () {
    ArvCamera *_camera;
    ArvStream *_stream;
    dispatch_queue_t _frameQueue;
    dispatch_source_t _frameTimer;
    NSString *_preferredPixelFormat;
    CGSize _currentResolution;
}
@end

@implementation AravisBridge

// Helper function to create IOSurface-backed pixel buffer
static CVPixelBufferRef CreateIOSurfaceBackedPixelBuffer(size_t width, size_t height, OSType pixelFormat) {
    // Create IOSurface properties
    NSDictionary *ioSurfaceProps = @{
        (__bridge NSString *)kIOSurfaceIsGlobal: @YES
    };
    
    // Create pixel buffer attributes with IOSurface backing
    NSDictionary *pixelBufferAttributes = @{
        (__bridge NSString *)kCVPixelBufferWidthKey: @(width),
        (__bridge NSString *)kCVPixelBufferHeightKey: @(height),
        (__bridge NSString *)kCVPixelBufferPixelFormatTypeKey: @(pixelFormat),
        (__bridge NSString *)kCVPixelBufferIOSurfacePropertiesKey: ioSurfaceProps
    };
    
    CVPixelBufferRef pixelBuffer = NULL;
    CVReturn result = CVPixelBufferCreate(kCFAllocatorDefault,
                                         width,
                                         height,
                                         pixelFormat,
                                         (__bridge CFDictionaryRef)pixelBufferAttributes,
                                         &pixelBuffer);
    
    if (result != kCVReturnSuccess) {
        NSLog(@"AravisBridge: Failed to create IOSurface-backed pixel buffer: %d", result);
        return NULL;
    }
    
    // Verify IOSurface backing
    IOSurfaceRef surface = CVPixelBufferGetIOSurface(pixelBuffer);
    if (!surface) {
        NSLog(@"AravisBridge: Warning: Pixel buffer does not have IOSurface backing!");
    }
    
    return pixelBuffer;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _state = AravisCameraStateDisconnected;
        _frameQueue = dispatch_queue_create("com.lukechang.gigecamera.framequeue", DISPATCH_QUEUE_SERIAL);
        _preferredPixelFormat = @"Auto";
        _currentResolution = CGSizeZero;
    }
    return self;
}

- (void)setDelegate:(id<AravisBridgeDelegate>)delegate {
    _delegate = delegate;
    NSLog(@"AravisBridge: Delegate set to %@", delegate ? NSStringFromClass([delegate class]) : @"nil");
}

- (void)dealloc {
    [self disconnect];
}

#pragma mark - Discovery

+ (NSArray<AravisCamera *> *)discoverCameras {
    return [self discoverCamerasWithTimeout:2000];
}

+ (NSArray<AravisCamera *> *)discoverCamerasWithTimeout:(int)timeoutMs {
    NSLog(@"AravisBridge: Starting camera discovery with timeout %dms...", timeoutMs);
    
    // Set environment variables for discovery
    char timeoutStr[32];
    snprintf(timeoutStr, sizeof(timeoutStr), "%d", timeoutMs);
    setenv("ARV_GV_DISCOVERY_TIMEOUT", timeoutStr, 1);
    
    // Allow broadcast acknowledgments
    setenv("ARV_GV_INTERFACE_FLAGS", "1", 1);
    
    arv_update_device_list();
    
    NSMutableArray<AravisCamera *> *cameras = [NSMutableArray array];
    guint n_devices = arv_get_n_devices();
    NSLog(@"AravisBridge: Found %u devices", n_devices);
    
    for (guint i = 0; i < n_devices; i++) {
        const char *device_id = arv_get_device_id(i);
        const char *physical_id = arv_get_device_physical_id(i);
        const char *model = arv_get_device_model(i);
        const char *vendor = arv_get_device_vendor(i);
        
        if (device_id) {
            NSString *name = [NSString stringWithFormat:@"%s %s", 
                            vendor ?: "Unknown", 
                            model ?: "Camera"];
            NSString *modelName = [NSString stringWithUTF8String:model ?: "Unknown"];
            NSString *deviceId = [NSString stringWithUTF8String:device_id];
            NSString *ipAddress = [NSString stringWithUTF8String:physical_id ?: ""];
            
            AravisCamera *camera = [[AravisCamera alloc] initWithDeviceId:deviceId
                                                                     name:name
                                                                modelName:modelName
                                                                ipAddress:ipAddress];
            [cameras addObject:camera];
            NSLog(@"AravisBridge: Added camera %@ at %@", name, ipAddress);
        }
    }
    
    NSLog(@"AravisBridge: Returning %lu cameras", (unsigned long)cameras.count);
    return cameras;
}

#pragma mark - Fake Camera Management

static ArvGvFakeCamera *_fakeCameraInstance = NULL;

+ (BOOL)startFakeCamera {
    if (_fakeCameraInstance != NULL) {
        NSLog(@"AravisBridge: Fake camera already running");
        return YES;
    }
    
    NSLog(@"AravisBridge: Starting Aravis fake camera...");
    
    // Create fake camera on loopback interface
    _fakeCameraInstance = arv_gv_fake_camera_new("127.0.0.1", "FakeCamera001");
    
    if (_fakeCameraInstance != NULL) {
        // The fake camera starts automatically when created
        NSLog(@"AravisBridge: ✅ Fake camera started successfully");
        
        // Give it a moment to initialize
        usleep(100000); // 100ms
        
        // Update device list to include the fake camera
        arv_update_device_list();
        return YES;
    } else {
        NSLog(@"AravisBridge: ❌ Failed to create fake camera");
        return NO;
    }
}

+ (void)stopFakeCamera {
    if (_fakeCameraInstance != NULL) {
        NSLog(@"AravisBridge: Stopping fake camera...");
        g_object_unref(_fakeCameraInstance);
        _fakeCameraInstance = NULL;
        
        // Update device list to remove the fake camera
        arv_update_device_list();
        NSLog(@"AravisBridge: Fake camera stopped");
    }
}

+ (BOOL)isFakeCameraRunning {
    return _fakeCameraInstance != NULL && arv_gv_fake_camera_is_running(_fakeCameraInstance);
}

#pragma mark - Connection

- (BOOL)connectToCamera:(AravisCamera *)camera {
    return [self connectToCameraAtAddress:camera.ipAddress];
}

- (BOOL)connectToCameraAtAddress:(NSString *)ipAddress {
    @synchronized(self) {
        if (_state != AravisCameraStateDisconnected) {
            [self disconnect];
        }
        
        [self setState:AravisCameraStateConnecting];
        
        NSLog(@"AravisBridge: Attempting to connect to camera at %@", ipAddress);
        
        // Set a timeout for camera connection
        // This prevents the UI from freezing on unresponsive cameras
        setenv("ARV_GV_STREAM_TIMEOUT", "3000", 1);  // 3 second timeout
        setenv("ARV_GV_PACKET_TIMEOUT", "40", 1);    // 40ms packet timeout
        
        GError *error = NULL;
        _camera = arv_camera_new([ipAddress UTF8String], &error);
        
        if (!_camera) {
            NSLog(@"AravisBridge: Failed to connect to camera at %@", ipAddress);
            [self handleError:error message:@"Failed to connect to camera"];
            if (error) g_error_free(error);
            [self setState:AravisCameraStateDisconnected];
            return NO;
        }
        
        NSLog(@"AravisBridge: Successfully created camera object for %@", ipAddress);
        
        // Get camera info
        const char *vendor = arv_camera_get_vendor_name(_camera, NULL);
        const char *model = arv_camera_get_model_name(_camera, NULL);
        const char *device_id = arv_camera_get_device_id(_camera, NULL);
        
        _currentCamera = [[AravisCamera alloc] initWithDeviceId:[NSString stringWithUTF8String:device_id ?: ""]
                                                           name:[NSString stringWithFormat:@"%s %s", vendor ?: "", model ?: ""]
                                                      modelName:[NSString stringWithUTF8String:model ?: ""]
                                                      ipAddress:ipAddress];
        
        // Configure GigE-specific settings for better streaming
        NSLog(@"AravisBridge: Configuring GigE settings for %@ %@", 
              [NSString stringWithUTF8String:vendor ?: "Unknown"], 
              [NSString stringWithUTF8String:model ?: "Camera"]);
        
        // Set packet size (MTU)
        // Try standard MTU first for compatibility
        guint packet_size = arv_camera_gv_get_packet_size(_camera, &error);
        NSLog(@"AravisBridge: Current packet size: %u", packet_size);
        
        if (error) {
            g_error_free(error);
            error = NULL;
        }
        
        // Use standard 1500 MTU for better compatibility
        arv_camera_gv_set_packet_size(_camera, 1500, &error);
        if (error) {
            NSLog(@"AravisBridge: Warning - could not set packet size: %s", error->message);
            g_error_free(error);
            error = NULL;
            arv_camera_gv_set_packet_size(_camera, 1400, &error); // Slightly less than 1500 to account for headers
            if (error) {
                NSLog(@"AravisBridge: Failed to set packet size: %s", error->message);
                g_error_free(error);
            } else {
                NSLog(@"AravisBridge: Set packet size to 1400");
            }
        } else {
            NSLog(@"AravisBridge: Set packet size to 1500");
        }
        
        // Set packet delay to prevent overwhelming the network
        // Use a more conservative delay
        arv_camera_gv_set_packet_delay(_camera, 750, NULL); // Match what the camera reports as current
        NSLog(@"AravisBridge: Set packet delay to 750 ns");
        
        // Ensure the camera is in the right pixel format
        error = NULL;
        const char *pixel_format = arv_camera_get_pixel_format_as_string(_camera, &error);
        if (!error && pixel_format) {
            NSLog(@"AravisBridge: Camera pixel format: %s", pixel_format);
        }
        if (error) {
            g_error_free(error);
        }
        
        [self setState:AravisCameraStateConnected];
        return YES;
    }
}

- (void)disconnect {
    NSLog(@"AravisBridge: disconnect called");
    
    // Stop streaming first (this sets shouldStopStreaming flag)
    [self stopStreaming];
    
    // Give frame processing time to exit cleanly
    dispatch_barrier_sync(_frameQueue, ^{
        // This block runs after all previously queued blocks have finished
        NSLog(@"AravisBridge: Frame queue drained");
    });
    
    @synchronized(self) {
        // Release the STREAM before the CAMERA, synchronously, here. stopStreaming
        // releases the stream on a deferred main-queue block that can run AFTER
        // this disconnect unrefs the camera (or not before a fast reconnect),
        // leaving the ArvStream holding the GigE device/control channel open
        // until the process exits — the "must quit the app to reconnect" leak.
        // NULL-guarded so the deferred block in stopStreaming becomes a no-op
        // (no double-free); that block is also @synchronized on self.
        if (_stream) {
            NSLog(@"AravisBridge: Releasing stream (disconnect)...");
            g_object_unref(_stream);
            _stream = NULL;
        }
        if (_camera) {
            NSLog(@"AravisBridge: Releasing camera...");
            g_object_unref(_camera);
            _camera = NULL;
        }

        _currentCamera = nil;
        [self setState:AravisCameraStateDisconnected];
    }
}

#pragma mark - Streaming

// Creates, configures, and starts the GVSP stream on the current _camera.
// Shared by startStreaming and the in-loop recovery path so both get the
// identical stream configuration (packet resend, timeouts, 8 MB socket buffer,
// elevated-priority receive thread, deep buffer pool). Does NOT touch state or
// notify the delegate — callers own lifecycle. Returns NO (and leaves _stream
// NULL) on failure.
- (BOOL)openStreamLocked {
    if (!_camera) return NO;
    GError *error = NULL;

    // Create stream with a thread-init callback so the GVSP receive thread runs
    // at elevated priority (see AravisStreamThreadInit) — keeps packet draining
    // ahead of the app's per-frame processing load.
    NSLog(@"AravisBridge: Creating stream...");
    _stream = arv_camera_create_stream(_camera, AravisStreamThreadInit, NULL, &error);
    if (!_stream) {
        NSLog(@"AravisBridge: Failed to create stream: %s", error ? error->message : "unknown");
        if (error) g_error_free(error);
        return NO;
    }

    arv_camera_set_acquisition_mode(_camera, ARV_ACQUISITION_MODE_CONTINUOUS, &error);
    if (error) {
        NSLog(@"AravisBridge: Error setting acquisition mode: %s", error->message);
        g_error_free(error);
        error = NULL;
    }

    guint payload = arv_camera_get_payload(_camera, &error);
    if (error) {
        NSLog(@"AravisBridge: Error getting payload size: %s", error->message);
        g_error_free(error);
        g_object_unref(_stream); _stream = NULL;
        return NO;
    }
    NSLog(@"AravisBridge: Payload size = %u bytes", payload);

    arv_stream_set_emit_signals(_stream, FALSE); // We're polling, not using signals

    if (ARV_IS_GV_STREAM(_stream)) {
        // Enable packet resend (critical for reliable GigE streaming)
        g_object_set(_stream, "packet-resend", TRUE, NULL);
        g_object_set(_stream, "packet-timeout", 40000, NULL);    // 40 ms
        g_object_set(_stream, "frame-retention", 200000, NULL);  // 200 ms

        // Size the GVSP receive socket buffer well above a single frame.
        // macOS defaults net.inet.udp.recvspace to ~768 KB — smaller than ONE
        // 921,600-byte frame — so any receive-thread delay overflows it and
        // drops packets. A large FIXED buffer (capped by kern.ipc.maxsockbuf,
        // 8 MB on target ≈ ~9 frames) took live packet loss from 575 to 0.
        // See docs/CAMERA_MR_CAM_HR_REFERENCE.md.
        g_object_set(_stream,
                     "socket-buffer", ARV_GV_STREAM_SOCKET_BUFFER_FIXED,
                     "socket-buffer-size", 8 * 1024 * 1024,
                     NULL);
        NSLog(@"AravisBridge: GigE stream configured (packet resend on, 8 MB socket buffer)");
    }

    // Deep buffer pool (30 ≈ 0.5 s at 60 fps) so the receive thread has spare
    // buffers to fill while the app still holds earlier ones in its
    // debayer/convert/CMIO path.
    NSLog(@"AravisBridge: Pushing %d buffers of size %u", 30, payload);
    for (int i = 0; i < 30; i++) {
        ArvBuffer *buffer = arv_buffer_new(payload, NULL);
        if (buffer) {
            if (_stream && !self.shouldStopStreaming) {
                arv_stream_push_buffer(_stream, buffer);
            }
        } else {
            NSLog(@"AravisBridge: Failed to allocate buffer %d", i);
        }
    }

    NSLog(@"AravisBridge: Starting acquisition");
    arv_camera_start_acquisition(_camera, &error);
    if (error) {
        NSLog(@"AravisBridge: Error starting acquisition: %s", error->message);
        g_error_free(error);
        g_object_unref(_stream); _stream = NULL;
        return NO;
    }

    return YES;
}

- (BOOL)startStreaming {
    NSLog(@"AravisBridge: startStreaming called, state=%ld", (long)_state);
    if (!_camera || _state != AravisCameraStateConnected) {
        NSLog(@"AravisBridge: Cannot start streaming - camera=%p, state=%ld", _camera, (long)_state);
        return NO;
    }

    // Reset stop flag
    self.shouldStopStreaming = NO;

    if (![self openStreamLocked]) {
        [self handleError:NULL message:@"Failed to start stream"];
        return NO;
    }

    [self setState:AravisCameraStateStreaming];
    NSLog(@"AravisBridge: State set to streaming");

    // Start frame processing
    dispatch_async(_frameQueue, ^{
        NSLog(@"AravisBridge: Frame processing thread started");
        [self processFrames];
        NSLog(@"AravisBridge: Frame processing thread ended");
    });

    return YES;
}

// Re-establish a dead GVSP stream in place, on the frame-processing thread.
// Triggered when the stream goes silent for kStreamSilenceRecoveryTimeouts
// (e.g. the fiber was moved/unplugged → camera-interface Link drop). Aravis
// does not recover this itself, so we do exactly what a manual camera switch
// does — fully tear down and rebuild camera + stream — except we keep
// state == Streaming so the CMIO sink/preview pipeline stays intact and frames
// simply resume. Retries with backoff until the camera is reachable again or
// the user stops streaming. Returns YES if the stream was rebuilt, NO if
// shutdown was requested mid-recovery. Must be called on _frameQueue (it never
// blocks on the queue barrier, so it can't deadlock with disconnect).
- (BOOL)attemptStreamRecovery {
    NSString *ip = nil;
    NSString *deviceId = nil;
    @synchronized(self) {
        ip = _currentCamera.ipAddress;
        deviceId = _currentCamera.deviceId;
    }
    if (ip.length == 0 && deviceId.length == 0) {
        os_log_error(AravisStreamLog(), "Recovery: no camera identity on record, cannot re-establish");
        return NO;
    }

    // Tear down the dead stream + camera. The link is gone, so don't try to
    // stop acquisition on an unreachable camera — it would just block.
    @synchronized(self) {
        if (_stream) { g_object_unref(_stream); _stream = NULL; }
        if (_camera) { g_object_unref(_camera); _camera = NULL; }
    }

    int attempt = 0;
    while (!self.shouldStopStreaming) {
        attempt++;

        // Re-discover before reconnecting. On a link-local (169.254.x) network
        // the camera re-negotiates its APIPA address when the link returns, and
        // ARP/interface bindings get flushed — so a direct unicast to the old
        // IP keeps failing. A GVCP discovery broadcast finds the camera at its
        // *current* address and refreshes Aravis' device list; reconnecting by
        // device ID then resolves to that address. This mirrors the manual
        // "refresh camera list" reconnect, which is proven to recover where a
        // stale-IP retry does not. Safe here because the stream is already down,
        // so the broadcast has no active stream to disturb.
        arv_update_device_list();
        if (self.shouldStopStreaming) return NO;

        GError *error = NULL;
        ArvCamera *cam = NULL;
        if (deviceId.length > 0) {
            cam = arv_camera_new(deviceId.UTF8String, &error);
        }
        if (!cam && ip.length > 0) {
            // Fall back to the last-known address if discovery-by-id didn't resolve.
            if (error) { g_error_free(error); error = NULL; }
            cam = arv_camera_new(ip.UTF8String, &error);
        }

        if (self.shouldStopStreaming) {
            if (cam) g_object_unref(cam);
            if (error) g_error_free(error);
            return NO;
        }

        if (cam) {
            @synchronized(self) { _camera = cam; }
            // Re-apply GVSP packet settings on the fresh camera object.
            arv_camera_gv_set_packet_size(_camera, 1500, NULL);
            arv_camera_gv_set_packet_delay(_camera, 750, NULL);

            if ([self openStreamLocked]) {
                os_log_error(AravisStreamLog(),
                             "GVSP stream re-established after %d attempt(s)", attempt);
                return YES;
            }

            // Stream open failed even though the camera answered — drop it and retry.
            @synchronized(self) {
                if (_stream) { g_object_unref(_stream); _stream = NULL; }
                if (_camera) { g_object_unref(_camera); _camera = NULL; }
            }
        }
        if (error) g_error_free(error);

        os_log_error(AravisStreamLog(),
                     "Recovery attempt %d failed (camera unreachable?) — retrying", attempt);

        // Back off ~2 s, staying responsive to a stop request.
        for (int i = 0; i < 20 && !self.shouldStopStreaming; i++) {
            usleep(100000); // 100 ms × 20 = 2 s
        }
    }
    return NO;
}

- (void)stopStreaming {
    NSLog(@"AravisBridge: stopStreaming called");
    
    // Signal frame processing to stop
    self.shouldStopStreaming = YES;
    
    // Stop camera acquisition first
    if (_state == AravisCameraStateStreaming && _camera) {
        NSLog(@"AravisBridge: Stopping camera acquisition...");
        arv_camera_stop_acquisition(_camera, NULL);
    }
    
    // Wait for frame processing to finish, then free the stream. Guard the
    // stream release under @synchronized + NULL-check so it can't race or
    // double-free with disconnect's synchronous release of the same stream.
    dispatch_async(_frameQueue, ^{
        dispatch_async(dispatch_get_main_queue(), ^{
            @synchronized(self) {
                if (self->_stream) {
                    NSLog(@"AravisBridge: Releasing stream...");
                    g_object_unref(self->_stream);
                    self->_stream = NULL;
                }

                if (self->_state == AravisCameraStateStreaming) {
                    [self setState:AravisCameraStateConnected];
                }
            }
        });
    });
}

#pragma mark - Frame Processing

- (void)processFrames {
    int frameCount = 0;
    int timeoutCount = 0;
    int consecutiveTimeouts = 0;  // reset whenever any buffer arrives; drives recovery
    NSLog(@"AravisBridge: processFrames started");
    
    // Get stream statistics before starting. These counters come from the
    // dedicated statistics API, NOT GObject properties — g_object_get with
    // "n-completed-buffers" etc. silently returns zeros (the v1.1.21 bug that
    // made every diagnostics stat read 0).
    if (ARV_IS_GV_STREAM(_stream)) {
        guint64 n_completed_buffers = 0;
        guint64 n_failures = 0;
        guint64 n_underruns = 0;

        arv_stream_get_statistics(_stream, &n_completed_buffers, &n_failures, &n_underruns);

        NSLog(@"AravisBridge: Initial stream stats - completed: %llu, failures: %llu, underruns: %llu",
              n_completed_buffers, n_failures, n_underruns);
    }
    
    while (_state == AravisCameraStateStreaming && _stream && !self.shouldStopStreaming) {
        // Check if we should stop before attempting to get buffer
        if (self.shouldStopStreaming || !_stream) {
            NSLog(@"AravisBridge: Stop requested or stream is null, exiting processFrames");
            break;
        }
        
        ArvBuffer *buffer = arv_stream_timeout_pop_buffer(_stream, 1000000); // 1 second timeout

        if (buffer) {
            // Any buffer (even an incomplete/error one) means the stream is
            // alive — clear the silence counter that drives recovery.
            consecutiveTimeouts = 0;
            ArvBufferStatus status = arv_buffer_get_status(buffer);
            if (status == ARV_BUFFER_STATUS_SUCCESS) {
                frameCount++;
                // Per-frame and once-per-second NSLogs removed. The
                // CMIOSinkConnector logs frame counts once per second at
                // info level; duplicating it here just floods the unified
                // log and makes the Diagnostics drawer noisy. Errors and
                // state transitions below still log normally.
                //
                // Low-rate stream-stats heartbeat (~every 2.5s at 59 fps) so
                // the diagnostics export shows the GVSP packet-loss trend
                // (missing / resent climbing) BEFORE a wedge, and the exact
                // frame count at which `n-completed-buffers` stops advancing.
                if (frameCount % 150 == 0 && ARV_IS_GV_STREAM(_stream)) {
                    guint64 completed = 0, failures = 0, underruns = 0, resent = 0, missing = 0;
                    arv_stream_get_statistics(_stream, &completed, &failures, &underruns);
                    arv_gv_stream_get_statistics(ARV_GV_STREAM(_stream), &resent, &missing);
                    os_log_info(AravisStreamLog(),
                                "Stream healthy — frames=%d completed=%llu failures=%llu underruns=%llu resent=%llu missing=%llu",
                                frameCount, completed, failures, underruns, resent, missing);
                }
                [self processBuffer:buffer];
            } else {
                NSLog(@"AravisBridge: Buffer status error: %d", status);
                os_log_error(AravisStreamLog(),
                             "Buffer status error: %d (frames so far=%d)", status, frameCount);
                // Log more details about the error
                switch (status) {
                    case ARV_BUFFER_STATUS_UNKNOWN:
                        NSLog(@"AravisBridge: Buffer error details: Unknown status");
                        break;
                    case ARV_BUFFER_STATUS_TIMEOUT:
                        NSLog(@"AravisBridge: Buffer error details: Timeout");
                        break;
                    case ARV_BUFFER_STATUS_MISSING_PACKETS:
                        NSLog(@"AravisBridge: Buffer error details: Missing packets");
                        break;
                    case ARV_BUFFER_STATUS_WRONG_PACKET_ID:
                        NSLog(@"AravisBridge: Buffer error details: Wrong packet ID");
                        break;
                    case ARV_BUFFER_STATUS_SIZE_MISMATCH:
                        NSLog(@"AravisBridge: Buffer error details: Size mismatch");
                        break;
                    case ARV_BUFFER_STATUS_FILLING:
                        NSLog(@"AravisBridge: Buffer error details: Filling");
                        break;
                    case ARV_BUFFER_STATUS_ABORTED:
                        NSLog(@"AravisBridge: Buffer error details: Aborted");
                        break;
                    default:
                        NSLog(@"AravisBridge: Buffer error details: Other error (%d)", status);
                        break;
                }
            }
            // Only push buffer if stream is still valid
            if (_stream && !self.shouldStopStreaming) {
                arv_stream_push_buffer(_stream, buffer);
            }
        } else {
            timeoutCount++;
            consecutiveTimeouts++;
            NSLog(@"AravisBridge: Timeout waiting for frame (timeout #%d)", timeoutCount);
            
            // Check stream statistics
            if (ARV_IS_GV_STREAM(_stream)) {
                guint64 n_completed_buffers = 0;
                guint64 n_failures = 0;
                guint64 n_underruns = 0;
                guint64 n_resent_packets = 0;
                guint64 n_missing_packets = 0;

                arv_stream_get_statistics(_stream, &n_completed_buffers, &n_failures, &n_underruns);
                arv_gv_stream_get_statistics(ARV_GV_STREAM(_stream), &n_resent_packets, &n_missing_packets);
                
                NSLog(@"AravisBridge: Stream stats - completed: %llu, failures: %llu, underruns: %llu, resent: %llu, missing: %llu",
                      n_completed_buffers, n_failures, n_underruns, n_resent_packets, n_missing_packets);

                // The decisive freeze signal. During a stall this fires ~once
                // per second (the loop is parked on the 1s pop timeout). If
                // `completed` is flat while `missing`/`resent` climb, the GVSP
                // stream wedged on packet loss; if all counters are flat, the
                // camera stopped sending entirely (link/socket orphaned). Logged
                // at error level so it surfaces in the diagnostics export.
                os_log_error(AravisStreamLog(),
                             "Frame timeout #%d — completed=%llu failures=%llu underruns=%llu resent=%llu missing=%llu",
                             timeoutCount, n_completed_buffers, n_failures, n_underruns,
                             n_resent_packets, n_missing_packets);
            }

            // Sustained silence = the GVSP stream is dead — typically the fiber
            // was moved/unplugged (camera-interface Link drop), which Aravis does
            // not recover on its own. (The old `arv_camera_is_gv_device` check
            // here was useless: it's a type predicate, always true.) Re-establish
            // the stream ourselves — the same teardown+reconnect a manual camera
            // switch performs, which is proven to recover — while keeping
            // state == Streaming so the CMIO sink/preview pipeline stays intact
            // and frames simply resume.
            if (consecutiveTimeouts >= kStreamSilenceRecoveryTimeouts) {
                os_log_error(AravisStreamLog(),
                             "Stream silent for %ds — re-establishing GVSP stream (link drop?)",
                             consecutiveTimeouts);
                if ([self attemptStreamRecovery]) {
                    consecutiveTimeouts = 0;
                    continue;  // resume the loop on the freshly rebuilt stream
                }
                // Recovery returns NO only when shutdown was requested.
                break;
            }
        }
    }

    NSLog(@"AravisBridge: processFrames ended - received %d frames, %d timeouts", frameCount, timeoutCount);
    // Surface loop exit in the diagnostics export so we can tell a clean stop
    // (shouldStopStreaming=YES from user disconnect) apart from the loop never
    // exiting at all (the freeze: stuck spinning on pop timeouts forever).
    os_log_error(AravisStreamLog(),
                 "processFrames ENDED — frames=%d timeouts=%d state=%d shouldStop=%d streamNull=%d",
                 frameCount, timeoutCount, (int)_state, (int)self.shouldStopStreaming, (int)(_stream == NULL));
}

- (void)processBuffer:(ArvBuffer *)buffer {
    gint width, height;
    const void *data = arv_buffer_get_data(buffer, NULL);
    arv_buffer_get_image_region(buffer, NULL, NULL, &width, &height);
    // Capture-time identity, read before any conversion work so timing never
    // inherits downstream queue jitter. CLOCK_UPTIME_RAW shares the mach
    // timebase used by CMClockGetHostTimeClock, so it is a valid host-domain PTS.
    uint64_t frameID = arv_buffer_get_frame_id(buffer);
    uint64_t cameraTimestampNs = arv_buffer_get_timestamp(buffer);
    uint64_t hostTimestampNs = clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
    ArvPixelFormat pixel_format = arv_buffer_get_image_pixel_format(buffer);
    
    // Update current resolution
    _currentResolution = CGSizeMake(width, height);
    
    // Override pixel format if user has selected a specific one
    if (![_preferredPixelFormat isEqualToString:@"Auto"]) {
        ArvPixelFormat overrideFormat = pixel_format;
        
        if ([_preferredPixelFormat isEqualToString:@"Bayer GR8"]) {
            overrideFormat = 0x01080008; // ARV_PIXEL_FORMAT_BAYER_GR_8
        } else if ([_preferredPixelFormat isEqualToString:@"Bayer RG8"]) {
            overrideFormat = 0x01080009; // ARV_PIXEL_FORMAT_BAYER_RG_8
        } else if ([_preferredPixelFormat isEqualToString:@"Bayer GB8"]) {
            overrideFormat = 0x0108000A; // ARV_PIXEL_FORMAT_BAYER_GB_8
        } else if ([_preferredPixelFormat isEqualToString:@"Bayer BG8"]) {
            overrideFormat = 0x0108000B; // ARV_PIXEL_FORMAT_BAYER_BG_8
        } else if ([_preferredPixelFormat isEqualToString:@"Mono8"]) {
            overrideFormat = 0x01080001; // ARV_PIXEL_FORMAT_MONO_8
        } else if ([_preferredPixelFormat isEqualToString:@"RGB8"]) {
            overrideFormat = 0x02180014; // ARV_PIXEL_FORMAT_RGB_8_PACKED
        }
        
        if (overrideFormat != pixel_format) {
            NSLog(@"AravisBridge: Overriding pixel format from 0x%x to 0x%x (%@)", 
                  pixel_format, overrideFormat, _preferredPixelFormat);
            pixel_format = overrideFormat;
        }
    }
    
    // Convert to CVPixelBuffer based on format
    CVPixelBufferRef pixelBuffer = NULL;
    
    switch (pixel_format) {
        case ARV_PIXEL_FORMAT_MONO_8:
            [self createPixelBufferFromMono8:data width:width height:height pixelBuffer:&pixelBuffer];
            break;
            
        case ARV_PIXEL_FORMAT_BAYER_GR_8:
            NSLog(@"AravisBridge: Processing Bayer GR8 format image %dx%d", width, height);
            [self createPixelBufferFromBayer:data width:width height:height pixelFormat:pixel_format pixelBuffer:&pixelBuffer];
            break;
        case ARV_PIXEL_FORMAT_BAYER_RG_8:
            NSLog(@"AravisBridge: Processing Bayer RG8 format image %dx%d", width, height);
            [self createPixelBufferFromBayer:data width:width height:height pixelFormat:pixel_format pixelBuffer:&pixelBuffer];
            break;
        case ARV_PIXEL_FORMAT_BAYER_GB_8:
            NSLog(@"AravisBridge: Processing Bayer GB8 format image %dx%d", width, height);
            [self createPixelBufferFromBayer:data width:width height:height pixelFormat:pixel_format pixelBuffer:&pixelBuffer];
            break;
        case ARV_PIXEL_FORMAT_BAYER_BG_8:
            NSLog(@"AravisBridge: Processing Bayer BG8 format image %dx%d", width, height);
            [self createPixelBufferFromBayer:data width:width height:height pixelFormat:pixel_format pixelBuffer:&pixelBuffer];
            break;
            
        case ARV_PIXEL_FORMAT_RGB_8_PACKED:
            [self createPixelBufferFromRGB:data width:width height:height pixelBuffer:&pixelBuffer];
            break;
            
        case ARV_PIXEL_FORMAT_BGR_8_PACKED:
            [self createPixelBufferFromBGR:data width:width height:height pixelBuffer:&pixelBuffer];
            break;
            
        default:
            NSLog(@"Unsupported pixel format: 0x%x (%s)", pixel_format, arv_pixel_format_to_gst_caps_string(pixel_format));
            return;
    }
    
    if (pixelBuffer && self.delegate) {
        static int delegateCallCount = 0;
        delegateCallCount++;

        // Only log the no-IOSurface case (which would indicate a fast path
        // regression). The successful-delivery message was firing once per
        // second and duplicating CMIOSinkConnector's downstream sink-send
        // log, so it just added noise to the unified log.
        IOSurfaceRef surface = CVPixelBufferGetIOSurface(pixelBuffer);
        if (!surface && delegateCallCount % 30 == 1) {
            NSLog(@"AravisBridge: WARNING - Frame #%d has no IOSurface!", delegateCallCount);
        }

        // Deliver synchronously on the frame queue. The delegate fan-out is a
        // cheap, non-blocking enqueue (see GigECameraManager), so the acquisition
        // loop is not stalled and the Aravis buffer is recycled promptly below.
        [self.delegate aravisBridge:self
                    didReceiveFrame:pixelBuffer
                            frameID:frameID
                  cameraTimestampNs:cameraTimestampNs
                    hostTimestampNs:hostTimestampNs];
        CVPixelBufferRelease(pixelBuffer);
    } else {
        if (pixelBuffer) {
            NSLog(@"AravisBridge: Have pixelBuffer but no delegate!");
            CVPixelBufferRelease(pixelBuffer);
        } else {
            NSLog(@"AravisBridge: Failed to create pixelBuffer");
        }
    }
}

- (void)createPixelBufferFromMono8:(const void *)data 
                            width:(size_t)width 
                           height:(size_t)height 
                      pixelBuffer:(CVPixelBufferRef *)pixelBuffer {
    // Convert Mono8 to BGRA for display with IOSurface backing
    *pixelBuffer = CreateIOSurfaceBackedPixelBuffer(width, height, kCVPixelFormatType_32BGRA);
    if (!*pixelBuffer) {
        NSLog(@"AravisBridge: Failed to create pixel buffer for Mono8");
        return;
    }
    
    CVPixelBufferLockBaseAddress(*pixelBuffer, 0);
    void *baseAddress = CVPixelBufferGetBaseAddress(*pixelBuffer);
    size_t bytesPerRow = CVPixelBufferGetBytesPerRow(*pixelBuffer);
    
    const uint8_t *srcData = (const uint8_t *)data;
    uint8_t *dstData = (uint8_t *)baseAddress;
    
    for (size_t y = 0; y < height; y++) {
        for (size_t x = 0; x < width; x++) {
            uint8_t gray = srcData[y * width + x];
            size_t dstIdx = y * bytesPerRow + x * 4;
            dstData[dstIdx + 0] = gray; // B
            dstData[dstIdx + 1] = gray; // G
            dstData[dstIdx + 2] = gray; // R
            dstData[dstIdx + 3] = 255;  // A
        }
    }
    
    CVPixelBufferUnlockBaseAddress(*pixelBuffer, 0);
}

- (void)createPixelBufferFromBayer:(const void *)data 
                             width:(size_t)width 
                            height:(size_t)height
                       pixelFormat:(ArvPixelFormat)bayerFormat
                       pixelBuffer:(CVPixelBufferRef *)pixelBuffer {
    // Create BGRA buffer with IOSurface backing
    *pixelBuffer = CreateIOSurfaceBackedPixelBuffer(width, height, kCVPixelFormatType_32BGRA);
    if (!*pixelBuffer) {
        NSLog(@"AravisBridge: Failed to create pixel buffer for Bayer");
        return;
    }
    
    CVPixelBufferLockBaseAddress(*pixelBuffer, 0);
    void *baseAddress = CVPixelBufferGetBaseAddress(*pixelBuffer);
    size_t bytesPerRow = CVPixelBufferGetBytesPerRow(*pixelBuffer);
    
    const uint8_t *srcData = (const uint8_t *)data;
    uint8_t *dstData = (uint8_t *)baseAddress;
    
    // Simple bilinear interpolation for Bayer pattern
    // This is a basic implementation - for production use consider using
    // more sophisticated algorithms or hardware debayering if available
    for (size_t y = 0; y < height; y++) {
        for (size_t x = 0; x < width; x++) {
            size_t srcIdx = y * width + x;
            size_t dstIdx = y * bytesPerRow + x * 4;
            
            uint8_t r = 0, g = 0, b = 0;
            
            // Determine the color of the current pixel based on Bayer pattern
            // and interpolate missing colors from neighbors
            BOOL isEvenRow = (y % 2 == 0);
            BOOL isEvenCol = (x % 2 == 0);
            
            if (bayerFormat == ARV_PIXEL_FORMAT_BAYER_RG_8) {
                if (isEvenRow && isEvenCol) {
                    // Red pixel
                    r = srcData[srcIdx];
                    g = [self averageNeighbors:srcData x:x y:y width:width height:height horizontal:YES vertical:YES];
                    b = [self averageNeighbors:srcData x:x y:y width:width height:height horizontal:NO vertical:NO];
                } else if (isEvenRow && !isEvenCol) {
                    // Green pixel (red row)
                    r = [self averageNeighbors:srcData x:x y:y width:width height:height horizontal:YES vertical:NO];
                    g = srcData[srcIdx];
                    b = [self averageNeighbors:srcData x:x y:y width:width height:height horizontal:NO vertical:YES];
                } else if (!isEvenRow && isEvenCol) {
                    // Green pixel (blue row)
                    r = [self averageNeighbors:srcData x:x y:y width:width height:height horizontal:NO vertical:YES];
                    g = srcData[srcIdx];
                    b = [self averageNeighbors:srcData x:x y:y width:width height:height horizontal:YES vertical:NO];
                } else {
                    // Blue pixel
                    r = [self averageNeighbors:srcData x:x y:y width:width height:height horizontal:NO vertical:NO];
                    g = [self averageNeighbors:srcData x:x y:y width:width height:height horizontal:YES vertical:YES];
                    b = srcData[srcIdx];
                }
            }
            else if (bayerFormat == ARV_PIXEL_FORMAT_BAYER_GR_8) {
                // GR pattern - Green is top-left
                if (isEvenRow && isEvenCol) {
                    // Green pixel (red row)
                    r = [self averageNeighbors:srcData x:x y:y width:width height:height horizontal:YES vertical:NO];
                    g = srcData[srcIdx];
                    b = [self averageNeighbors:srcData x:x y:y width:width height:height horizontal:NO vertical:YES];
                } else if (isEvenRow && !isEvenCol) {
                    // Red pixel
                    r = srcData[srcIdx];
                    g = [self averageNeighbors:srcData x:x y:y width:width height:height horizontal:YES vertical:YES];
                    b = [self averageNeighbors:srcData x:x y:y width:width height:height horizontal:NO vertical:NO];
                } else if (!isEvenRow && isEvenCol) {
                    // Blue pixel
                    r = [self averageNeighbors:srcData x:x y:y width:width height:height horizontal:NO vertical:NO];
                    g = [self averageNeighbors:srcData x:x y:y width:width height:height horizontal:YES vertical:YES];
                    b = srcData[srcIdx];
                } else {
                    // Green pixel (blue row)
                    r = [self averageNeighbors:srcData x:x y:y width:width height:height horizontal:NO vertical:YES];
                    g = srcData[srcIdx];
                    b = [self averageNeighbors:srcData x:x y:y width:width height:height horizontal:YES vertical:NO];
                }
            }
            else if (bayerFormat == ARV_PIXEL_FORMAT_BAYER_GB_8) {
                // GB pattern - Green is top-left, Blue is top-right
                if (isEvenRow && isEvenCol) {
                    // Green pixel (blue row)
                    r = [self averageNeighbors:srcData x:x y:y width:width height:height horizontal:NO vertical:YES];
                    g = srcData[srcIdx];
                    b = [self averageNeighbors:srcData x:x y:y width:width height:height horizontal:YES vertical:NO];
                } else if (isEvenRow && !isEvenCol) {
                    // Blue pixel
                    r = [self averageNeighbors:srcData x:x y:y width:width height:height horizontal:NO vertical:NO];
                    g = [self averageNeighbors:srcData x:x y:y width:width height:height horizontal:YES vertical:YES];
                    b = srcData[srcIdx];
                } else if (!isEvenRow && isEvenCol) {
                    // Red pixel
                    r = srcData[srcIdx];
                    g = [self averageNeighbors:srcData x:x y:y width:width height:height horizontal:YES vertical:YES];
                    b = [self averageNeighbors:srcData x:x y:y width:width height:height horizontal:NO vertical:NO];
                } else {
                    // Green pixel (red row)
                    r = [self averageNeighbors:srcData x:x y:y width:width height:height horizontal:YES vertical:NO];
                    g = srcData[srcIdx];
                    b = [self averageNeighbors:srcData x:x y:y width:width height:height horizontal:NO vertical:YES];
                }
            }
            else if (bayerFormat == ARV_PIXEL_FORMAT_BAYER_BG_8) {
                // BG pattern - Blue is top-left
                if (isEvenRow && isEvenCol) {
                    // Blue pixel
                    r = [self averageNeighbors:srcData x:x y:y width:width height:height horizontal:NO vertical:NO];
                    g = [self averageNeighbors:srcData x:x y:y width:width height:height horizontal:YES vertical:YES];
                    b = srcData[srcIdx];
                } else if (isEvenRow && !isEvenCol) {
                    // Green pixel (blue row)
                    r = [self averageNeighbors:srcData x:x y:y width:width height:height horizontal:NO vertical:YES];
                    g = srcData[srcIdx];
                    b = [self averageNeighbors:srcData x:x y:y width:width height:height horizontal:YES vertical:NO];
                } else if (!isEvenRow && isEvenCol) {
                    // Green pixel (red row)
                    r = [self averageNeighbors:srcData x:x y:y width:width height:height horizontal:YES vertical:NO];
                    g = srcData[srcIdx];
                    b = [self averageNeighbors:srcData x:x y:y width:width height:height horizontal:NO vertical:YES];
                } else {
                    // Red pixel
                    r = srcData[srcIdx];
                    g = [self averageNeighbors:srcData x:x y:y width:width height:height horizontal:YES vertical:YES];
                    b = [self averageNeighbors:srcData x:x y:y width:width height:height horizontal:NO vertical:NO];
                }
            }
            else {
                // Fallback to grayscale for unsupported patterns
                NSLog(@"AravisBridge: Unsupported Bayer pattern 0x%x, using grayscale", bayerFormat);
                r = g = b = srcData[srcIdx];
            }
            
            dstData[dstIdx + 0] = b;     // B
            dstData[dstIdx + 1] = g;     // G
            dstData[dstIdx + 2] = r;     // R
            dstData[dstIdx + 3] = 255;   // A
        }
    }
    
    CVPixelBufferUnlockBaseAddress(*pixelBuffer, 0);
}

- (uint8_t)averageNeighbors:(const uint8_t *)data 
                          x:(size_t)x 
                          y:(size_t)y 
                      width:(size_t)width 
                     height:(size_t)height
                 horizontal:(BOOL)horizontal
                   vertical:(BOOL)vertical {
    int sum = 0;
    int count = 0;
    
    if (horizontal) {
        if (x > 0) {
            sum += data[y * width + (x - 1)];
            count++;
        }
        if (x < width - 1) {
            sum += data[y * width + (x + 1)];
            count++;
        }
    }
    
    if (vertical) {
        if (y > 0) {
            sum += data[(y - 1) * width + x];
            count++;
        }
        if (y < height - 1) {
            sum += data[(y + 1) * width + x];
            count++;
        }
    }
    
    if (!horizontal && !vertical) {
        // Diagonal neighbors
        if (x > 0 && y > 0) {
            sum += data[(y - 1) * width + (x - 1)];
            count++;
        }
        if (x < width - 1 && y > 0) {
            sum += data[(y - 1) * width + (x + 1)];
            count++;
        }
        if (x > 0 && y < height - 1) {
            sum += data[(y + 1) * width + (x - 1)];
            count++;
        }
        if (x < width - 1 && y < height - 1) {
            sum += data[(y + 1) * width + (x + 1)];
            count++;
        }
    }
    
    return count > 0 ? (uint8_t)(sum / count) : 0;
}

- (void)createPixelBufferFromRGB:(const void *)data 
                           width:(size_t)width 
                          height:(size_t)height 
                     pixelBuffer:(CVPixelBufferRef *)pixelBuffer {
    // Convert RGB to BGRA with IOSurface backing
    *pixelBuffer = CreateIOSurfaceBackedPixelBuffer(width, height, kCVPixelFormatType_32BGRA);
    if (!*pixelBuffer) {
        NSLog(@"AravisBridge: Failed to create pixel buffer for RGB");
        return;
    }
    
    CVPixelBufferLockBaseAddress(*pixelBuffer, 0);
    void *baseAddress = CVPixelBufferGetBaseAddress(*pixelBuffer);
    size_t bytesPerRow = CVPixelBufferGetBytesPerRow(*pixelBuffer);
    
    const uint8_t *srcData = (const uint8_t *)data;
    uint8_t *dstData = (uint8_t *)baseAddress;
    
    for (size_t y = 0; y < height; y++) {
        for (size_t x = 0; x < width; x++) {
            size_t srcIdx = y * width * 3 + x * 3;
            size_t dstIdx = y * bytesPerRow + x * 4;
            
            dstData[dstIdx + 0] = srcData[srcIdx + 2]; // B
            dstData[dstIdx + 1] = srcData[srcIdx + 1]; // G
            dstData[dstIdx + 2] = srcData[srcIdx + 0]; // R
            dstData[dstIdx + 3] = 255;                 // A
        }
    }
    
    CVPixelBufferUnlockBaseAddress(*pixelBuffer, 0);
}

- (void)createPixelBufferFromBGR:(const void *)data 
                           width:(size_t)width 
                          height:(size_t)height 
                     pixelBuffer:(CVPixelBufferRef *)pixelBuffer {
    // Convert BGR to BGRA with IOSurface backing
    *pixelBuffer = CreateIOSurfaceBackedPixelBuffer(width, height, kCVPixelFormatType_32BGRA);
    if (!*pixelBuffer) {
        NSLog(@"AravisBridge: Failed to create pixel buffer for BGR");
        return;
    }
    
    CVPixelBufferLockBaseAddress(*pixelBuffer, 0);
    void *baseAddress = CVPixelBufferGetBaseAddress(*pixelBuffer);
    size_t bytesPerRow = CVPixelBufferGetBytesPerRow(*pixelBuffer);
    
    const uint8_t *srcData = (const uint8_t *)data;
    uint8_t *dstData = (uint8_t *)baseAddress;
    
    for (size_t y = 0; y < height; y++) {
        for (size_t x = 0; x < width; x++) {
            size_t srcIdx = y * width * 3 + x * 3;
            size_t dstIdx = y * bytesPerRow + x * 4;
            
            dstData[dstIdx + 0] = srcData[srcIdx + 0]; // B
            dstData[dstIdx + 1] = srcData[srcIdx + 1]; // G
            dstData[dstIdx + 2] = srcData[srcIdx + 2]; // R
            dstData[dstIdx + 3] = 255;                 // A
        }
    }
    
    CVPixelBufferUnlockBaseAddress(*pixelBuffer, 0);
}

#pragma mark - Camera Settings

- (BOOL)setFrameRate:(double)frameRate {
    if (!_camera) return NO;
    
    GError *error = NULL;
    arv_camera_set_frame_rate(_camera, frameRate, &error);
    
    if (error) {
        g_error_free(error);
        return NO;
    }
    return YES;
}

- (BOOL)setExposureTime:(double)exposureTimeUs {
    if (!_camera) return NO;
    
    GError *error = NULL;
    
    // Check if exposure time is available
    if (!arv_camera_is_exposure_time_available(_camera, &error)) {
        NSLog(@"AravisBridge: Exposure time control not available on this camera");
        if (error) {
            NSLog(@"AravisBridge: Error: %s", error->message);
            g_error_free(error);
        }
        return NO;
    }
    
    // Get exposure time bounds
    double min_exposure, max_exposure;
    arv_camera_get_exposure_time_bounds(_camera, &min_exposure, &max_exposure, &error);
    if (error) {
        NSLog(@"AravisBridge: Failed to get exposure bounds: %s", error->message);
        g_error_free(error);
        error = NULL;
    } else {
        NSLog(@"AravisBridge: Exposure bounds: %.1f - %.1f µs", min_exposure, max_exposure);
        
        // Clamp value to bounds
        if (exposureTimeUs < min_exposure) {
            NSLog(@"AravisBridge: Clamping exposure time to minimum: %.1f µs", min_exposure);
            exposureTimeUs = min_exposure;
        } else if (exposureTimeUs > max_exposure) {
            NSLog(@"AravisBridge: Clamping exposure time to maximum: %.1f µs", max_exposure);
            exposureTimeUs = max_exposure;
        }
    }
    
    arv_camera_set_exposure_time(_camera, exposureTimeUs, &error);
    
    if (error) {
        NSLog(@"AravisBridge: Failed to set exposure time: %s", error->message);
        g_error_free(error);
        return NO;
    }
    
    // Verify the change
    double actual_exposure = arv_camera_get_exposure_time(_camera, &error);
    if (!error) {
        NSLog(@"AravisBridge: Set exposure time to %.1f µs (requested: %.1f µs)", actual_exposure, exposureTimeUs);
    }
    
    return YES;
}

- (BOOL)setGain:(double)gain {
    if (!_camera) return NO;
    
    GError *error = NULL;
    
    // Check if gain is available
    if (!arv_camera_is_gain_available(_camera, &error)) {
        NSLog(@"AravisBridge: Gain control not available on this camera");
        if (error) {
            NSLog(@"AravisBridge: Error: %s", error->message);
            g_error_free(error);
        }
        return NO;
    }
    
    // Get gain bounds
    double min_gain, max_gain;
    arv_camera_get_gain_bounds(_camera, &min_gain, &max_gain, &error);
    if (error) {
        NSLog(@"AravisBridge: Failed to get gain bounds: %s", error->message);
        g_error_free(error);
        error = NULL;
    } else {
        NSLog(@"AravisBridge: Gain bounds: %.2f - %.2f", min_gain, max_gain);
        
        // Clamp value to bounds
        if (gain < min_gain) {
            NSLog(@"AravisBridge: Clamping gain to minimum: %.2f", min_gain);
            gain = min_gain;
        } else if (gain > max_gain) {
            NSLog(@"AravisBridge: Clamping gain to maximum: %.2f", max_gain);
            gain = max_gain;
        }
    }
    
    arv_camera_set_gain(_camera, gain, &error);
    
    if (error) {
        NSLog(@"AravisBridge: Failed to set gain: %s", error->message);
        g_error_free(error);
        return NO;
    }
    
    // Verify the change
    double actual_gain = arv_camera_get_gain(_camera, &error);
    if (!error) {
        NSLog(@"AravisBridge: Set gain to %.2f (requested: %.2f)", actual_gain, gain);
    }
    
    return YES;
}

- (double)frameRate {
    if (!_camera) return 0;
    return arv_camera_get_frame_rate(_camera, NULL);
}

- (double)exposureTime {
    if (!_camera) return 0;
    return arv_camera_get_exposure_time(_camera, NULL);
}

- (double)gain {
    if (!_camera) return 0;
    return arv_camera_get_gain(_camera, NULL);
}

- (void)setPreferredPixelFormat:(NSString *)format {
    @synchronized(self) {
        _preferredPixelFormat = format ?: @"Auto";
        NSLog(@"AravisBridge: Preferred pixel format set to: %@", _preferredPixelFormat);
    }
}

- (BOOL)setResolution:(CGSize)resolution {
    if (!_camera) return NO;
    
    GError *error = NULL;
    
    // Stop streaming if active
    BOOL wasStreaming = (_state == AravisCameraStateStreaming);
    if (wasStreaming) {
        [self stopStreaming];
    }
    
    // Set the region of interest (ROI)
    arv_camera_set_region(_camera, 0, 0, (int)resolution.width, (int)resolution.height, &error);
    
    if (error) {
        NSLog(@"AravisBridge: Failed to set resolution: %s", error->message);
        g_error_free(error);
        
        // Restart streaming if it was active
        if (wasStreaming) {
            [self startStreaming];
        }
        return NO;
    }
    
    NSLog(@"AravisBridge: Successfully set resolution to %dx%d", (int)resolution.width, (int)resolution.height);
    
    // Restart streaming if it was active
    if (wasStreaming) {
        [self startStreaming];
    }
    
    return YES;
}

- (NSDictionary *)getCameraCapabilities {
    if (!_camera) return @{};
    
    NSMutableDictionary *capabilities = [NSMutableDictionary dictionary];
    GError *error = NULL;
    
    // Check exposure time
    capabilities[@"exposureTimeAvailable"] = @(arv_camera_is_exposure_time_available(_camera, NULL));
    if ([capabilities[@"exposureTimeAvailable"] boolValue]) {
        double min_exp, max_exp;
        arv_camera_get_exposure_time_bounds(_camera, &min_exp, &max_exp, &error);
        if (!error) {
            capabilities[@"exposureTimeMin"] = @(min_exp);
            capabilities[@"exposureTimeMax"] = @(max_exp);
            capabilities[@"exposureTimeCurrent"] = @(arv_camera_get_exposure_time(_camera, NULL));
        } else {
            g_error_free(error);
            error = NULL;
        }
    }
    
    // Check gain
    capabilities[@"gainAvailable"] = @(arv_camera_is_gain_available(_camera, NULL));
    if ([capabilities[@"gainAvailable"] boolValue]) {
        double min_gain, max_gain;
        arv_camera_get_gain_bounds(_camera, &min_gain, &max_gain, &error);
        if (!error) {
            capabilities[@"gainMin"] = @(min_gain);
            capabilities[@"gainMax"] = @(max_gain);
            capabilities[@"gainCurrent"] = @(arv_camera_get_gain(_camera, NULL));
        } else {
            g_error_free(error);
            error = NULL;
        }
    }
    
    // Check frame rate
    capabilities[@"frameRateAvailable"] = @(arv_camera_is_frame_rate_available(_camera, NULL));
    if ([capabilities[@"frameRateAvailable"] boolValue]) {
        double min_fps, max_fps;
        arv_camera_get_frame_rate_bounds(_camera, &min_fps, &max_fps, &error);
        if (!error) {
            capabilities[@"frameRateMin"] = @(min_fps);
            capabilities[@"frameRateMax"] = @(max_fps);
            capabilities[@"frameRateCurrent"] = @(arv_camera_get_frame_rate(_camera, NULL));
        } else {
            g_error_free(error);
            error = NULL;
        }
    }
    
    // Get sensor info
    int sensor_width, sensor_height;
    arv_camera_get_sensor_size(_camera, &sensor_width, &sensor_height, &error);
    if (!error) {
        capabilities[@"sensorWidth"] = @(sensor_width);
        capabilities[@"sensorHeight"] = @(sensor_height);
    } else {
        g_error_free(error);
        error = NULL;
    }
    
    // Log capabilities
    NSLog(@"AravisBridge: Camera capabilities:");
    NSLog(@"  - Exposure time: %@", [capabilities[@"exposureTimeAvailable"] boolValue] ? 
          [NSString stringWithFormat:@"Yes (%.1f - %.1f µs)", 
           [capabilities[@"exposureTimeMin"] doubleValue],
           [capabilities[@"exposureTimeMax"] doubleValue]] : @"No");
    NSLog(@"  - Gain: %@", [capabilities[@"gainAvailable"] boolValue] ? 
          [NSString stringWithFormat:@"Yes (%.1f - %.1f)", 
           [capabilities[@"gainMin"] doubleValue],
           [capabilities[@"gainMax"] doubleValue]] : @"No");
    NSLog(@"  - Frame rate: %@", [capabilities[@"frameRateAvailable"] boolValue] ? 
          [NSString stringWithFormat:@"Yes (%.1f - %.1f fps)", 
           [capabilities[@"frameRateMin"] doubleValue],
           [capabilities[@"frameRateMax"] doubleValue]] : @"No");
    
    return capabilities;
}

#pragma mark - Private

- (void)setState:(AravisCameraState)state {
    _state = state;
    if (self.delegate) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self.delegate aravisBridge:self didChangeState:state];
        });
    }
}

- (void)handleError:(GError *)error message:(NSString *)message {
    NSString *errorMessage = error ? [NSString stringWithUTF8String:error->message] : @"Unknown error";
    NSError *nsError = [NSError errorWithDomain:@"AravisBridge" 
                                           code:error ? error->code : -1
                                       userInfo:@{NSLocalizedDescriptionKey: message,
                                                NSLocalizedFailureReasonErrorKey: errorMessage}];
    
    [self setState:AravisCameraStateError];
    
    if (self.delegate) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self.delegate aravisBridge:self didEncounterError:nsError];
        });
    }
}

- (CGSize)currentResolution {
    return _currentResolution;
}

@end