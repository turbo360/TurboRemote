import Foundation
import Metal
import MetalKit
import CoreVideo
import AppKit
import SwiftUI

final class MetalRenderer: NSObject, MTKViewDelegate, @unchecked Sendable {
    private let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private let passthroughPipeline: MTLRenderPipelineState
    private let colourPipeline: MTLRenderPipelineState
    private var textureCache: CVMetalTextureCache?
    private var colourParamsBuffer: MTLBuffer?

    private var currentPixelBuffer: CVPixelBuffer?
    private let lock = NSLock()

    let colourManager = ColourPipelineManager()
    private var useColourTransform = false

    init?(mtkView: MTKView) {
        guard let device = MTLCreateSystemDefaultDevice() else {
            print("[Renderer] No Metal device")
            return nil
        }
        self.device = device

        guard let queue = device.makeCommandQueue() else {
            print("[Renderer] Failed to create command queue")
            return nil
        }
        self.commandQueue = queue

        var cache: CVMetalTextureCache?
        CVMetalTextureCacheCreate(nil, nil, device, nil, &cache)
        self.textureCache = cache

        guard let library = device.makeDefaultLibrary() else {
            print("[Renderer] No default Metal library")
            return nil
        }

        // Configure MTKView for HDR/EDR if available
        if let screen = mtkView.window?.screen ?? NSScreen.main {
            let maxEDR = screen.maximumExtendedDynamicRangeColorComponentValue
            if maxEDR > 1.0 {
                mtkView.colorPixelFormat = .rgba16Float
                mtkView.colorspace = CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3)
                print("[Renderer] EDR enabled: headroom=\(maxEDR)")
            }
        }

        // Passthrough pipeline (no colour transform)
        let passDesc = MTLRenderPipelineDescriptor()
        passDesc.vertexFunction = library.makeFunction(name: "videoVertexShader")
        passDesc.fragmentFunction = library.makeFunction(name: "videoFragmentShader")
        passDesc.colorAttachments[0].pixelFormat = mtkView.colorPixelFormat

        // Colour-managed pipeline
        let colourDesc = MTLRenderPipelineDescriptor()
        colourDesc.vertexFunction = library.makeFunction(name: "videoVertexShader")
        colourDesc.fragmentFunction = library.makeFunction(name: "videoColourFragmentShader")
        colourDesc.colorAttachments[0].pixelFormat = mtkView.colorPixelFormat

        do {
            passthroughPipeline = try device.makeRenderPipelineState(descriptor: passDesc)
            colourPipeline = try device.makeRenderPipelineState(descriptor: colourDesc)
        } catch {
            print("[Renderer] Pipeline error: \(error)")
            return nil
        }

        colourParamsBuffer = device.makeBuffer(length: MemoryLayout<ColourParams>.size, options: .storageModeShared)

        super.init()

        mtkView.device = device
        mtkView.delegate = self
        mtkView.enableSetNeedsDisplay = false
        mtkView.isPaused = false
        mtkView.preferredFramesPerSecond = 60

        // Detect client display colour space
        colourManager.updateClientDisplay()
    }

    func updatePixelBuffer(_ pixelBuffer: CVPixelBuffer) {
        lock.lock()
        currentPixelBuffer = pixelBuffer
        lock.unlock()
    }

    func setSourceColourSpace(_ info: ColourSpaceInfo) {
        colourManager.updateSourceColourSpace(info)
        useColourTransform = colourManager.needsTransform
    }

    // MARK: - MTKViewDelegate

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        colourManager.updateClientDisplay()
        useColourTransform = colourManager.needsTransform
    }

    func draw(in view: MTKView) {
        lock.lock()
        let pixelBuffer = currentPixelBuffer
        lock.unlock()

        guard let pixelBuffer = pixelBuffer,
              let drawable = view.currentDrawable,
              let passDescriptor = view.currentRenderPassDescriptor else {
            return
        }

        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)

        guard let textureCache = textureCache else { return }

        var cvTexture: CVMetalTexture?
        let status = CVMetalTextureCacheCreateTextureFromImage(
            nil, textureCache, pixelBuffer, nil,
            .bgra8Unorm, width, height, 0, &cvTexture
        )

        guard status == kCVReturnSuccess, let cvTex = cvTexture else { return }
        guard let texture = CVMetalTextureGetTexture(cvTex) else { return }

        guard let commandBuffer = commandQueue.makeCommandBuffer(),
              let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: passDescriptor) else {
            return
        }

        if useColourTransform, let paramsBuffer = colourParamsBuffer {
            // Colour-managed rendering
            var params = colourManager.colourParams
            paramsBuffer.contents().copyMemory(from: &params, byteCount: MemoryLayout<ColourParams>.size)

            encoder.setRenderPipelineState(colourPipeline)
            encoder.setFragmentTexture(texture, index: 0)
            encoder.setFragmentBuffer(paramsBuffer, offset: 0, index: 0)
        } else {
            // Passthrough
            encoder.setRenderPipelineState(passthroughPipeline)
            encoder.setFragmentTexture(texture, index: 0)
        }

        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
        encoder.endEncoding()

        commandBuffer.present(drawable)
        commandBuffer.commit()
    }
}

// MARK: - SwiftUI wrapper

struct MetalStreamView: NSViewRepresentable {
    let renderer: MetalRenderer?
    @Binding var mtkView: MTKView

    func makeNSView(context: Context) -> MTKView {
        return mtkView
    }

    func updateNSView(_ nsView: MTKView, context: Context) {}
}
