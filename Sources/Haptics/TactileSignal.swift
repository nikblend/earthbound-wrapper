//
//  TactileSignal.swift
//  EarthboundWrapper
//
//  Reading the game's mood off its own audio.
//
//  There is no game state to hook: as far as the frontend is concerned EarthBound
//  is an opaque stream of pixels and samples. So the tactile feedback is driven
//  by the mix itself, split into bands that correspond to things you can actually
//  feel:
//
//    bass   below ~180 Hz  — explosions, the bass line, the low end of a fanfare
//    mid    around 1 kHz   — footsteps, the drum body, menu confirmations
//    high   above ~3 kHz   — the text blip, PSI shimmer, cymbals
//
//  Onsets (sharp rises above a slow-moving average) become discrete taps; the
//  band levels become a continuous rumble. EarthBound's text blip living in the
//  high band is what makes scrolling dialogue feel like something is happening.
//
//  Cheap on purpose: two state-variable filters, three envelopes, and one pass
//  over the batch. It runs on the emulation thread, inside the audio callback,
//  where the samples already are and no copy is needed.
//

import Foundation

/// What the mix looks like for one audio batch.
struct TactileFrame {
    /// 0…1 per band.
    var bass: Float = 0
    var mid: Float = 0
    var high: Float = 0
    /// A sharp rise in the band since the last batch.
    var bassOnset = false
    var midOnset = false
    var highOnset = false

    static let silent = TactileFrame()
}

/// Two-pole state-variable filter. Gives low, band and high outputs from one
/// pass, which is exactly the shape we need at two cutoffs.
private struct StateVariableFilter {
    private var low: Float = 0
    private var band: Float = 0
    private var coefficient: Float = 0
    private let damping: Float

    init(cutoff: Float, sampleRate: Float, q: Float = 0.9) {
        // Chamberlin SVF, stable while coefficient < 1. At 180 Hz and 3 kHz on a
        // 32 kHz stream both land far inside that bound.
        coefficient = 2 * sin(.pi * min(cutoff, sampleRate * 0.24) / sampleRate)
        damping = 1 / q
    }

    mutating func process(_ input: Float) -> (low: Float, band: Float, high: Float) {
        low += coefficient * band
        let high = input - low - damping * band
        band += coefficient * high
        return (low, band, high)
    }

    mutating func reset() {
        low = 0
        band = 0
    }
}

final class TactileSignalAnalyzer {
    /// Below this, a band is treated as silence rather than a quiet signal.
    private static let noiseFloor: Float = 0.002
    /// How much a band must exceed its slow average to count as an onset.
    private static let onsetRatio: Float = 1.7
    /// Minimum spacing between onsets in the same band, so a resonant note does
    /// not buzz. Roughly 11 Hz.
    private static let onsetCooldownBatches = 5

    private var bassFilter: StateVariableFilter
    private var midFilter: StateVariableFilter
    private var presenceFilter: StateVariableFilter

    /// Fast envelopes, one step per batch.
    private var bassEnvelope: Float = 0
    private var midEnvelope: Float = 0
    private var presenceEnvelope: Float = 0
    /// Slow averages, the reference onsets are measured against.
    private var bassAverage: Float = 0
    private var midAverage: Float = 0
    private var presenceAverage: Float = 0

    private var bassCooldown = 0
    private var midCooldown = 0
    private var presenceCooldown = 0

    init(sampleRate: Double) {
        let rate = Float(sampleRate > 1000 ? sampleRate : 32_040)
        bassFilter = StateVariableFilter(cutoff: 180, sampleRate: rate)
        midFilter = StateVariableFilter(cutoff: 1_000, sampleRate: rate)
        presenceFilter = StateVariableFilter(cutoff: 3_000, sampleRate: rate)
    }

    func reset() {
        bassFilter.reset()
        midFilter.reset()
        presenceFilter.reset()
        bassEnvelope = 0
        midEnvelope = 0
        presenceEnvelope = 0
        bassAverage = 0
        midAverage = 0
        presenceAverage = 0
        bassCooldown = 0
        midCooldown = 0
        presenceCooldown = 0
    }

    /// Consumes one interleaved stereo batch and reports what it contained.
    func process(_ samples: UnsafePointer<Int16>, frames: Int) -> TactileFrame {
        guard frames > 0 else { return .silent }

        let scale: Float = 1.0 / 32_768.0
        var bassPeak: Float = 0
        var midPeak: Float = 0
        var presencePeak: Float = 0

        for frame in 0..<frames {
            // Fold to mono; the SNES pan is mostly decorative and we only have
            // one actuator anyway.
            let sample = (Float(samples[frame * 2]) + Float(samples[frame * 2 + 1]))
                * 0.5 * scale

            // Each filter's band output is the energy near its cutoff, so three
            // filters give three independent bands from one signal. Each filter
            // must be advanced exactly once per sample, hence the separate
            // calls rather than repeated reads.
            let bassMagnitude = abs(bassFilter.process(sample).low)
            let midMagnitude = abs(midFilter.process(sample).band) * 1.4
            let presence = presenceFilter.process(sample)
            let presenceMagnitude = abs(presence.band) + abs(presence.high)

            // Peak rather than mean-square: haptics care about the transient, and
            // a peak tracker reacts on the first sample of the attack.
            if bassMagnitude > bassPeak { bassPeak = bassMagnitude }
            if midMagnitude > midPeak { midPeak = midMagnitude }
            if presenceMagnitude > presencePeak { presencePeak = presenceMagnitude }
        }

        // Fast attack, slow release. The asymmetry is what makes a hit feel
        // instant and a decay feel natural instead of chattering.
        bassEnvelope = smooth(bassEnvelope, towards: bassPeak, attack: 0.55, release: 0.12)
        midEnvelope = smooth(midEnvelope, towards: midPeak, attack: 0.6, release: 0.15)
        presenceEnvelope = smooth(presenceEnvelope, towards: presencePeak,
                                  attack: 0.65, release: 0.18)
        bassAverage += 0.04 * (bassEnvelope - bassAverage)
        midAverage += 0.04 * (midEnvelope - midAverage)
        presenceAverage += 0.04 * (presenceEnvelope - presenceAverage)

        let bassOnset = isOnset(level: bassEnvelope, average: bassAverage, cooldown: &bassCooldown)
        let midOnset = isOnset(level: midEnvelope, average: midAverage, cooldown: &midCooldown)
        let presenceOnset = isOnset(level: presenceEnvelope, average: presenceAverage,
                                    cooldown: &presenceCooldown)

        return TactileFrame(
            bass: shape(bassEnvelope),
            mid: shape(midEnvelope),
            high: shape(presenceEnvelope),
            bassOnset: bassOnset,
            midOnset: midOnset,
            highOnset: presenceOnset)
    }

    private func smooth(_ current: Float, towards target: Float,
                        attack: Float, release: Float) -> Float {
        let coefficient = target > current ? attack : release
        return current + coefficient * (target - current)
    }

    private func isOnset(level: Float, average: Float,
                         cooldown: inout Int) -> Bool {
        if cooldown > 0 {
            cooldown -= 1
            return false
        }
        guard level > Self.noiseFloor else { return false }
        guard level > average * Self.onsetRatio + Self.noiseFloor else { return false }
        cooldown = Self.onsetCooldownBatches
        return true
    }

    /// Envelope to perceptual 0…1. The square root is a cheap stand-in for the
    /// loudness curve and keeps quiet passages from vanishing into the noise
    /// floor of the actuator.
    private func shape(_ value: Float) -> Float {
        guard value > Self.noiseFloor else { return 0 }
        return min(1, sqrt(value * 1.6))
    }
}
