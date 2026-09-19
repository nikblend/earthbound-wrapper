//
//  GameScreen.swift
//  EarthboundWrapper
//
//  The game itself: picture, controls, and the lifecycle that keeps saves honest.
//
//  Layer order matters here and is the whole layout:
//
//    1. the Metal view, ignoring the safe area so the picture reaches the edges
//    2. the controls, which handle their own touches, inside the safe area
//    3. the top bar, above the controls so its buttons behave like buttons
//
//  Putting the top bar above the controls is not cosmetic: the controls' capture
//  view takes every touch that lands on it, so anything that should behave like
//  ordinary UI has to sit on top of it.
//

import SwiftUI
import os

struct GameScreen: View {
    let rom: RomDescriptor

    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @Environment(AppSettings.self) private var settings

    @State private var display = DisplaySettings()
    @State private var runtime: GameRuntime?
    @State private var showSettings = false
    @State private var isFastForwarding = false
    @State private var lastSize: CGSize = .zero
    @State private var lastSafeArea: EdgeInsets = EdgeInsets()

    private let log = Logger(subsystem: "dev.nikan.earthbound", category: "screen")

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                Color.black.ignoresSafeArea()

                if let runtime {
                    MetalGameView(frameQueue: runtime.session.frames,
                                  settings: runtime.displaySnapshot,
                                  displayAspect: runtime.displayAspect,
                                  onFramePresented: { runtime.handleFramePresented() })
                        .ignoresSafeArea()

                    TouchControlsOverlay(model: runtime.controls,
                                         gamepad: runtime.gamepad,
                                         onMenu: { showSettings = true })
                        .opacity(settings.controlOpacity)

                    topBar(runtime: runtime, safeArea: proxy.safeAreaInsets)

                    if let toast = runtime.toast {
                        toastOverlay(toast)
                    }

                    if let failure = runtime.failureMessage {
                        failureOverlay(message: failure)
                    }
                } else {
                    ProgressView()
                        .tint(.white)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .onAppear {
                lastSize = proxy.size
                lastSafeArea = proxy.safeAreaInsets
                startRuntimeIfNeeded()
            }
            .onChange(of: proxy.size) { _, newSize in
                lastSize = newSize
                lastSafeArea = proxy.safeAreaInsets
            }
            .animation(.easeOut(duration: 0.16), value: runtime?.toast)
        }
        .statusBarHidden()
        .persistentSystemOverlays(.hidden)
        .onDisappear {
            runtime?.shutdown()
            runtime = nil
        }
        .onChange(of: scenePhase) { _, phase in
            handleScenePhase(phase)
        }
        .sheet(isPresented: $showSettings) {
            if let runtime {
                GameSettingsSheet(runtime: runtime,
                                  settings: settings,
                                  display: runtime.display,
                                  onRestart: { restart() },
                                  onQuit: {
                                      showSettings = false
                                      shutdownAndDismiss()
                                  })
            }
        }
    }

    // MARK: - Chrome

    private func topBar(runtime: GameRuntime, safeArea: EdgeInsets) -> some View {
        HStack(spacing: 8) {
            saveStateButton(runtime: runtime)
            fastForwardButton(runtime: runtime)
            Spacer()
        }
        // Offset past the controls' own menu button, which sits in the overlay and
        // occupies the first 58 points of the top edge.
        .padding(.leading, 64)
        .padding(.top, safeArea.top + 8)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    /// Saves into the slot chosen in settings, and names it on screen afterwards.
    ///
    /// One tap rather than a menu: this exists to replace reaching for the game's own
    /// save, so it has to be faster than the thing it replaces.
    private func saveStateButton(runtime: GameRuntime) -> some View {
        Button {
            runtime.saveState(to: .manual(settings.quickSaveSlot))
        } label: {
            Text("SAVE")
                .font(.system(size: 14, weight: .semibold, design: .rounded))
                .foregroundStyle(.white.opacity(0.9))
                .padding(.horizontal, 16)
                .frame(height: 40)
                .background(.black.opacity(0.35), in: Capsule())
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    /// A brief confirmation. Deliberately not an alert: saving is frequent, and
    /// anything that interrupts play to say it worked is worse than not saying it.
    private func toastOverlay(_ message: String) -> some View {
        Text(message)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 18)
            .padding(.vertical, 10)
            .background(.black.opacity(0.75), in: Capsule())
            .overlay(Capsule().strokeBorder(.white.opacity(0.18), lineWidth: 1))
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .padding(.top, 56)
            .allowsHitTesting(false)
    }

    private func fastForwardButton(runtime: GameRuntime) -> some View {
        // Hold to run fast, release to stop: a latched fast-forward is a trap in an
        // RPG, where you notice you have been moving at 4x only after you have
        // walked somewhere you did not mean to.
        Text("4x")
            .font(.system(size: 14, weight: .semibold, design: .rounded))
            .foregroundStyle(isFastForwarding ? .black : .white.opacity(0.9))
            .frame(width: 44, height: 40)
            .background(isFastForwarding ? Color.white.opacity(0.9) : Color.black.opacity(0.35),
                        in: Capsule())
            .contentShape(Capsule())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in
                        guard !isFastForwarding else { return }
                        isFastForwarding = true
                        runtime.setFastForwarding(true)
                    }
                    .onEnded { _ in
                        isFastForwarding = false
                        runtime.setFastForwarding(false)
                    })
    }

    private func failureOverlay(message: String) -> some View {
        VStack(spacing: 14) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 34))
                .foregroundStyle(.yellow)
            Text("Could not start the game")
                .font(.headline)
            Text(message)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("Back to library") { shutdownAndDismiss() }
                .buttonStyle(.borderedProminent)
        }
        .padding(28)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20))
        .padding(40)
    }

    // MARK: - Lifecycle

    private func startRuntimeIfNeeded() {
        guard runtime == nil else { return }
        let runtime = GameRuntime(rom: rom,
                                  settings: settings,
                                  display: display,
                                  size: lastSize,
                                  safeArea: lastSafeArea)
        runtime.start()
        self.runtime = runtime
    }

    /// Tears the session down and builds a new one, which is the only way to apply
    /// core options snes9x reads exactly once (region, the hi-res modes).
    private func restart() {
        runtime?.shutdown()
        runtime = nil
        isFastForwarding = false
        // A short delay rather than an immediate rebuild: the old session's
        // emulation thread needs to unwind before a new core is initialised, and
        // snes9x keeps process-global state.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            startRuntimeIfNeeded()
        }
    }

    private func shutdownAndDismiss() {
        runtime?.shutdown()
        runtime = nil
        dismiss()
    }

    private func handleScenePhase(_ phase: ScenePhase) {
        switch phase {
        case .active:
            // CoreHaptics tears its engine down when the app leaves the foreground
            // and does not necessarily bring it back.
            runtime?.conductor.start()
        case .inactive, .background:
            // Release every input before anything else. A virtual button whose
            // touchesEnded never arrives would otherwise stay held through the whole
            // background period and resume mid-stride.
            runtime?.gamepad.releaseAll()
            runtime?.session.saveState(to: .auto)
            runtime?.session.flushSRAM()
            isFastForwarding = false
            runtime?.setFastForwarding(false)
        @unknown default:
            break
        }
    }
}
