//
//  GameSettingsSheet.swift
//  EarthboundWrapper
//
//  Settings, opened over the running game so the display changes can be judged
//  against the actual picture rather than from memory.
//
//  A note on core options: every picker here writes a raw libretro key/value pair,
//  and snes9x only reads some of them when it loads a game. Rather than let a
//  change silently do nothing, options known to be load-time only are marked, and
//  the sheet offers to restart the game when one of them has changed.
//

import SwiftUI

struct GameSettingsSheet: View {
    let runtime: GameRuntime
    @Bindable var settings: AppSettings
    @Bindable var display: DisplaySettings
    let onRestart: () -> Void
    let onQuit: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var showResetConfirmation = false
    /// The slot a load has been requested for, waiting on confirmation. Loading is
    /// the one savestate action that throws work away, so it is the one that asks.
    @State private var pendingLoad: SaveSlot?

    var body: some View {
        NavigationStack {
            Form {
                stateSection
                displaySection
                controlsSection
                hapticsSection
                audioSection
                coreOptionsSections
                librarySection
            }
            .navigationTitle(runtime.rom.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .confirmationDialog("Reset the console?", isPresented: $showResetConfirmation) {
                Button("Reset", role: .destructive) { runtime.session.reset() }
            } message: {
                Text("This is the SNES reset button: any unsaved progress in the game is lost, but your SRAM saves are kept.")
            }
            .confirmationDialog("Load this savestate?",
                                isPresented: Binding(get: { pendingLoad != nil },
                                                     set: { if !$0 { pendingLoad = nil } }),
                                titleVisibility: .visible) {
                if let slot = pendingLoad {
                    Button("Load \(slot.title)", role: .destructive) {
                        runtime.loadState(from: slot)
                        pendingLoad = nil
                        dismiss()
                    }
                }
                Button("Cancel", role: .cancel) { pendingLoad = nil }
            } message: {
                Text("Progress since that state was saved will be lost.")
            }
        }
    }

    // MARK: - State

    private var stateSection: some View {
        Group {
            Section {
                Button {
                    runtime.saveState(to: .manual(settings.quickSaveSlot))
                } label: {
                    Label("Save to \(SaveSlot.manual(settings.quickSaveSlot).title)",
                          systemImage: "square.and.arrow.down")
                }

                Picker("Save button writes to", selection: $settings.quickSaveSlot) {
                    ForEach(SaveSlot.manual) { slot in
                        Text(slot.title).tag(slot.id)
                    }
                }
            } header: {
                Text("Savestates")
            } footer: {
                Text("A savestate is a snapshot of the console taken mid-frame, so it can be made anywhere — no need to find a phone to call Dad. The SAVE button in the game writes to the slot chosen above.")
            }

            Section {
                ForEach(runtime.saveSlots) { info in
                    slotRow(info)
                }
            } header: {
                Text("Slots")
            } footer: {
                Text("The automatic slot is rewritten whenever the app leaves the foreground, which is what a game resumes from. The numbered slots change only when you save to them. Battery saves are kept alongside them.")
            }

            Section {
                Button(role: .destructive) {
                    showResetConfirmation = true
                } label: {
                    Label("Reset console", systemImage: "arrow.counterclockwise")
                }
            }
        }
    }

    /// One slot: what is in it, and the two things you can do about it. Deleting is a
    /// swipe rather than a third button, because it is the rare one.
    private func slotRow(_ info: SaveSlotInfo) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(info.slot.title)
                Text(info.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 4)
            Button("Save") {
                runtime.saveState(to: info.slot)
            }
            .buttonStyle(.borderless)
            if !info.isEmpty {
                Button("Load") {
                    pendingLoad = info.slot
                }
                .buttonStyle(.borderless)
                .tint(.accentColor)
            }
        }
        .swipeActions(edge: .trailing) {
            if !info.isEmpty {
                Button(role: .destructive) {
                    runtime.eraseState(in: info.slot)
                } label: {
                    Label("Delete", systemImage: "trash")
                }
            }
        }
    }

    // MARK: - Display

    private var displaySection: some View {
        Section {
            Picker("Scaling", selection: $display.scaling) {
                ForEach(DisplaySettings.Scaling.allCases) { mode in
                    Text(mode.label).tag(mode)
                }
            }
            .pickerStyle(.segmented)

            Text(display.scaling.explanation)
                .font(.caption)
                .foregroundStyle(.secondary)

            if display.scaling == .fill {
                LabelledSlider(title: "Widen",
                               value: $display.stretch,
                               range: 0...1,
                               readout: "\(Int(display.stretch * 100))%")
                Text("0% is aspect-correct, 100% reaches the screen edges. A mild widening is usually invisible in a 2D game and buys a noticeably bigger picture.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            LabelledSlider(title: "Zoom",
                           value: $display.zoom,
                           range: 1...1.6,
                           readout: String(format: "%.2f×", display.zoom))

            LabelledSlider(title: "Vertical",
                           value: $display.verticalOffset,
                           range: -0.25...0.25,
                           readout: String(format: "%+.0f%%", display.verticalOffset * 100))

            Toggle("Smooth pixels", isOn: $display.smoothing)

            Button {
                display.scaling = .fit
                display.stretch = 0
                display.zoom = 1
                display.verticalOffset = 0
                display.smoothing = false
            } label: {
                Label("Reset display", systemImage: "arrow.uturn.backward")
            }
        } header: {
            Text("Display")
        }
    }

    // MARK: - Controls

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
            Text("The stick snaps to eight directions, so holding it north-east presses Up and Right together — which is what the SNES does when you walk into a corner. Turning diagonals off restricts it to four.")
        }
    }

    // MARK: - Haptics

    private var hapticsSection: some View {
        Section {
            Picker("Feel", selection: presetBinding) {
                ForEach(AppSettings.HapticPreset.allCases) { preset in
                    Text(preset.label).tag(preset)
                }
            }
            .pickerStyle(.segmented)

            if let preset = settings.matchingPreset {
                Text(preset.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text("Custom mix.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Toggle("Haptics", isOn: $settings.hapticsEnabled)

            Button {
                runtime.conductor.audition()
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
            Text("The rumble follows the game's own audio in real time: bass becomes a continuous thump, sharp sounds become taps. Direction ticks are the little knock you feel each time the stick snaps to a new direction.")
        }
    }

    /// The preset picker is derived rather than stored, so dragging a slider
    /// deselects the preset instead of leaving a lie on screen.
    private var presetBinding: Binding<AppSettings.HapticPreset> {
        Binding(
            get: { settings.matchingPreset ?? .standard },
            set: { settings.apply($0) })
    }

    // MARK: - Audio

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

    // MARK: - Core options

    private var coreOptionsSections: some View {
        Group {
            ForEach(CoreOptionCatalog.groups) { group in
                Section {
                    ForEach(group.keys, id: \.self) { key in
                        if let descriptor = Snes9xOptions.descriptor(for: key) {
                            coreOptionRow(descriptor: descriptor)
                        }
                    }
                } header: {
                    Text(group.title)
                } footer: {
                    if let caption = group.caption {
                        Text(caption)
                    }
                }
            }

            Section {
                if runtime.coreOptionsNeedReload {
                    Button {
                        onRestart()
                        dismiss()
                    } label: {
                        Label("Restart to apply", systemImage: "arrow.clockwise")
                    }
                }
                Button(role: .destructive) {
                    settings.resetCoreOptions()
                } label: {
                    Label("Reset all core options", systemImage: "arrow.uturn.backward")
                }
            } header: {
                Text("Apply")
            } footer: {
                if runtime.coreOptionsNeedReload {
                    Text("One of the changed options is only read when a game loads. Restarting reloads the ROM and resumes from your savestate.")
                } else {
                    Text("Changes are applied to the running core immediately. Options marked “reload” take effect on restart.")
                }
            }
        }
    }

    private func coreOptionRow(descriptor: CoreOptionDescriptor) -> some View {
        Picker(selection: coreOptionBinding(descriptor)) {
            ForEach(descriptor.values, id: \.self) { value in
                Text(value).tag(value)
            }
        } label: {
            HStack {
                Text(descriptor.label)
                if CoreOptionCatalog.reloadRequired.contains(descriptor.key) {
                    Text("reload")
                        .font(.caption2.weight(.semibold))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(.quaternary, in: Capsule())
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func coreOptionBinding(_ descriptor: CoreOptionDescriptor) -> Binding<String> {
        Binding(
            get: { settings.coreOptionValue(for: descriptor.key) ?? descriptor.defaultValue },
            set: { settings.setCoreOptionValue($0, for: descriptor.key) })
    }

    // MARK: - Library

    private var librarySection: some View {
        Section {
            Button(role: .destructive) {
                onQuit()
            } label: {
                Label("Quit to library", systemImage: "rectangle.on.rectangle")
            }
        }
    }
}

/// A slider with its label and readout on one line, which `Form` does not give you
/// for free.
struct LabelledSlider: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let readout: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title)
                Spacer()
                Text(readout)
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Slider(value: $value, in: range)
        }
    }
}
