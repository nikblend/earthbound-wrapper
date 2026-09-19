//
//  RetroEnvironment.swift
//  EarthboundWrapper
//
//  The frontend side of libretro's environment callback.
//
//  The core talks to us through one function pointer and a command integer. Get
//  it wrong and nothing loads, so this file aims to be boring: answer only the
//  commands we genuinely implement, return `false` for everything else (libretro
//  cores are written to tolerate that), and never hand back a null string.
//
//  Threading: every call arrives from the emulation thread, except during
//  `retro_set_environment`/`retro_load_game`, which also run there because the
//  session funnels all core calls onto that thread.
//

import Foundation
import os

/// What the core reports about itself once loaded.
struct CoreSystemInfo: Sendable {
    var libraryName: String
    var libraryVersion: String
    var validExtensions: [String]
    var needsFullPath: Bool
}

/// What the core reports about its video and audio output.
struct CoreAVInfo: Sendable {
    var baseWidth: UInt32
    var baseHeight: UInt32
    var maxWidth: UInt32
    var maxHeight: UInt32
    /// Aspect the core wants for the displayed image. Zero means "use
    /// baseWidth / baseHeight". snes9x fills this in from its own aspect option.
    var aspectRatio: Float
    var fps: Double
    var sampleRate: Double

    /// The aspect to display at, falling back to the raw pixel grid when the
    /// core declines to state a preference.
    var displayAspect: Double {
        if aspectRatio > 0 { return Double(aspectRatio) }
        guard baseHeight > 0 else { return 4.0 / 3.0 }
        return Double(baseWidth) / Double(baseHeight)
    }
}

/// Handles libretro environment commands for a running session.
final class RetroEnvironment: @unchecked Sendable {
    /// The core calls `retro_set_environment` before anything else and may emit
    /// commands from inside that call, so this has to exist beforehand.
    static let shared = RetroEnvironment()

    private let log = Logger(subsystem: "dev.nikan.earthbound", category: "core")

    /// Directories handed to the core. Declared once and never mutated.
    let systemDirectory: URL
    let saveDirectory: URL

    /// Bumped by the session so the environment can answer questions about the
    /// running game rather than the app in general.
    private let state = Locked(State())

    private struct State {
        /// Values the core is currently being served.
        var optionValues: [String: String] = [:]
        /// Values the running core was started with. When these diverge, the game
        /// is still running on settings the user has already changed.
        var installedValues: [String: String] = [:]
        var pixelFormat: Libretro.PixelFormat = .rgb565
        var geometry: CoreAVInfo = CoreAVInfo(baseWidth: 256, baseHeight: 224,
                                              maxWidth: 512, maxHeight: 478,
                                              aspectRatio: 4.0 / 3.0,
                                              fps: 60.0988, sampleRate: 32040)
        var wantsShutdown = false
        var isFastForwarding = false
        var targetRefreshRate: Float = 60
        var optionUpdatePending = false
        var loggedCommands: Set<UInt32> = []
    }

    /// C strings the core may keep pointers to. Keyed by content so repeated
    /// answers reuse one allocation and the set stays tiny.
    private let cStringCache = Locked([String: UnsafeMutablePointer<CChar>]())

    private init() {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        systemDirectory = documents.appendingPathComponent("System", isDirectory: true)
        saveDirectory = documents.appendingPathComponent("Saves", isDirectory: true)
        for directory in [systemDirectory, saveDirectory] {
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        state.withLock { $0.optionValues = [:] }
        eb_set_log_sink(ebCoreLogSink)
    }

    // MARK: - Session state

    /// Installs the user's core-option values for a core that is about to start.
    /// Called before `retro_load_game`, never while a core is mid-run.
    func installOptionValues(_ values: [String: String]) {
        state.withLock {
            $0.optionValues = values
            $0.installedValues = values
        }
    }

    /// Applies a settings change to a running core. snes9x re-reads most options
    /// when it sees the update flag, but a few (region, the hires modes) only take
    /// effect on reload, which is what `optionsDifferFromRunningCore` reports.
    func updateOptionValues(_ values: [String: String]) {
        state.withLock {
            $0.optionValues = values
            $0.optionUpdatePending = true
        }
    }

    /// True when the running core is still using options the user has since
    /// changed beyond what a live update can apply.
    var optionsDifferFromRunningCore: Bool {
        state.withLock { $0.optionValues != $0.installedValues }
    }

    /// Records the values a core was actually started with.
    func markOptionsInstalled() {
        state.withLock { $0.installedValues = $0.optionValues }
    }

    /// Asks the core to re-read its options on its next frame.
    var optionUpdatePending: Bool {
        get { state.withLock { $0.optionUpdatePending } }
        set { state.withLock { $0.optionUpdatePending = newValue } }
    }

    /// What the core reports about itself: name, version, accepted file
    /// extensions. Valid as soon as the library is linked, since the values are
    /// static strings inside the core.
    func systemInfo() -> CoreSystemInfo {
        var raw = eb_system_info_t()
        eb_get_system_info(&raw)
        let extensions = raw.valid_extensions
            .map { String(cString: $0).split(separator: "|").map(String.init) } ?? []
        return CoreSystemInfo(
            libraryName: raw.library_name.map { String(cString: $0) } ?? "unknown core",
            libraryVersion: raw.library_version.map { String(cString: $0) } ?? "unknown",
            validExtensions: extensions,
            needsFullPath: raw.need_fullpath)
    }

    var pixelFormat: Libretro.PixelFormat {
        state.withLock { $0.pixelFormat }
    }

    var avInfo: CoreAVInfo {
        state.withLock { $0.geometry }
    }

    /// Reads the core's own description of its video and audio output. Only
    /// valid between `retro_load_game` and `retro_unload_game`.
    func refreshAVInfo() {
        var raw = eb_av_info_t()
        eb_get_system_av_info(&raw)
        let info = CoreAVInfo(baseWidth: raw.base_width,
                              baseHeight: raw.base_height,
                              maxWidth: raw.max_width,
                              maxHeight: raw.max_height,
                              aspectRatio: raw.aspect_ratio,
                              fps: raw.fps > 1 ? raw.fps : 60.0988,
                              sampleRate: raw.sample_rate > 1000 ? raw.sample_rate : 32040)
        state.withLock { $0.geometry = info }
    }

    func consumeShutdownRequest() -> Bool {
        state.withLock { state in
            defer { state.wantsShutdown = false }
            return state.wantsShutdown
        }
    }

    var isFastForwarding: Bool {
        get { state.withLock { $0.isFastForwarding } }
        set { state.withLock { $0.isFastForwarding = newValue } }
    }

    /// The screen's refresh rate, which snes9x uses to decide how hard to try to
    /// hit 60.0988 Hz without tearing. libretro types this as `float *`; writing a
    /// wider value here would corrupt the core's stack.
    var targetRefreshRate: Float {
        get { state.withLock { $0.targetRefreshRate } }
        set { state.withLock { $0.targetRefreshRate = newValue } }
    }

    // MARK: - Command dispatch

    @discardableResult
    func handle(_ command: UInt32, _ data: UnsafeMutableRawPointer?) -> Bool {
        switch command {
        case Libretro.Command.getSystemDirectory,
             Libretro.Command.getContentDirectory,
             Libretro.Command.getSaveDirectory:
            guard let data else { return false }
            let directory = command == Libretro.Command.getSaveDirectory
                ? saveDirectory : systemDirectory
            writeCString(directory.path, to: data)
            return true

        case Libretro.Command.getLogInterface:
            guard let data else { return false }
            eb_install_log_callback(data)
            return true

        case Libretro.Command.setPixelFormat:
            guard let data else { return false }
            guard let format = Libretro.PixelFormat(rawValue: eb_read_u32(data)) else {
                // We only implement formats we can actually expand. Refusing the
                // request makes the core fail cleanly instead of handing us a
                // buffer we would misread.
                return false
            }
            state.withLock { $0.pixelFormat = format }
            return true

        case Libretro.Command.getVariable:
            guard let data else { return false }
            guard let key = eb_variable_key(data).map({ String(cString: $0) }) else {
                return false
            }
            // Answering "true" with a null value crashes the core, which
            // compares the result without checking. So we only accept keys from
            // the pinned table, and we always produce a real string.
            guard let descriptor = Snes9xOptions.descriptor(for: key) else { return false }
            let value = state.withLock { $0.optionValues[key] } ?? descriptor.defaultValue
            eb_variable_set_value(data, cString(value))
            return true

        case Libretro.Command.getVariableUpdate:
            guard let data else { return false }
            // Read-and-clear in one critical section, so two rapid option edits
            // cannot both be reported as a single update.
            let pending = state.withLock { state -> Bool in
                defer { state.optionUpdatePending = false }
                return state.optionUpdatePending
            }
            data.assumingMemoryBound(to: Bool.self).pointee = pending
            return true

        case Libretro.Command.setVariables,
             Libretro.Command.setCoreOptions,
             Libretro.Command.setCoreOptionsIntl,
             Libretro.Command.setCoreOptionsV2,
             Libretro.Command.setCoreOptionsV2Intl:
            // We already know this core's whole option vocabulary (see
            // Snes9xOptions), so there is nothing to learn from the definitions
            // and nothing to store. Accepting just tells the core its options
            // were published.
            return true

        case Libretro.Command.getCoreOptionsVersion:
            guard let data else { return false }
            data.assumingMemoryBound(to: UInt32.self).pointee = 2
            return true

        case Libretro.Command.getCanDupe:
            guard let data else { return false }
            data.assumingMemoryBound(to: Bool.self).pointee = true
            return true

        case Libretro.Command.getInputBitmasks:
            guard let data else { return false }
            data.assumingMemoryBound(to: Bool.self).pointee = true
            return true

        case Libretro.Command.getLanguage:
            guard let data else { return false }
            data.assumingMemoryBound(to: UInt32.self).pointee = Libretro.languageEnglish
            return true

        case Libretro.Command.getAudioVideoEnable:
            guard let data else { return false }
            // Bit 0 enables video, bit 1 enables audio. Both, always.
            data.assumingMemoryBound(to: Int32.self).pointee = 3
            return true

        case Libretro.Command.getFastForwarding:
            guard let data else { return false }
            data.assumingMemoryBound(to: Bool.self).pointee =
                state.withLock { $0.isFastForwarding }
            return true

        case Libretro.Command.getTargetRefreshRate:
            guard let data else { return false }
            data.assumingMemoryBound(to: Float.self).pointee =
                state.withLock { $0.targetRefreshRate }
            return true

        case Libretro.Command.setSupportNoGame,
             Libretro.Command.setPerformanceLevel,
             Libretro.Command.setInputDescriptors:
            return true

        case Libretro.Command.shutdown:
            state.withLock { $0.wantsShutdown = true }
            return true

        case Libretro.Command.getMessageInterfaceVersion:
            guard let data else { return false }
            data.assumingMemoryBound(to: UInt32.self).pointee = 1
            return true

        default:
            // Geometry commands included: the renderer reads frame size from the
            // video callback every frame, so it has no use for them, and a core
            // that is told "no" keeps its own defaults.
            noteUnhandled(command)
            return false
        }
    }

    // MARK: - Helpers

    /// Writes `string` into an out-parameter of type `const char **`, reusing the
    /// allocation for repeat answers so a core that holds on to a pointer keeps
    /// seeing valid memory.
    private func writeCString(_ string: String, to pointer: UnsafeMutableRawPointer) {
        pointer.assumingMemoryBound(to: UnsafePointer<CChar>?.self).pointee = cString(string)
    }

    private func cString(_ string: String) -> UnsafePointer<CChar> {
        let cached: UnsafeMutablePointer<CChar>? = cStringCache.withLock { cache in
            if let existing = cache[string] { return existing }
            guard let duplicated = strdup(string) else { return nil }
            cache[string] = duplicated
            return duplicated
        }
        return UnsafePointer(cached)
    }

    /// Logs each unhandled command once, so a new core revision asking for
    /// something we do not implement shows up in the log without flooding it
    /// sixty times a second.
    private func noteUnhandled(_ command: UInt32) {
        let isNew = state.withLock { state -> Bool in
            state.loggedCommands.insert(command).inserted
        }
        guard isNew else { return }
        log.debug("unhandled environment command \(command)")
    }
}

// MARK: - C callbacks
//
// These have to be top-level functions with no captured context: libretro takes
// plain C function pointers, and only non-capturing closures convert to one.

/// The environment callback handed to `retro_set_environment`.
func ebEnvironmentCallback(_ command: UInt32, _ data: UnsafeMutableRawPointer?) -> Bool {
    RetroEnvironment.shared.handle(command, data)
}

/// Routes core log lines into the unified log.
func ebCoreLogSink(_ level: Int32, _ message: UnsafePointer<CChar>?) {
    guard let message else { return }
    let text = String(cString: message)
    let log = Logger(subsystem: "dev.nikan.earthbound", category: "snes9x")
    switch level {
    case 0: log.debug("\(text, privacy: .public)")
    case 1: log.info("\(text, privacy: .public)")
    case 2: log.warning("\(text, privacy: .public)")
    default: log.error("\(text, privacy: .public)")
    }
}
