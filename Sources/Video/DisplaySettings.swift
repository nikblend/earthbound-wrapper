//
//  DisplaySettings.swift
//  EarthboundWrapper
//
//  How the 256x224 image is fitted onto a 19.5:9 screen.
//
//  This is the app's answer to "the game looks tiny". A SNES frame is 4:3 inside
//  a phone that is roughly 2.2:1 in landscape, so an aspect-correct fit uses only
//  about 60% of the width and leaves two fat pillarboxes. There are three honest
//  ways out:
//
//    fit       aspect-correct, as tall as the screen allows. Correct, and still
//              leaves the bars.
//    integer   whole-number scaling of the raw pixel grid. The pixels are perfect
//              and the bars are slightly bigger.
//    fill      let the image grow sideways until it reaches the screen edges. The
//              slider decides how much of the stretch to take; anything short of
//              1.0 is a compromise, and for a 2D game with a fixed HUD a mild
//              stretch costs much less than it sounds.
//
//  Zoom crops in past any of those, which is the other lever: the SNES draws a lot
//  of dead border, and pushing it off-screen makes what is left bigger.
//

import Foundation
import Observation
import SwiftUI

/// An immutable snapshot the renderer can read without touching `@Observable`.
struct DisplaySnapshot: Equatable, Sendable {
    var scaling: DisplaySettings.Scaling = .fit
    var stretch: Double = 0
    var zoom: Double = 1
    var verticalOffset: Double = 0
    var smoothing = false

    static let fallback = DisplaySnapshot()
}

@MainActor
@Observable
final class DisplaySettings {
    enum Scaling: String, CaseIterable, Identifiable, Sendable {
        /// Aspect-correct at the largest size that fits.
        case fit
        /// Whole-number scaling, square pixels, exact pixels.
        case integer
        /// Grow sideways toward the screen edges.
        case fill

        var id: String { rawValue }

        var label: String {
            switch self {
            case .fit: return "Fit"
            case .integer: return "Pixel-perfect"
            case .fill: return "Fill"
            }
        }

        var explanation: String {
            switch self {
            case .fit: return "4:3, as large as the screen allows. Leaves bars."
            case .integer: return "Whole-number pixels. Crispest, smallest."
            case .fill: return "Widens the image toward the edges. Use the slider to choose how far."
            }
        }
    }

    var scaling: Scaling {
        didSet { persist() }
    }
    /// 0 = aspect-correct, 1 = stretched all the way to the screen edges.
    /// Only meaningful in `.fill`.
    var stretch: Double {
        didSet { persist() }
    }
    /// 1 = no crop, 1.5 = 50% larger with the edges cropped away.
    var zoom: Double {
        didSet { persist() }
    }
    /// Shifts the image up or down as a fraction of its height. Useful with zoom,
    /// where the interesting part of the frame is usually not its centre.
    var verticalOffset: Double {
        didSet { persist() }
    }
    /// Bilinear filtering. Off by default: 16-bit pixel art is meant to look like
    /// pixels, and the stretch modes already soften the grid.
    var smoothing: Bool {
        didSet { persist() }
    }

    private static let storageKey = "display.settings.v1"

    init() {
        let stored = UserDefaults.standard.dictionary(forKey: Self.storageKey) ?? [:]
        scaling = (stored["scaling"] as? String).flatMap(Scaling.init(rawValue:)) ?? .fit
        stretch = stored["stretch"] as? Double ?? 0
        zoom = stored["zoom"] as? Double ?? 1
        verticalOffset = stored["verticalOffset"] as? Double ?? 0
        smoothing = stored["smoothing"] as? Bool ?? false
    }

    var snapshot: DisplaySnapshot {
        DisplaySnapshot(scaling: scaling, stretch: stretch, zoom: zoom,
                        verticalOffset: verticalOffset, smoothing: smoothing)
    }

    private func persist() {
        UserDefaults.standard.set([
            "scaling": scaling.rawValue,
            "stretch": stretch,
            "zoom": zoom,
            "verticalOffset": verticalOffset,
            "smoothing": smoothing,
        ] as [String: Any], forKey: Self.storageKey)
    }
}

/// Fitting maths, kept apart from the Metal plumbing so the geometry can be read
/// and checked on its own.
enum BlitGeometry {
    /// Destination rectangle in normalised device coordinates, packed as
    /// `(left, bottom, width, height)`.
    ///
    /// The renderer only ever receives this, so a display-mode change never has to
    /// touch a shader, a texture, or a pipeline: it changes one `float4`.
    static func destinationRect(drawableWidth: Double,
                                drawableHeight: Double,
                                sourceWidth: Double,
                                sourceHeight: Double,
                                displayAspect: Double,
                                settings: DisplaySnapshot) -> SIMD4<Float> {
        guard drawableWidth > 0, drawableHeight > 0,
              sourceWidth > 0, sourceHeight > 0 else {
            return SIMD4(0, 0, 1, 1)
        }

        // `.integer` scales the raw pixel grid, so its natural size is the source
        // size. The other modes scale the aspect-corrected image, whose width is
        // derived from the core's display aspect rather than from the pixel count.
        let pixelExact = settings.scaling == .integer
        let baseWidth = pixelExact ? sourceWidth : sourceHeight * displayAspect
        let baseHeight = sourceHeight

        let fitScale = min(drawableWidth / baseWidth, drawableHeight / baseHeight)
        var scaleX = fitScale
        var scaleY = fitScale

        switch settings.scaling {
        case .integer:
            let whole = max(1, fitScale.rounded(.down))
            scaleX = whole
            scaleY = whole
        case .fit:
            break
        case .fill:
            // Interpolate each axis between "aspect-correct" and "fills the
            // screen". The y axis usually has nothing to give (an aspect-correct
            // fit already fills the height on a wide screen), so in practice this
            // widens the image and the vertical factor stays put.
            let fillX = drawableWidth / baseWidth
            let fillY = drawableHeight / baseHeight
            scaleX = fitScale + (fillX - fitScale) * settings.stretch
            scaleY = fitScale + (fillY - fitScale) * settings.stretch
        }

        scaleX *= settings.zoom
        scaleY *= settings.zoom

        let imageWidth = baseWidth * scaleX
        let imageHeight = baseHeight * scaleY
        let originX = (drawableWidth - imageWidth) * 0.5
        let originY = (drawableHeight - imageHeight) * 0.5
            + settings.verticalOffset * imageHeight

        // Pixels (y down) to NDC (y up).
        let left = originX / drawableWidth * 2 - 1
        let right = (originX + imageWidth) / drawableWidth * 2 - 1
        let bottom = 1 - (originY + imageHeight) / drawableHeight * 2
        let top = 1 - originY / drawableHeight * 2

        return SIMD4(Float(left), Float(bottom),
                     Float(right - left), Float(top - bottom))
    }
}
