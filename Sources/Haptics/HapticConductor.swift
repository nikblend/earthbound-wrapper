//
//  HapticConductor.swift
//  EarthboundWrapper
//
//  The Taptic Engine as a game-feel device rather than a notification buzzer.
//
//  Three output paths:
//
//    rumble      a single looping continuous player whose intensity and
//                sharpness are pushed every frame from the audio bands. This is
//                the one that makes EarthBound feel like it has weight: a bass
//                hit in the soundtrack becomes a thump in your hands.
//
//    transients  short taps fired by onsets in the mix, and by button presses.
//                Kept in a small round-robin pool so two taps close together do
//                not cut each other off.
//
//    ticks       a deliberately sharp tap when the stick crosses into a new
//                direction. Cheap to do, and it is the thing that makes a
//                floating analogue stick feel like it has detents instead of
//                being a slippery dot.
//
//  Everything is best-effort. Haptics are unavailable on some hardware, the
//  engine can be torn down when the app backgrounds, and none of that should
//  ever interrupt a game, so every call site is failure-tolerant.
//

import CoreHaptics
import Foundation
import os

@MainActor
final class HapticConductor {
    /// Tunables, surfaced in Settings.
    struct Settings: Equatable, Sendable {
        var isEnabled = true
        /// Master gain on everything below.
        var intensity: Double = 0.75
        /// How much of the low band reaches the continuous rumble.
        var bassGain: Double = 1.0
        /// How much of the mid/high band does. SNES percussion and PSI effects
        /// live here, so it is worth having even at the cost of some buzz.
        var trebleGain: Double = 0.5
        /// Gain on audio-detected taps.
        var transientGain: Double = 0.7
        /// Tap when a button is pressed. Distinct from `directionTicks` because
        /// some players want the controls silent and the game loud.
        var buttonFeedback = true
        /// Tap when the stick snaps to a new direction.
        var directionTicks = true
        /// Turn the whole audio-reactive path off and keep only control feedback.
        var audioReactive = true

        static let standard = Settings()
    }

    private(set) var settings = Settings.standard

    private let log = Logger(subsystem: "dev.nikan.earthbound", category: "haptics")

    private var engine: CHHapticEngine?
    private var isEngineRunning = false
    private var supportsHaptics = false

    /// Diagnostics, for the player rather than for the game.
    ///
    /// Haptics that stop are the hardest thing in this app to describe from memory,
    /// because the two possible authors -- the system and this file -- feel identical
    /// from the outside. These are shown in Settings so the question can be answered by
    /// looking instead of by guessing.
    private(set) var restartCount = 0
    private(set) var lastStopDescription: String?

    /// Throttles restart attempts. `apply` runs at frame rate, and a restart that
    /// cannot succeed would otherwise be attempted sixty times a second.
    private var lastRestartAttempt: TimeInterval = 0
    private static let restartCooldown: TimeInterval = 2

    /// Looping continuous player carrying the rumble. Modulated in place.
    private var rumblePlayer: CHHapticAdvancedPatternPlayer?
    private var isRumbleActive = false
    /// Batches of near-silence, used to decide when to park the player.
    private var silenceRun = 0
    private var lastRumbleIntensity: Float = -1

    /// Global cap on audio-driven taps per second. The per-band detectors allow
    /// roughly 36 Hz combined; anything past about 16 Hz stops reading as
    /// separate events and just feels like noise.
    private var lastTransientTime: TimeInterval = 0
    private let minimumTransientInterval: TimeInterval = 1.0 / 16.0

    /// Below this the continuous player is paused, because a looping haptic
    /// player with zero intensity still costs power.
    private static let silenceThreshold: Float = 0.012
    /// Batches of silence (≈1/60 s each) before parking the player.
    private static let silenceBatchesBeforeParking = 12

    // MARK: - Lifecycle

    func start() {
        guard settings.isEnabled else { return }
        supportsHaptics = CHHapticEngine.capabilitiesForHardware().supportsHaptics
        guard supportsHaptics else {
            log.info("haptics unavailable on this hardware")
            return
        }
        // Idempotent on purpose. This is called on every return to the foreground, and
        // building a second engine each time used to leave the previous one to be
        // released mid-loop while a player still referenced it.
        guard engine == nil else {
            if !isEngineRunning { restartEngine() }
            return
        }
        guard let engine = makeEngine() else { return }
        self.engine = engine
        do {
            try engine.start()
            isEngineRunning = true
            buildRumblePlayer()
        } catch {
            log.error("haptic engine failed to start: \(error.localizedDescription)")
            isEngineRunning = false
        }
    }

    func stop() {
        try? rumblePlayer?.stop(atTime: CHHapticTimeImmediate)
        discardEngine()
    }

    /// Stops and forgets the engine.
    ///
    /// The handlers cannot be uninstalled -- `stoppedHandler` and `resetHandler` are
    /// non-optional stored properties -- so a stop this file causes looks exactly like
    /// one the system caused. Both handlers therefore check that they are still talking
    /// about the current engine before acting, which is what stops an intentional
    /// shutdown from resurrecting what it just closed.
    private func discardEngine() {
        engine?.stop()
        engine = nil
        rumblePlayer = nil
        isRumbleActive = false
        isEngineRunning = false
        silenceRun = 0
        lastRumbleIntensity = -1
    }

    func update(settings newSettings: Settings) {
        let wasEnabled = settings.isEnabled
        settings = newSettings
        if !newSettings.isEnabled {
            stop()
        } else if !wasEnabled {
            start()
        }
    }

    private func makeEngine() -> CHHapticEngine? {
        do {
            let engine = try CHHapticEngine()
            // We synthesise our own audio; the engine must not add any.
            engine.playsHapticsOnly = true
            // The system stops the engine on backgrounding and after a media
            // services reset. Both are recoverable, and a game that silently
            // loses its haptics for the rest of the session is worse than one
            // that spends a few milliseconds restarting.
            // Both closures capture the engine weakly: it owns the closure, so a strong
            // capture would be a cycle, and the reference is only needed to identify
            // which engine is talking.
            engine.stoppedHandler = { [weak self, weak engine] reason in
                guard let engine else { return }
                Task { @MainActor in
                    self?.handleStopped(reason, from: engine)
                }
            }
            engine.resetHandler = { [weak self, weak engine] in
                guard let engine else { return }
                Task { @MainActor in
                    self?.handleReset(from: engine)
                }
            }
            return engine
        } catch {
            log.error("could not create haptic engine: \(error.localizedDescription)")
            return nil
        }
    }

    /// The system stopped the engine. It does that for backgrounding, for a call, and
    /// when it wants the haptics hardware for something else.
    ///
    /// This used to only record the fact, which is why haptics could die and stay dead
    /// until the next return to the foreground. Recovering here is what heals it. No
    /// attempt is made to distinguish backgrounding from the rest: a restart while
    /// suspended simply fails, is throttled, and is retried by `apply` on the next
    /// frame after the app is back.
    private func handleStopped(_ reason: CHHapticEngine.StoppedReason, from engine: CHHapticEngine) {
        // Not our engine any more means this stop was caused by `discardEngine` or by a
        // rebuild, and reviving it would be undoing what the caller just asked for.
        guard engine === self.engine else { return }
        isEngineRunning = false
        lastStopDescription = String(describing: reason)
        log.info("haptic engine stopped (\(String(describing: reason), privacy: .public))")
        guard settings.isEnabled else { return }
        restartEngine()
    }

    /// Brings a stopped engine back on the instance already held.
    private func restartEngine() {
        guard settings.isEnabled, let engine else { return }

        let now = Date.timeIntervalSinceReferenceDate
        guard now - lastRestartAttempt >= Self.restartCooldown else { return }
        lastRestartAttempt = now

        do {
            try engine.start()
            isEngineRunning = true
            // A new player has to be built: the previous one belonged to the stopped
            // engine and cannot be resumed. Restoring only the engine and leaving the old
            // player in place is precisely the half-recovery this is fixing.
            buildRumblePlayer()
            restartCount += 1
            log.info("haptic engine restarted")
        } catch {
            log.error("haptic engine restart failed: \(error.localizedDescription)")
            isEngineRunning = false
        }
    }

    /// The media services daemon restarted, which invalidates the engine and every
    /// player made from it. Apple's guidance is to build a new engine rather than reuse
    /// the old one.
    private func handleReset(from engine: CHHapticEngine) {
        guard engine === self.engine, settings.isEnabled else { return }
        log.info("haptic engine reset; rebuilding")
        discardEngine()
        lastRestartAttempt = 0
        start()
    }

    /// One line about the haptic engine, for the Settings screen.
    var diagnostics: String {
        guard settings.isEnabled else { return "Off" }
        guard CHHapticEngine.capabilitiesForHardware().supportsHaptics else {
            return "Unsupported on this hardware"
        }
        if isEngineRunning {
            return restartCount == 0 ? "Running" : "Running · recovered \(restartCount)×"
        }
        if let lastStopDescription {
            return "Stopped · \(lastStopDescription)"
        }
        return "Not running"
    }

    // MARK: - Continuous rumble

    private func buildRumblePlayer() {
        guard let engine else { return }
        // A long continuous event driven entirely by `sendParameters`. The
        // duration is a ceiling rather than a plan: the player loops, and we
        // rebuild it if the engine is ever recycled.
        let event = CHHapticEvent(
            eventType: .hapticContinuous,
            parameters: [
                CHHapticEventParameter(parameterID: .hapticIntensity, value: 0),
                CHHapticEventParameter(parameterID: .hapticSharpness, value: 0.4),
            ],
            relativeTime: 0,
            duration: 1800)

        do {
            let pattern = try CHHapticPattern(events: [event], parameters: [])
            let player = try engine.makeAdvancedPlayer(with: pattern)
            player.loopEnabled = true
            rumblePlayer = player
            // Reset the modulation state alongside the player.
            //
            // Without this, a player is created while `isRumbleActive` still claims the
            // *previous* one was running, so `updateRumble` only pushes parameters at a
            // player that was never started. The rumble then stays silent until a quiet
            // passage parks it and the next loud frame restarts it -- haptics that stop
            // and then, some while later, start back up.
            isRumbleActive = false
            lastRumbleIntensity = -1
            silenceRun = 0
        } catch {
            log.error("could not build rumble player: \(error.localizedDescription)")
        }
    }

    /// Feeds one batch of audio analysis into the continuous output and fires
    /// any taps the analysis found.
    func apply(_ frame: TactileFrame) {
        guard settings.isEnabled, settings.audioReactive else { return }

        // Recovery is attempted here as well as in `stoppedHandler`, because that
        // handler can fire while the app is on its way to the background, where a
        // restart cannot succeed -- and nothing else would try again until the next
        // foreground.
        guard isEngineRunning else {
            restartEngine()
            return
        }

        // Bass dominates the rumble; the upper bands add sharpness rather than
        // intensity, which is what stops a hi-hat from feeling like a kick drum.
        let weighted = Float(settings.bassGain) * frame.bass
            + Float(settings.trebleGain) * 0.35 * (frame.mid + frame.high)
        let intensity = min(1, weighted * Float(settings.intensity))
        let sharpness = min(1, max(0.15, 0.25 + frame.high * 0.75))

        updateRumble(intensity: intensity, sharpness: sharpness)

        let transientGain = Float(settings.transientGain * settings.intensity)
        if frame.bassOnset {
            fireTransient(intensity: 0.9 * transientGain, sharpness: 0.25)
        }
        if frame.midOnset {
            fireTransient(intensity: 0.6 * transientGain, sharpness: 0.5)
        }
        if frame.highOnset {
            fireTransient(intensity: 0.45 * transientGain, sharpness: 0.85)
        }
    }

    private func updateRumble(intensity: Float, sharpness: Float) {
        if intensity <= Self.silenceThreshold {
            silenceRun += 1
            if isRumbleActive && silenceRun > Self.silenceBatchesBeforeParking {
                // Park it. Leaving a player running at zero intensity still
                // costs, and the restart path below sets its own intensity, so
                // nothing is lost by not preserving the pattern's position.
                try? rumblePlayer?.stop(atTime: CHHapticTimeImmediate)
                isRumbleActive = false
                lastRumbleIntensity = -1
            }
            return
        }
        silenceRun = 0

        guard let rumblePlayer else { return }
        if !isRumbleActive {
            // Restart at the target intensity rather than ramping up from zero,
            // so the first hit after a quiet spell lands at full strength.
            try? setRumbleParameters(on: rumblePlayer, intensity: 0, sharpness: sharpness)
            do {
                try rumblePlayer.start(atTime: CHHapticTimeImmediate)
                isRumbleActive = true
            } catch {
                log.error("rumble start failed: \(error.localizedDescription)")
                // A player that will not start usually means the engine underneath it is
                // gone. Recovering here is the difference between losing the rumble for
                // the session and losing it for one frame.
                isEngineRunning = false
                restartEngine()
                return
            }
        }

        // Skip redundant sends: at 60 Hz this is most of them during a sustained
        // note, and each one crosses into the haptic server.
        guard abs(intensity - lastRumbleIntensity) > 0.01 else { return }
        try? setRumbleParameters(on: rumblePlayer, intensity: intensity, sharpness: sharpness)
        lastRumbleIntensity = intensity
    }

    private func setRumbleParameters(on player: CHHapticAdvancedPatternPlayer,
                                     intensity: Float, sharpness: Float) throws {
        let parameters = [
            CHHapticDynamicParameter(parameterID: .hapticIntensityControl,
                                     value: intensity, relativeTime: 0),
            CHHapticDynamicParameter(parameterID: .hapticSharpnessControl,
                                     value: sharpness, relativeTime: 0),
        ]
        try player.sendParameters(parameters, atTime: CHHapticTimeImmediate)
    }

    // MARK: - Discrete taps

    /// Builds and plays one tap. A `CHHapticPatternPlayer` bakes its parameters
    /// in, so there is nothing to reuse across taps of different strengths;
    /// constructing a single-event pattern costs microseconds, well inside a
    /// frame, and keeps this code free of pooling states to get wrong.
    private func playTap(intensity: Float, sharpness: Float) {
        guard isEngineRunning, let engine else { return }
        guard intensity > 0.02 else { return }
        guard let player = try? makeTransientPlayer(engine: engine,
                                                   intensity: min(1, intensity),
                                                   sharpness: min(1, max(0, sharpness)))
        else { return }
        try? player.start(atTime: CHHapticTimeImmediate)
    }

    private func makeTransientPlayer(engine: CHHapticEngine, intensity: Float,
                                     sharpness: Float) throws -> CHHapticPatternPlayer {
        let event = CHHapticEvent(
            eventType: .hapticTransient,
            parameters: [
                CHHapticEventParameter(parameterID: .hapticIntensity, value: intensity),
                CHHapticEventParameter(parameterID: .hapticSharpness, value: sharpness),
            ],
            relativeTime: 0)
        let pattern = try CHHapticPattern(events: [event], parameters: [])
        return try engine.makePlayer(with: pattern)
    }

    /// Audio-driven tap, rate limited so a busy mix does not turn into a buzz.
    private func fireTransient(intensity: Float, sharpness: Float) {
        guard settings.isEnabled, isEngineRunning else { return }
        let now = Date.timeIntervalSinceReferenceDate
        guard now - lastTransientTime >= minimumTransientInterval else { return }
        lastTransientTime = now
        playTap(intensity: intensity, sharpness: sharpness)
    }

    // MARK: - Audition

    /// Plays a short stand-in for what the current settings feel like.
    ///
    /// Building this out of the same primitives the game uses — a continuous swell
    /// and a couple of taps — means the audition cannot drift away from the real
    /// behaviour the way a hand-tuned demo pattern would.
    func audition() {
        guard settings.isEnabled else { return }
        // The engine is normally started with a game, but the button is also offered
        // from Settings without one running.
        if !isEngineRunning { start() }
        guard isEngineRunning, let engine else { return }

        let gain = Float(settings.intensity)
        let swell = CHHapticEvent(
            eventType: .hapticContinuous,
            parameters: [
                CHHapticEventParameter(parameterID: .hapticIntensity, value: min(1, 0.85 * gain)),
                CHHapticEventParameter(parameterID: .hapticSharpness, value: 0.3),
            ],
            relativeTime: 0,
            duration: 0.45)

        // Two taps at different sharpness, mimicking the mid and high bands, so a
        // player can hear with their hands which slider does what.
        let thump = CHHapticEvent(
            eventType: .hapticTransient,
            parameters: [
                CHHapticEventParameter(parameterID: .hapticIntensity,
                                       value: min(1, 0.9 * gain)),
                CHHapticEventParameter(parameterID: .hapticSharpness, value: 0.25),
            ],
            relativeTime: 0.05)
        let tick = CHHapticEvent(
            eventType: .hapticTransient,
            parameters: [
                CHHapticEventParameter(parameterID: .hapticIntensity,
                                       value: min(1, 0.5 * gain)),
                CHHapticEventParameter(parameterID: .hapticSharpness, value: 0.95),
            ],
            relativeTime: 0.35)

        do {
            let pattern = try CHHapticPattern(events: [swell, thump, tick], parameters: [])
            let player = try engine.makePlayer(with: pattern)
            try player.start(atTime: CHHapticTimeImmediate)
        } catch {
            log.error("audition failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Control feedback

    /// A crisp tap for a button press. Deliberately sharper and shorter than the
    /// audio-driven taps, so it reads as "you pressed something" rather than as
    /// part of the soundtrack.
    func buttonPressed() {
        guard settings.isEnabled, settings.buttonFeedback else { return }
        let gain = Float(settings.intensity)
        fireTransientNow(intensity: 0.55 * gain, sharpness: 0.9)
    }

    /// A firmer tap for a direction change, with a haptic vocabulary:
    ///   · cardinal       short and sharp
    ///   · diagonal       slightly softer, so a corner does not feel like two
    ///                    presses
    ///   · release        a very light one, so you can feel that you let go
    func stickDirectionChanged(to direction: StickDirection) {
        guard settings.isEnabled, settings.directionTicks else { return }
        let gain = Float(settings.intensity)
        if direction.isEmpty {
            fireTransientNow(intensity: 0.22 * gain, sharpness: 0.5)
            return
        }
        let isDiagonal = direction == .upLeft || direction == .upRight
            || direction == .downLeft || direction == .downRight
        fireTransientNow(intensity: (isDiagonal ? 0.42 : 0.6) * gain,
                         sharpness: isDiagonal ? 0.55 : 0.95)
    }

    /// Like `fireTransient`, but bypasses the audio-rate throttle: control
    /// feedback should always be immediate, and the user's own fingers are the
    /// natural rate limiter.
    private func fireTransientNow(intensity: Float, sharpness: Float) {
        playTap(intensity: intensity, sharpness: sharpness)
    }
}
