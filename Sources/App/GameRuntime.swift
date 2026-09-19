//
//  GameRuntime.swift
//  EarthboundWrapper
//
//  Everything that has to exist while a game is running, wired together in one
//  place: the core session, the audio device, the haptic engine, the input state
//  and the on-screen controls.
//
//  They are one object because their lifetimes are identical and their ordering
//  matters. The audio output holds a pointer into the session's ring buffer, so it
//  must be stopped before the session is released; the controls hold the session's
//  input word, so they must not outlive it either. Expressing that as an owner with
//  a single `shutdown()` is the point of this file.
//

import CoreGraphics
import Foundation
import Observation
import UIKit
import os

@MainActor
@Observable
final class GameRuntime {
    let rom: RomDescriptor
    private(set) var session: EmulatorSession
    private(set) var gamepad: GamepadState
    private(set) var controls: TouchControlsModel
    let conductor = HapticConductor()
    let display: DisplaySettings

    /// Non-nil when the core refused the ROM. Surfaced instead of a black screen.
    private(set) var failureMessage: String?
    private(set) var isFastForwarding = false

    /// The option values the running core was started with. Compared against the
    /// current settings to tell the player that a change needs a restart.
    private let installedCoreOptions: [String: String]

    private var audio: AudioOutput?
    private var didShutdown = false
    private var audioRetryCount = 0
    private var settings: AppSettings
    private let log = Logger(subsystem: "dev.nikan.earthbound", category: "runtime")

    init(rom: RomDescriptor,
         settings: AppSettings,
         display: DisplaySettings,
         size: CGSize,
         safeArea: EdgeInsets) {
        self.rom = rom
        self.settings = settings
        self.display = display
        installedCoreOptions = settings.coreOptionValues

        let session = EmulatorSession(rom: rom,
                                      initialOptionValues: settings.coreOptionValues)
        session.targetRefreshRate = Self.screenRefreshRate()
        self.session = session

        let gamepad = GamepadState(input: session.input)
        self.gamepad = gamepad
        controls = TouchControlsModel(gamepad: gamepad, size: size, safeArea: safeArea)
        controls.allowsDiagonals = settings.stickDiagonals

        applyControlFeedback()
    }

    // MARK: - Lifecycle

    func start() {
        session.start()

        // snes9x always reports 32040 Hz. Building the output at the core's nominal
        // rate lets audio start immediately instead of waiting for the core to
        // finish loading, and the engine's converter covers the hardware rate.
        let output = AudioOutput(ring: session.audioRing, sampleRate: session.avInfo.sampleRate)
        output.volume = Float(settings.volume)
        do {
            try output.start()
            audio = output
        } catch {
            // Not fatal. A silent game is still a game, and a phone with a broken
            // audio route should not refuse to run.
            log.error("audio unavailable: \(error.localizedDescription)")
        }

        conductor.update(settings: settings.hapticSettings)
        conductor.start()

        // Drop the preroll that accumulated while the core was loading, so the game
        // does not open by replaying a second of stale audio.
        eb_ring_clear(session.audioRing)
    }

    /// Saves and tears everything down. Safe to call more than once.
    func shutdown() {
        guard !didShutdown else { return }
        didShutdown = true

        controls.cancelAll()
        // Ordered deliberately: stop the audio device first so it cannot pull from a
        // ring buffer we are about to destroy, then flush the saves while the core
        // is still loaded, then stop the core.
        audio?.stop()
        audio = nil

        if session.isRunning {
            session.flushSRAM()
            session.saveState()
            // Both commands are drained at a frame boundary, so give the emulation
            // thread a moment to act on them before asking it to exit.
            usleep(60_000)
        }
        session.stop()
        conductor.stop()
    }

    func setFastForwarding(_ enabled: Bool) {
        guard enabled != isFastForwarding else { return }
        isFastForwarding = enabled
        session.setFastForwarding(enabled)
    }

    // MARK: - Per-frame

    /// Called after each presented frame, on the main thread.
    ///
    /// This doubles as the heartbeat for the tactile output. Piggy-backing on the
    /// draw loop rather than dispatching from the audio callback means haptics can
    /// never outpace the screen and turn into a queue of late taps.
    func handleFramePresented() {
        if let message = session.lastError?.errorDescription {
            failureMessage = message
        }
        guard !didShutdown else { return }
        retryAudioIfNeeded()
        conductor.apply(session.consumeTactileFrame())
    }

    /// Audio can only fail at first start (route in use, session activation race), so
    /// one retry once the core is definitely running covers the realistic case.
    private func retryAudioIfNeeded() {
        guard audio == nil, audioRetryCount < 1, session.isRunning else { return }
        audioRetryCount += 1
        let output = AudioOutput(ring: session.audioRing, sampleRate: session.avInfo.sampleRate)
        output.volume = Float(settings.volume)
        guard (try? output.start()) != nil else { return }
        audio = output
        log.info("audio recovered on retry")
    }

    // MARK: - Settings

    func apply(settings newSettings: AppSettings) {
        settings = newSettings
        audio?.volume = Float(newSettings.volume)
        conductor.update(settings: newSettings.hapticSettings)
        controls.allowsDiagonals = newSettings.stickDiagonals
        applyControlFeedback()
    }

    /// Routes the input layer's events into the conductor.
    ///
    /// Assigning the callbacks here rather than inside `GamepadState` keeps the input
    /// layer free of any opinion about feedback: it reports what happened, and
    /// something else decides what that should feel like.
    private func applyControlFeedback() {
        gamepad.onButtonPressed = { [weak self] _ in
            self?.conductor.buttonPressed()
        }
        gamepad.onStickDirectionChanged = { [weak self] direction in
            self?.conductor.stickDirectionChanged(to: direction)
        }
    }

    // MARK: - Reading state out

    /// The aspect ratio the picture should be drawn at, as the core reports it.
    var displayAspect: Double { session.avInfo.displayAspect }

    var displaySnapshot: DisplaySnapshot { display.snapshot }

    /// True when a core option the player changed is only read at load time, so the
    /// running core is still using the old value.
    var coreOptionsNeedReload: Bool {
        let changed = Set(installedCoreOptions.keys).union(settings.coreOptionValues.keys)
        return changed.contains { key in
            installedCoreOptions[key] != settings.coreOptionValues[key]
        }
    }

    var volume: Double {
        get { settings.volume }
        set {
            settings.volume = newValue
            audio?.volume = Float(newValue)
        }
    }

    /// The screen's refresh rate, which the core uses to pace its own frame limiter.
    private static func screenRefreshRate() -> Float {
        let windowScene = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first
        let rate = windowScene?.screen.maximumFramesPerSecond ?? 60
        return Float(rate)
    }
}
