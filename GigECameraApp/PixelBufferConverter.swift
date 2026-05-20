//
//  PixelBufferConverter.swift
//  GigECameraApp
//
//  Converts pixel buffers between formats
//

import Foundation
import CoreVideo
import VideoToolbox
import os.log

class PixelBufferConverter {
    private let logger = Logger(subsystem: "com.lukechang.GigEVirtualCamera", category: "PixelBufferConverter")
    private var converter: VTPixelTransferSession?

    // Reused output pool, recreated only when the output dimensions change.
    private var pool: CVPixelBufferPool?
    private var poolWidth = 0
    private var poolHeight = 0

    init() {
        VTPixelTransferSessionCreate(allocator: kCFAllocatorDefault, pixelTransferSessionOut: &converter)
        if let converter = converter {
            VTSessionSetProperty(converter, key: kVTPixelTransferPropertyKey_ScalingMode, value: kVTScalingMode_Normal)
        }
    }

    deinit {
        converter = nil
    }

    /// Returns a recycled YUV420 IOSurface-backed buffer of the given size,
    /// (re)building the pool only when dimensions change.
    private func dequeueYUVBuffer(width: Int, height: Int) -> CVPixelBuffer? {
        if pool == nil || width != poolWidth || height != poolHeight {
            let bufferAttrs: [CFString: Any] = [
                kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                kCVPixelBufferWidthKey: width,
                kCVPixelBufferHeightKey: height,
                kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary
            ]
            var newPool: CVPixelBufferPool?
            let status = CVPixelBufferPoolCreate(kCFAllocatorDefault, nil,
                                                 bufferAttrs as CFDictionary, &newPool)
            guard status == kCVReturnSuccess, let createdPool = newPool else {
                logger.error("Failed to create pixel buffer pool: \(status)")
                return nil
            }
            pool = createdPool
            poolWidth = width
            poolHeight = height
        }
        var buffer: CVPixelBuffer?
        let status = CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool!, &buffer)
        guard status == kCVReturnSuccess else {
            logger.error("Failed to dequeue pooled buffer: \(status)")
            return nil
        }
        return buffer
    }
    
    /// Convert BGRA to YUV420 (420v) format for video streaming
    func convertBGRAToYUV420(_ bgraBuffer: CVPixelBuffer) -> CVPixelBuffer? {
        guard let converter = converter else {
            logger.error("No pixel transfer session available")
            return nil
        }
        
        let width = CVPixelBufferGetWidth(bgraBuffer)
        let height = CVPixelBufferGetHeight(bgraBuffer)
        
        guard let outputBuffer = dequeueYUVBuffer(width: width, height: height) else {
            return nil
        }
        
        // Perform the conversion
        let transferResult = VTPixelTransferSessionTransferImage(
            converter,
            from: bgraBuffer,
            to: outputBuffer
        )
        
        if transferResult != noErr {
            logger.error("Failed to convert pixel buffer: \(transferResult)")
            return nil
        }
        
        return outputBuffer
    }
    
    /// Convert to standard HD resolution if needed
    func convertToHD(_ inputBuffer: CVPixelBuffer, targetWidth: Int = 1280, targetHeight: Int = 720) -> CVPixelBuffer? {
        let currentWidth = CVPixelBufferGetWidth(inputBuffer)
        let currentHeight = CVPixelBufferGetHeight(inputBuffer)
        
        // If already HD, just convert format
        if currentWidth == targetWidth && currentHeight == targetHeight {
            return convertBGRAToYUV420(inputBuffer)
        }
        
        // Need to scale and convert
        guard let converter = converter else {
            logger.error("No pixel transfer session available")
            return nil
        }
        
        guard let outputBuffer = dequeueYUVBuffer(width: targetWidth, height: targetHeight) else {
            return nil
        }
        
        // Perform scaling and format conversion
        let transferResult = VTPixelTransferSessionTransferImage(
            converter,
            from: inputBuffer,
            to: outputBuffer
        )
        
        if transferResult != noErr {
            logger.error("Failed to scale and convert pixel buffer: \(transferResult)")
            return nil
        }
        
        return outputBuffer
    }
}