import Foundation
import Metal
import CoreVideo

final class FrameDeltaAnalyzer: @unchecked Sendable {
    private let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private let pipelineState: MTLComputePipelineState
    private let counterBuffer: MTLBuffer
    private let thresholdBuffer: MTLBuffer
    private var textureCache: CVMetalTextureCache?
    private var previousTexture: MTLTexture?

    init?() {
        guard let device = MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue(),
              let library = device.makeDefaultLibrary(),
              let function = library.makeFunction(name: "frameDeltaCompute") else {
            return nil
        }

        self.device = device
        self.commandQueue = queue

        do {
            pipelineState = try device.makeComputePipelineState(function: function)
        } catch {
            print("[DeltaAnalyzer] Pipeline error: \(error)")
            return nil
        }

        guard let counter = device.makeBuffer(length: MemoryLayout<UInt32>.size, options: .storageModeShared),
              let threshold = device.makeBuffer(length: MemoryLayout<Float>.size, options: .storageModeShared) else {
            return nil
        }

        counterBuffer = counter
        thresholdBuffer = threshold

        // Default threshold: ~0.024 (roughly 2/255 per channel * 3 channels)
        thresholdBuffer.contents().storeBytes(of: Float(0.024), as: Float.self)

        var cache: CVMetalTextureCache?
        CVMetalTextureCacheCreate(nil, nil, device, nil, &cache)
        textureCache = cache
    }

    /// Returns the fraction of pixels that changed (0.0 to 1.0)
    func analyzeDelta(pixelBuffer: CVPixelBuffer) -> Float {
        guard let textureCache = textureCache else { return 1.0 }

        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)

        var cvTexture: CVMetalTexture?
        let status = CVMetalTextureCacheCreateTextureFromImage(
            nil, textureCache, pixelBuffer, nil,
            .bgra8Unorm, width, height, 0, &cvTexture
        )
        guard status == kCVReturnSuccess, let cvTex = cvTexture,
              let currentTexture = CVMetalTextureGetTexture(cvTex) else {
            return 1.0
        }

        defer {
            previousTexture = currentTexture
        }

        guard let prevTexture = previousTexture,
              prevTexture.width == currentTexture.width,
              prevTexture.height == currentTexture.height else {
            // First frame or resolution changed — treat as full change
            return 1.0
        }

        // Reset counter
        counterBuffer.contents().storeBytes(of: UInt32(0), as: UInt32.self)

        guard let commandBuffer = commandQueue.makeCommandBuffer(),
              let encoder = commandBuffer.makeComputeCommandEncoder() else {
            return 1.0
        }

        encoder.setComputePipelineState(pipelineState)
        encoder.setTexture(currentTexture, index: 0)
        encoder.setTexture(prevTexture, index: 1)
        encoder.setBuffer(counterBuffer, offset: 0, index: 0)
        encoder.setBuffer(thresholdBuffer, offset: 0, index: 1)

        let threadGroupSize = MTLSize(width: 16, height: 16, depth: 1)
        let threadGroups = MTLSize(
            width: (width + 15) / 16,
            height: (height + 15) / 16,
            depth: 1
        )
        encoder.dispatchThreadgroups(threadGroups, threadsPerThreadgroup: threadGroupSize)
        encoder.endEncoding()

        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()

        let changedPixels = counterBuffer.contents().load(as: UInt32.self)
        let totalPixels = UInt32(width * height)
        guard totalPixels > 0 else { return 1.0 }

        return Float(changedPixels) / Float(totalPixels)
    }
}
