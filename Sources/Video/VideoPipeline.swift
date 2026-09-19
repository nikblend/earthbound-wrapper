//
//  VideoPipeline.swift
//  EarthboundWrapper
//
//  Turns the core's framebuffer into something Metal can draw, without ever
//  making the emulation thread wait for the renderer.
//
//  Two pieces:
//
//    FrameQueue    three RGBA buffers with an explicit ownership handoff. The
//                  emulation thread writes into whichever buffer nobody else
//                  holds; the renderer takes the newest published buffer and
//                  releases it once the upload is done. Three is the smallest
//                  count that guarantees the writer always finds a free buffer,
//                  so neither side ever blocks on the other.
//
//    PixelDecoder  RGB565 / XRGB8888 / 0RGB1555 to RGBA8. Metal has no pixel
//                  format that round-trips libretro's channel order on every
//                  GPU, and unorm formats would silently filter the packed bits
//                  if scaled, so the conversion happens here where it is exact.
//                  A 64K-entry table turns the 16-bit case into one load and one
//                  store per pixel.
//

import Foundation

/// A decoded frame the renderer can upload.
struct VideoFrame {
    let pixels: UnsafeMutablePointer<UInt8>
    let width: Int
    let height: Int
    /// Bytes per row in `pixels`. Always `width * 4` today, but named so the
    /// renderer never has to assume it.
    let bytesPerRow: Int
    let generation: UInt64
}

/// Three-buffer handoff between the emulation thread and the draw loop.
final class FrameQueue: @unchecked Sendable {
    /// Widest frame the core can produce. snes9x tops out at 512x478 (hi-res
    /// Mode 7, interlaced); the extra headroom costs a few hundred kilobytes.
    static let maximumWidth = 640
    static let maximumHeight = 512
    private static let bufferCount = 3

    private struct State {
        /// Index the producer is currently filling.
        var writing = 0
        /// Newest finished frame, waiting for the renderer.
        var pending: Int?
        /// Frame the renderer is uploading right now.
        var inUse: Int?
        var width = 0
        var height = 0
        var generation: UInt64 = 0
    }

    private let buffers: [UnsafeMutablePointer<UInt8>]
    private let bytesPerBuffer = maximumWidth * maximumHeight * 4
    private let state = Locked(State())

    init() {
        buffers = (0..<Self.bufferCount).map { _ in
            let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bytesPerBuffer)
            buffer.initialize(repeating: 0, count: bytesPerBuffer)
            return buffer
        }
    }

    deinit {
        for buffer in buffers { buffer.deallocate() }
    }

    // MARK: - Producer side (emulation thread only)

    /// Claims a buffer for the next frame. Guaranteed to find one: the renderer
    /// holds at most one buffer and at most one is pending, so with three
    /// buffers a free one always exists.
    func beginFrame() -> UnsafeMutablePointer<UInt8> {
        let index = state.withLock { state -> Int in
            for candidate in 0..<Self.bufferCount
            where candidate != state.pending && candidate != state.inUse {
                state.writing = candidate
                return candidate
            }
            // Unreachable with three buffers. Falling back keeps a logic error
            // in this file to a torn frame instead of an index crash.
            state.writing = state.pending ?? 0
            return state.writing
        }
        return buffers[index]
    }

    /// Publishes the frame just written. Any previously pending frame is
    /// dropped: at 60 Hz with a renderer that occasionally runs slower, showing
    /// the newest frame matters more than showing every one.
    func commitFrame(width: Int, height: Int) {
        state.withLock { state in
            state.pending = state.writing
            state.width = width
            state.height = height
            state.generation &+= 1
        }
    }

    // MARK: - Consumer side (draw loop)

    /// The newest published frame, marked in use until `release()`.
    func acquire() -> VideoFrame? {
        state.withLock { state -> VideoFrame? in
            guard let index = state.pending, state.inUse == nil else { return nil }
            state.pending = nil
            state.inUse = index
            return VideoFrame(pixels: buffers[index],
                              width: state.width,
                              height: state.height,
                              bytesPerRow: state.width * 4,
                              generation: state.generation)
        }
    }

    func release() {
        state.withLock { $0.inUse = nil }
    }
}

// MARK: - Pixel decoding

/// Expands the core's framebuffers into the RGBA8 layout `MTLPixelFormat.rgba8Unorm`
/// expects.
///
/// Not thread-safe by design: it is only ever used from the emulation thread, and
/// the tables are built once on first use.
enum PixelDecoder {
    /// 1 << 16 entries of RGBA8 pixels, little-endian packed as AABBGGRR.
    private static let rgb565Table: UnsafeMutablePointer<UInt32> = {
        let table = UnsafeMutablePointer<UInt32>.allocate(capacity: 1 << 16)
        for value in 0..<(1 << 16) {
            let r5 = UInt32((value >> 11) & 0x1F)
            let g6 = UInt32((value >> 5) & 0x3F)
            let b5 = UInt32(value & 0x1F)
            // Bit replication so full-on stays full-on: 0x1F -> 0xFF, and the
            // mid-tones land where a linear expand would put them.
            let r = (r5 << 3) | (r5 >> 2)
            let g = (g6 << 2) | (g6 >> 4)
            let b = (b5 << 3) | (b5 >> 2)
            table[value] = 0xFF00_0000 | (b << 16) | (g << 8) | r
        }
        return table
    }()

    /// 1 << 15 entries for the legacy 0RGB1555 layout.
    private static let rgb1555Table: UnsafeMutablePointer<UInt32> = {
        let table = UnsafeMutablePointer<UInt32>.allocate(capacity: 1 << 15)
        for value in 0..<(1 << 15) {
            let r5 = UInt32((value >> 10) & 0x1F)
            let g5 = UInt32((value >> 5) & 0x1F)
            let b5 = UInt32(value & 0x1F)
            let r = (r5 << 3) | (r5 >> 2)
            let g = (g5 << 3) | (g5 >> 2)
            let b = (b5 << 3) | (b5 >> 2)
            table[value] = 0xFF00_0000 | (b << 16) | (g << 8) | r
        }
        return table
    }()

    /// Decodes one frame into `destination`, which must hold at least
    /// `width * height * 4` bytes. `source` may be null, which libretro uses to
    /// mean "repeat the previous frame" — the caller detects that separately and
    /// never reaches here.
    static func decode(source: UnsafeRawPointer,
                       width: Int,
                       height: Int,
                       pitch: Int,
                       format: Libretro.PixelFormat,
                       into destination: UnsafeMutablePointer<UInt8>) {
        guard width > 0, height > 0 else { return }

        switch format {
        case .rgb565:
            for row in 0..<height {
                let source16 = (source + row * pitch).assumingMemoryBound(to: UInt16.self)
                let rowBase = destination + row * width * 4
                rowBase.withMemoryRebound(to: UInt32.self, capacity: width) { row32 in
                    for column in 0..<width {
                        row32[column] = rgb565Table[Int(source16[column])]
                    }
                }
            }

        case .zeroRGB1555:
            for row in 0..<height {
                let source16 = (source + row * pitch).assumingMemoryBound(to: UInt16.self)
                let rowBase = destination + row * width * 4
                rowBase.withMemoryRebound(to: UInt32.self, capacity: width) { row32 in
                    for column in 0..<width {
                        // Bit 15 is the unused zero, so mask it before indexing.
                        row32[column] = rgb1555Table[Int(source16[column] & 0x7FFF)]
                    }
                }
            }

        case .xrgb8888:
            for row in 0..<height {
                let source32 = (source + row * pitch).assumingMemoryBound(to: UInt32.self)
                let rowBase = destination + row * width * 4
                rowBase.withMemoryRebound(to: UInt32.self, capacity: width) { row32 in
                    for column in 0..<width {
                        // Stored as 0x00RRGGBB; RGBA8 wants the bytes R,G,B,A, so
                        // the red and blue bytes trade places.
                        let value = source32[column]
                        let swapped = (value & 0xFF00_FF00)
                            | ((value & 0x0000_00FF) << 16)
                            | ((value >> 16) & 0x0000_00FF)
                        row32[column] = 0xFF00_0000 | swapped
                    }
                }
            }
        }
    }
}
