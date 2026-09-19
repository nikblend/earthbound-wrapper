//
//  GameRenderer.swift
//  EarthboundWrapper
//
//  Draws the emulator's frame with `MTKView`.
//
//  Deliberately the simplest thing that could work: one textured quad, one
//  pipeline, one texture that is re-created only when the frame size changes. The
//  per-frame work is an upload and a draw call, and everything interesting about
//  presentation lives in `BlitGeometry` as a destination rectangle.
//
//  Re-presenting the previous texture on a frame where the core produced nothing
//  is intentional. `MTKView` hands out a fresh drawable every cycle, and skipping
//  the present entirely would leave the timing of the layer to the system; drawing
//  the same quad again costs almost nothing and keeps the cadence predictable.
//

import Foundation
import Metal
import MetalKit
import SwiftUI

final class GameRenderer: NSObject, MTKViewDelegate {
    /// Everything the renderer needs to know that does not come from the frame.
    struct Input {
        var displayAspect: Double = 4.0 / 3.0
        var settings: DisplaySnapshot = .fallback
    }

    static let colorPixelFormat: MTLPixelFormat = .bgra8Unorm

    private let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private let blitPipeline: MTLRenderPipelineState
    private var texture: MTLTexture?
    private var textureSize = CGSize.zero

    /// Set from the main thread before each draw.
    var input = Input()

    weak var frames: FrameQueue?

    /// Called after each present, on the main thread. The SwiftUI layer uses this
    /// as its once-per-frame heartbeat for feeding haptics.
    var onFramePresented: (() -> Void)?

    init?(device: MTLDevice, pixelFormat: MTLPixelFormat) {
        guard let queue = device.makeCommandQueue() else { return nil }
        commandQueue = queue
        self.device = device

        // The shader source is compiled into the app's default library, which is
        // what `MTLLibrary` finds automatically for a Metal file in the target.
        guard let library = device.makeDefaultLibrary(),
              let vertexFunction = library.makeFunction(name: "ebBlitVertex"),
              let fragmentFunction = library.makeFunction(name: "ebBlitFragment")
        else { return nil }

        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.label = "SNES blit"
        descriptor.vertexFunction = vertexFunction
        descriptor.fragmentFunction = fragmentFunction
        descriptor.colorAttachments[0].pixelFormat = pixelFormat

        guard let pipeline = try? device.makeRenderPipelineState(descriptor: descriptor) else {
            return nil
        }
        blitPipeline = pipeline

        super.init()
    }

    // MARK: - MTKViewDelegate

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        // Nothing to do: the destination rectangle is recomputed from the drawable
        // size on every frame, so a rotation or a window resize needs no state.
    }

    func draw(in view: MTKView) {
        guard let drawable = view.currentDrawable,
              let passDescriptor = view.currentRenderPassDescriptor,
              let commandBuffer = commandQueue.makeCommandBuffer()
        else { return }

        uploadLatestFrame()

        if texture != nil {
            encodeBlit(passDescriptor: passDescriptor, commandBuffer: commandBuffer,
                       drawableSize: view.drawableSize)
        } else {
            // Nothing to show yet. Still present, so the player sees the app's
            // background instead of whatever the layer last held.
            guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: passDescriptor)
            else { return }
            encoder.endEncoding()
        }

        commandBuffer.present(drawable)
        commandBuffer.commit()
        onFramePresented?()
    }

    // MARK: - Frame upload

    private func uploadLatestFrame() {
        guard let frames, let frame = frames.acquire() else { return }
        defer { frames.release() }

        if texture == nil || textureSize.width != CGFloat(frame.width)
            || textureSize.height != CGFloat(frame.height) {
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: .rgba8Unorm,
                width: frame.width,
                height: frame.height,
                mipmapped: false)
            descriptor.usage = .shaderRead
            // `.shared` lets the CPU write straight into the texture's storage on
            // iOS, which is what `replace(region:)` wants and avoids a second copy.
            descriptor.storageMode = .shared
            texture = device.makeTexture(descriptor: descriptor)
            texture?.label = "SNES frame"
            textureSize = CGSize(width: frame.width, height: frame.height)
        }

        guard let texture else { return }
        texture.replace(region: MTLRegionMake2D(0, 0, frame.width, frame.height),
                        mipmapLevel: 0,
                        withBytes: frame.pixels,
                        bytesPerRow: frame.bytesPerRow)
    }

    // MARK: - Encoding

    private func encodeBlit(passDescriptor: MTLRenderPassDescriptor,
                            commandBuffer: MTLCommandBuffer,
                            drawableSize: CGSize) {
        guard let texture,
              let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: passDescriptor)
        else { return }

        let rect = BlitGeometry.destinationRect(
            drawableWidth: Double(drawableSize.width),
            drawableHeight: Double(drawableSize.height),
            sourceWidth: Double(texture.width),
            sourceHeight: Double(texture.height),
            displayAspect: input.displayAspect,
            settings: input.settings)

        var blitRect = rect
        var smoothing: Float = input.settings.smoothing ? 1 : 0

        encoder.setRenderPipelineState(blitPipeline)
        encoder.setVertexBytes(&blitRect, length: MemoryLayout<SIMD4<Float>>.size, index: 0)
        encoder.setFragmentBytes(&smoothing, length: MemoryLayout<Float>.size, index: 0)
        encoder.setFragmentTexture(texture, index: 0)
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        encoder.endEncoding()
    }
}

// MARK: - SwiftUI wrapper

/// The emulator's picture, and the once-per-frame heartbeat the rest of the UI
/// hangs off.
struct MetalGameView: UIViewRepresentable {
    let frameQueue: FrameQueue
    let settings: DisplaySnapshot
    let displayAspect: Double
    /// Called on the main thread after every presented frame.
    let onFramePresented: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIView(context: Context) -> MTKView {
        let view = MTKView()
        view.device = context.coordinator.device
        view.colorPixelFormat = GameRenderer.colorPixelFormat
        view.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        view.framebufferOnly = true
        // Free-running rather than `isPaused`, so the draw loop keeps ticking even
        // through a long stall in the emulation thread: the last frame stays on
        // screen and the controls stay responsive.
        view.isPaused = false
        view.enableSetNeedsDisplay = false
        view.preferredFramesPerSecond = 60
        view.backgroundColor = .black
        context.coordinator.renderer?.frames = frameQueue
        view.delegate = context.coordinator.renderer
        return view
    }

    func updateUIView(_ view: MTKView, context: Context) {
        context.coordinator.renderer?.input = GameRenderer.Input(displayAspect: displayAspect,
                                                                settings: settings)
        context.coordinator.renderer?.onFramePresented = onFramePresented
    }

    static func dismantleUIView(_ view: MTKView, coordinator: Coordinator) {
        view.delegate = nil
        coordinator.renderer?.onFramePresented = nil
    }

    final class Coordinator {
        let device: MTLDevice?
        let renderer: GameRenderer?

        init() {
            let device = MTLCreateSystemDefaultDevice()
            self.device = device
            if let device {
                renderer = GameRenderer(device: device,
                                        pixelFormat: GameRenderer.colorPixelFormat)
            } else {
                renderer = nil
            }
        }
    }
}
