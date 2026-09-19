//
//  LibrarySettingsSheet.swift
//  EarthboundWrapper
//
//  Defaults that apply to every game: how it should feel, how loud it should be,
//  and what the core should do unless a game overrides it.
//
//  The same haptic controls appear in-game; this screen exists so a player can dial
//  in the feel before starting, and so the core's option vocabulary is visible
//  without a game loaded.
//

import SwiftUI

struct LibrarySettingsSheet: View {
    @Bindable var settings: AppSettings

    /// Created on first use rather than as a `@State` initial value: the conductor
    /// is main-actor bound, and a default initialiser does not run on the main actor.
    @State private var hapticConductor: HapticConductor?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                feelSection
                controlsSection
                audioSection
                coreDefaultsSection
                aboutSection
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .onAppear {
            if hapticConductor == nil { hapticConductor = HapticConductor() }
        }
        .onDisappear { hapticConductor?.stop() }
    }

    // MARK: - Sections

    private var feelSection: some View {
        Section {
            Picker("Feel", selection: presetBinding) {
                ForEach(AppSettings.HapticPreset.allCases) { preset in
                    Text(preset.label).tag(preset)
                }
            }
            .pickerStyle(.segmented)

            Text(settings.matchingPreset?.detail ?? "Custom mix.")
                .font(.caption)
                .foregroundStyle(.secondary)

            Button {
                hapticConductor?.update(settings: settings.hapticSettings)
                hapticConductor?.audition()
            } label: {
                Label("Feel the current settings", systemImage: "hand.tap")
            }
            .disabled(!settings.hapticsEnabled)

            if settings.hapticsEnabled {
                LabelledSlider(title: "Intensity",
                               value: $settings.hapticIntensity,
                               range: 0...1,
                               readout: "\(Int(settings.hapticIntensity * 100))%")
                LabelledSlider(title: "Bass",
                               value: $settings.hapticBassGain,
                               range: 0...1.5,
                               readout: "\(Int(settings.hapticBassGain * 100))%")
                LabelledSlider(title: "Treble",
                               value: $settings.hapticTrebleGain,
                               range: 0...1.5,
                               readout: "\(Int(settings.hapticTrebleGain * 100))%")
                LabelledSlider(title: "Hits",
                               value: $settings.hapticTransientGain,
                               range: 0...1.5,
                               readout: "\(Int(settings.hapticTransientGain * 100))%")

                Toggle("React to the soundtrack", isOn: $settings.audioReactiveHaptics)
                Toggle("Button feedback", isOn: $settings.controlFeedback)
                Toggle("Direction ticks", isOn: $settings.directionTicks)
            }
        } header: {
            Text("Haptics")
        } footer: {
            Text("Only devices with a Taptic Engine can do this. The rumble is driven by the game's audio: bass becomes a continuous thump, sharp sounds become taps, and the stick knocks once each time it snaps to a new direction.")
        }
    }

    private var controlsSection: some View {
        Section {
            LabelledSlider(title: "Control opacity",
                           value: $settings.controlOpacity,
                           range: 0.3...1,
                           readout: "\(Int(settings.controlOpacity * 100))%")
            Toggle("Allow diagonals", isOn: $settings.stickDiagonals)
        } header: {
            Text("Touch controls")
        } footer: {
            Text("The stick is planted wherever you first touch the left side of the screen, and the nub follows your finger exactly while the direction it reports snaps to one of eight sectors.")
        }
    }

    private var audioSection: some View {
        Section {
            LabelledSlider(title: "Volume",
                           value: $settings.volume,
                           range: 0...1,
                           readout: "\(Int(settings.volume * 100))%")
        } header: {
            Text("Audio")
        }
    }

    private var coreDefaultsSection: some View {
        Section {
            ForEach(CoreOptionCatalog.groups) { group in
                ForEach(group.keys, id: \.self) { key in
                    if let descriptor = Snes9xOptions.descriptor(for: key) {
                        Picker(descriptor.label, selection: coreOptionBinding(descriptor)) {
                            ForEach(descriptor.values, id: \.self) { value in
                                Text(value).tag(value)
                            }
                        }
                    }
                }
            }
            Button(role: .destructive) {
                settings.resetCoreOptions()
            } label: {
                Label("Reset all core options", systemImage: "arrow.uturn.backward")
            }
        } header: {
            Text("Emulator defaults")
        } footer: {
            Text("These are the emulator core's own options. Anything left at its default is not stored, so a future update to the core takes effect.")
        }
    }

    private var aboutSection: some View {
        Section {
            LabeledContent("Emulator", value: RetroEnvironment.shared.systemInfo().libraryName)
            LabeledContent("Core version",
                           value: RetroEnvironment.shared.systemInfo().libraryVersion)
            LabeledContent("libretro API", value: String(Libretro.apiVersion))
            LabeledContent("Machine", value: "Super Nintendo / Super Famicom")
        } header: {
            Text("About")
        } footer: {
            Text("This app is a frontend. The emulation itself is snes9x, an open-source Super Nintendo emulator, statically linked into this build. It ships with no games.")
        }
    }

    private var presetBinding: Binding<AppSettings.HapticPreset> {
        Binding(get: { settings.matchingPreset ?? .standard },
                set: { settings.apply($0) })
    }

    private func coreOptionBinding(_ descriptor: CoreOptionDescriptor) -> Binding<String> {
        Binding(get: { settings.coreOptionValue(for: descriptor.key) ?? descriptor.defaultValue },
                set: { settings.setCoreOptionValue($0, for: descriptor.key) })
    }
}
