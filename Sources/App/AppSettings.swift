//
//  AppSettings.swift
//  EarthboundWrapper
//
//  Everything the player can change, in one observable place, persisted as a
//  single dictionary.
//
//  The core-option values live here too, stored as the raw key/value strings the
//  core asks for. Keeping them in the same store as everything else means there is
//  exactly one format to migrate, and the Settings screen can treat a snes9x
//  option as just another preference with a known set of values.
//

import Foundation
import Observation

@MainActor
@Observable
final class AppSettings {
    // MARK: - Haptics

    var hapticsEnabled: Bool { didSet { persist() } }
    /// Master gain on both the rumble and the taps.
    var hapticIntensity: Double { didSet { persist() } }
    /// How much of the low band becomes rumble. The one that matters most.
    var hapticBassGain: Double { didSet { persist() } }
    /// How much of the mid and high bands does.
    var hapticTrebleGain: Double { didSet { persist() } }
    /// Gain on taps detected in the mix.
    var hapticTransientGain: Double { didSet { persist() } }
    /// Taps on button presses and stick snaps.
    var controlFeedback: Bool { didSet { persist() } }
    /// Taps on stick direction changes specifically.
    var directionTicks: Bool { didSet { persist() } }
    /// The whole audio-reactive path. Off leaves control feedback intact.
    var audioReactiveHaptics: Bool { didSet { persist() } }

    // MARK: - Audio

    var volume: Double { didSet { persist() } }

    // MARK: - Controls

    /// Produce diagonals. Off gives a strict four-way stick.
    var stickDiagonals: Bool { didSet { persist() } }
    /// Opacity of the on-screen controls, 0.3…1.
    var controlOpacity: Double { didSet { persist() } }

    // MARK: - Core options

    /// Only the options the player has actually changed; anything absent falls
    /// back to the core's own default. Storing just the differences means a core
    /// re-pin that changes a default does not silently inherit our stale copy.
    private(set) var coreOptionValues: [String: String] { didSet { persist() } }

    // MARK: - Storage

    private static let storageKey = "app.settings.v1"

    init() {
        let stored = UserDefaults.standard.dictionary(forKey: Self.storageKey) ?? [:]
        hapticsEnabled = stored["hapticsEnabled"] as? Bool ?? true
        hapticIntensity = stored["hapticIntensity"] as? Double ?? 0.75
        hapticBassGain = stored["hapticBassGain"] as? Double ?? 1.0
        hapticTrebleGain = stored["hapticTrebleGain"] as? Double ?? 0.5
        hapticTransientGain = stored["hapticTransientGain"] as? Double ?? 0.7
        controlFeedback = stored["controlFeedback"] as? Bool ?? true
        directionTicks = stored["directionTicks"] as? Bool ?? true
        audioReactiveHaptics = stored["audioReactiveHaptics"] as? Bool ?? true
        volume = stored["volume"] as? Double ?? 0.9
        stickDiagonals = stored["stickDiagonals"] as? Bool ?? true
        controlOpacity = stored["controlOpacity"] as? Double ?? 0.85
        coreOptionValues = stored["coreOptionValues"] as? [String: String] ?? [:]
    }

    private func persist() {
        UserDefaults.standard.set([
            "hapticsEnabled": hapticsEnabled,
            "hapticIntensity": hapticIntensity,
            "hapticBassGain": hapticBassGain,
            "hapticTrebleGain": hapticTrebleGain,
            "hapticTransientGain": hapticTransientGain,
            "controlFeedback": controlFeedback,
            "directionTicks": directionTicks,
            "audioReactiveHaptics": audioReactiveHaptics,
            "volume": volume,
            "stickDiagonals": stickDiagonals,
            "controlOpacity": controlOpacity,
            "coreOptionValues": coreOptionValues,
        ] as [String: Any], forKey: Self.storageKey)
    }

    // MARK: - Derived

    var hapticSettings: HapticConductor.Settings {
        HapticConductor.Settings(
            isEnabled: hapticsEnabled,
            intensity: hapticIntensity,
            bassGain: hapticBassGain,
            trebleGain: hapticTrebleGain,
            transientGain: hapticTransientGain,
            buttonFeedback: controlFeedback,
            directionTicks: directionTicks,
            audioReactive: audioReactiveHaptics)
    }

    /// The value the core should see for a key: the player's choice, or nil to let
    /// the core use its own default.
    func coreOptionValue(for key: String) -> String? {
        coreOptionValues[key]
    }

    func setCoreOptionValue(_ value: String, for key: String) {
        var updated = coreOptionValues
        if let descriptor = Snes9xOptions.descriptor(for: key),
           descriptor.defaultValue == value {
            // Store the default as an absence, so re-pinning the core to a
            // revision with a new default actually takes effect.
            updated.removeValue(forKey: key)
        } else {
            updated[key] = value
        }
        coreOptionValues = updated
    }

    func resetCoreOptions() {
        coreOptionValues = [:]
    }

    // MARK: - Presets

    /// Every haptic knob at once.
    ///
    /// Presets are stored as data rather than as code that assigns to the
    /// properties, so "apply a preset" and "which preset is this?" read from the
    /// same numbers and cannot drift apart.
    struct HapticValues: Equatable, Sendable {
        var enabled: Bool
        var intensity: Double
        var bass: Double
        var treble: Double
        var transient: Double
        var controlFeedback: Bool
        var directionTicks: Bool
        var audioReactive: Bool

        var settings: HapticConductor.Settings {
            HapticConductor.Settings(isEnabled: enabled,
                                     intensity: intensity,
                                     bassGain: bass,
                                     trebleGain: treble,
                                     transientGain: transient,
                                     buttonFeedback: controlFeedback,
                                     directionTicks: directionTicks,
                                     audioReactive: audioReactive)
        }
    }

    enum HapticPreset: String, CaseIterable, Identifiable, Sendable {
        case off, subtle, standard, heavy

        var id: String { rawValue }

        var label: String {
            switch self {
            case .off: return "Off"
            case .subtle: return "Subtle"
            case .standard: return "Standard"
            case .heavy: return "Heavy"
            }
        }

        var detail: String {
            switch self {
            case .off: return "No haptics at all."
            case .subtle: return "A barely-there rumble, with ticks on direction changes."
            case .standard: return "The soundtrack drives the rumble; the controls tick."
            case .heavy: return "Everything at full strength."
            }
        }

        var values: HapticValues {
            switch self {
            case .off:
                return HapticValues(enabled: false, intensity: 0.75, bass: 1, treble: 0.5,
                                    transient: 0.7, controlFeedback: true,
                                    directionTicks: true, audioReactive: true)
            case .subtle:
                return HapticValues(enabled: true, intensity: 0.4, bass: 0.6, treble: 0.2,
                                    transient: 0.35, controlFeedback: true,
                                    directionTicks: true, audioReactive: true)
            case .standard:
                return HapticValues(enabled: true, intensity: 0.75, bass: 1, treble: 0.5,
                                    transient: 0.7, controlFeedback: true,
                                    directionTicks: true, audioReactive: true)
            case .heavy:
                return HapticValues(enabled: true, intensity: 1, bass: 1, treble: 0.9,
                                    transient: 1, controlFeedback: true,
                                    directionTicks: true, audioReactive: true)
            }
        }
    }

    var hapticValues: HapticValues {
        HapticValues(enabled: hapticsEnabled,
                     intensity: hapticIntensity,
                     bass: hapticBassGain,
                     treble: hapticTrebleGain,
                     transient: hapticTransientGain,
                     controlFeedback: controlFeedback,
                     directionTicks: directionTicks,
                     audioReactive: audioReactiveHaptics)
    }

    /// Which preset the current values correspond to, or nil for a custom mix.
    /// Computed rather than stored, so the sliders and the picker can never
    /// disagree about what is selected.
    var matchingPreset: HapticPreset? {
        HapticPreset.allCases.first { $0.values == hapticValues }
    }

    func apply(_ preset: HapticPreset) {
        let values = preset.values
        hapticsEnabled = values.enabled
        hapticIntensity = values.intensity
        hapticBassGain = values.bass
        hapticTrebleGain = values.treble
        hapticTransientGain = values.transient
        controlFeedback = values.controlFeedback
        directionTicks = values.directionTicks
        audioReactiveHaptics = values.audioReactive
    }
}
