//
//  EmulatorSession.swift
//  EarthboundWrapper
//
//  Owns one running game.
//
//  Threading model, which is the whole point of this file:
//
//    · Everything libretro touches happens on one dedicated thread. The core is
//      not thread-safe, and a surprising number of "random emulator crashes" are
//      really a frontend calling `retro_serialize` from the UI thread during
//      `retro_run`.
//
//    · Video leaves through `FrameQueue`, which hands the renderer whole buffers
//      and lets it own them until it is done. The emulation thread never waits.
//
//    · Audio leaves through the C ring buffer. The CoreAudio render thread pulls
//      from it and never waits on us either.
//
//    · Input arrives as a single atomic word that the UI stores and the core
//      loads inside `retro_run`.
//
//    · Saves, resets and fast-forward arrive as commands on a queue drained at a
//      frame boundary.
//
//  Frame pacing is a servo rather than a fixed sleep. Sleeping exactly
//  1/60.0988 s per frame drifts against the audio hardware's real rate, and after
//  a minute the ring is either empty or overflowing. Steering the sleep by how
//  full the ring is keeps audio in sync without resampling anything.
//

import Foundation
import os

/// The ROM being played.
struct RomDescriptor: Identifiable, Hashable, Sendable {
    let url: URL

    var id: URL { url }
    var name: String { url.deletingPathExtension().lastPathComponent }

    /// Where the battery-backed SRAM lives, in the same directory as the savestates
    /// that SaveSlots.swift names. Derived from the ROM name, so a game's saves
    /// travel with the ROM file itself.
    var sramURL: URL { Self.savesDirectory.appendingPathComponent(name + ".srm") }

    var isPlayable: Bool { FileManager.default.fileExists(atPath: url.path) }
    var hasSRAM: Bool { FileManager.default.fileExists(atPath: sramURL.path) }

    static var savesDirectory: URL {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let directory = documents.appendingPathComponent("Saves", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}

final class EmulatorSession: @unchecked Sendable {
    // MARK: - Types

    enum Failure: LocalizedError {
        case romUnreadable(String)
        case coreRejectedGame
        case unsupportedAPI(UInt32)

        var errorDescription: String? {
            switch self {
            case .romUnreadable(let name):
                return "Could not read \(name). The file may have moved, or it may not be a SNES ROM."
            case .coreRejectedGame:
                return "The emulator core refused to load this file. Usually that means it is not a SNES ROM, or it is a hack the core cannot map."
            case .unsupportedAPI(let version):
                return "The bundled core reports libretro API version \(version), which this frontend does not speak."
            }
        }
    }

    private enum Command {
        case reset
        case saveState(SaveSlot)
        case loadState(SaveSlot)
        case flushSRAM
    }

    /// The result of the last save or load, for the UI to confirm on screen.
    struct SaveOutcome: Sendable {
        let slot: SaveSlot
        let succeeded: Bool
        let message: String
    }

    // MARK: - Shared state a C callback can reach
    //
    // libretro takes bare C function pointers, and only non-capturing functions
    // convert to one. Rather than thread a context pointer through a core API
    // that has no field for one, the callbacks look up the one session that can
    // be running.

    private static let activeStorage = Locked(EmulatorSession?.none)

    static var active: EmulatorSession? {
        get { activeStorage.withLock { $0 } }
        set { activeStorage.withLock { $0 = newValue } }
    }

    // MARK: - Storage

    let rom: RomDescriptor
    /// Carries the core's audio to `AudioOutput`. The owner must shut the audio
    /// output down before releasing the session, since it holds this pointer.
    let audioRing: OpaquePointer
    /// The joypad bitmask the UI writes and the core reads.
    let input: OpaquePointer
    let frames = FrameQueue()

    /// Behind a lock because the emulation thread updates it when a state is loaded
    /// and the main thread reads it every frame for the aspect ratio, and a torn
    /// read of a struct containing a `Double` is not a theoretically safe thing.
    private let avInfoStorage: Locked<CoreAVInfo>
    var avInfo: CoreAVInfo { avInfoStorage.withLock { $0 } }

    private(set) var systemInfo: CoreSystemInfo
    private(set) var lastError: Failure?

    /// Latest tactile analysis, picked up by the draw loop on the main thread.
    private let tactileSlot = Locked(TactileFrame.silent)

    /// Outcome of the newest save or load, waiting for the main thread to report it.
    private let saveOutcomeStorage = Locked(SaveOutcome?.none)

    /// Screen refresh rate, forwarded to the core so it can pace itself.
    var targetRefreshRate: Float = 60 {
        didSet { environment.targetRefreshRate = targetRefreshRate }
    }

    private let environment = RetroEnvironment.shared
    private let analyzer: TactileSignalAnalyzer
    private let log = Logger(subsystem: "dev.nikan.earthbound", category: "session")

    private var thread: Thread?
    /// Read by `eb_sleep_until`, so a stop request interrupts the frame sleep
    /// instead of waiting out the last frame. This, not a Swift flag, is what the
    /// frame loop tests: it is the only piece of state both threads touch without
    /// a lock.
    private let stopFlag: UnsafeMutablePointer<Int32>
    private var commands = Locked([Command]())

    /// The ROM bytes, kept alive for as long as the core may read them.
    private var romData: UnsafeMutableRawPointer?
    private var romByteCount = 0

    private var lastWrittenSRAM: Data?
    private var lastSRAMFlush = Date.distantPast
    private var isFastForwarding = false

    // MARK: - Init

    init(rom: RomDescriptor, initialOptionValues: [String: String]) {
        self.rom = rom
        audioRing = eb_ring_create(AudioOutput.ringCapacityBytes)!
        input = eb_input_create()!
        stopFlag = .allocate(capacity: 1)
        stopFlag.initialize(to: 0)

        // snes9x always runs at 32040 Hz; this only sizes the analyser's filters,
        // and the real rate replaces it once the core reports its AV info.
        analyzer = TactileSignalAnalyzer(sampleRate: 32_040)

        systemInfo = CoreSystemInfo(libraryName: "snes9x", libraryVersion: "—",
                                    validExtensions: ["sfc", "smc"], needsFullPath: false)
        // Overwritten from the core's own report once a game is loaded; these are
        // snes9x's values for a standard NTSC cartridge.
        avInfoStorage = Locked(CoreAVInfo(baseWidth: 256, baseHeight: 224,
                                          maxWidth: 512, maxHeight: 478,
                                          aspectRatio: 4.0 / 3.0,
                                          fps: 60.0988, sampleRate: 32_040))

        environment.installOptionValues(initialOptionValues)
        environment.targetRefreshRate = targetRefreshRate
    }

    deinit {
        stop()
        eb_ring_destroy(audioRing)
        eb_input_destroy(input)
        stopFlag.deinitialize(count: 1)
        stopFlag.deallocate()
        romData?.deallocate()
    }

    // MARK: - Lifecycle

    /// Starts the emulation thread. Returns immediately; the game appears once the
    /// core has loaded and produced a frame. Poll `lastError` for failure.
    func start() {
        guard thread == nil else { return }
        stopFlag.pointee = 0
        lastError = nil

        let thread = Thread { [self] in runCore() }
        thread.name = "dev.nikan.earthbound.core"
        thread.qualityOfService = .userInteractive
        // The interpreter plus the audio stack uses a few hundred kilobytes;
        // 1 MB leaves room without wasting pages.
        thread.stackSize = 1 << 20
        self.thread = thread
        thread.start()
    }

    /// Asks the emulation thread to finish and waits briefly for it to unwind.
    func stop() {
        guard thread != nil else { return }
        stopFlag.pointee = 1
        // The loop notices within one frame, so this is fast; the timeout is a
        // backstop against a core that has itself wedged, not an expectation.
        let deadline = Date().addingTimeInterval(1.0)
        while thread?.isFinished == false, Date() < deadline {
            usleep(4_000)
        }
        thread = nil
        EmulatorSession.active = nil
    }

    var isRunning: Bool { thread?.isFinished == false }

    // MARK: - Commands (callable from any thread)

    func reset() { commands.withLock { $0.append(.reset) } }

    /// Dumps the core's state into `slot`. Drained at the next frame boundary, so the
    /// dump is taken between frames rather than mid-instruction.
    func saveState(to slot: SaveSlot) { commands.withLock { $0.append(.saveState(slot)) } }

    func loadState(from slot: SaveSlot) { commands.withLock { $0.append(.loadState(slot)) } }

    func flushSRAM() { commands.withLock { $0.append(.flushSRAM) } }

    /// The newest save or load result, cleared by the read. Read-and-clear because a
    /// confirmation nobody was left to draw is a message nobody should see.
    func takeSaveOutcome() -> SaveOutcome? {
        saveOutcomeStorage.withLock { outcome in
            defer { outcome = nil }
            return outcome
        }
    }

    func setFastForwarding(_ enabled: Bool) {
        isFastForwarding = enabled
        environment.isFastForwarding = enabled
    }

    /// Picks up the newest tactile analysis. Main thread, once per drawn frame.
    ///
    /// Read-and-clear rather than a shared snapshot: a frame nobody drew is a
    /// frame of haptics nobody should feel, and it keeps the audio callback free
    /// of any dependency on UI timing.
    func consumeTactileFrame() -> TactileFrame {
        tactileSlot.withLock { slot in
            let frame = slot
            slot = .silent
            return frame
        }
    }

    // MARK: - The emulation thread

    private func runCore() {
        defer {
            EmulatorSession.active = nil
            romData?.deallocate()
            romData = nil
        }

        // Environment first: the core publishes its option definitions from inside
        // `retro_set_environment`, so it has to be wired before anything else.
        eb_retro_set_environment(ebEnvironmentCallback)
        eb_retro_set_video_refresh(ebVideoRefresh)
        eb_retro_set_audio_sample_batch(ebAudioBatch)
        eb_retro_set_input_poll(ebInputPoll)
        eb_retro_set_input_state(ebInputState)

        let apiVersion = eb_retro_api_version()
        guard apiVersion == Libretro.apiVersion else {
            lastError = .unsupportedAPI(apiVersion)
            return
        }

        eb_retro_init()
        defer { eb_retro_deinit() }

        systemInfo = environment.systemInfo()

        guard let pointer = readROM() else {
            lastError = .romUnreadable(rom.name)
            return
        }

        // Visible to the callbacks before `load_game`, because the core may already
        // be producing frames and audio during it.
        EmulatorSession.active = self

        guard loadGame(data: pointer) else {
            lastError = .coreRejectedGame
            return
        }
        defer { eb_retro_unload_game() }

        eb_retro_set_controller_port_device(0, Libretro.Device.joypad)
        environment.refreshAVInfo()
        environment.markOptionsInstalled()
        refreshAVInfo()

        // SRAM first, then the savestate: a savestate already contains the save
        // RAM it was taken with, so restoring it second is what "resume" means.
        restoreSRAMFromDisk()
        // The automatic slot is the resume path, and its outcome is deliberately not
        // published: reopening a game should not raise a banner about it.
        if rom.hasState(in: .auto) { _ = readState(from: .auto) }
        refreshAVInfo()

        runFrames()

        flushSRAMToDisk()
    }

    private func readROM() -> UnsafeMutableRawPointer? {
        guard let fileData = try? Data(contentsOf: rom.url, options: .mappedIfSafe) else {
            return nil
        }
        // Copied into our own allocation rather than handing the core a pointer
        // into a `Data` whose storage lifetime we do not control.
        let count = max(fileData.count, 1)
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: count, alignment: 16)
        fileData.withUnsafeBytes { source in
            guard let base = source.baseAddress else { return }
            buffer.copyMemory(from: base, byteCount: fileData.count)
        }
        romData = buffer
        romByteCount = fileData.count
        return buffer
    }

    private func loadGame(data: UnsafeMutableRawPointer) -> Bool {
        let gameInfo = UnsafeMutableRawPointer.allocate(byteCount: eb_game_info_size(),
                                                        alignment: 16)
        defer { gameInfo.deallocate() }

        // The core only reads these during the call, but they must stay valid for
        // its duration, so they outlive the call and are freed afterwards.
        let path = strdup(rom.url.path)!
        defer { free(path) }
        let meta = strdup("earthbound-wrapper")!
        defer { free(meta) }

        eb_build_game_info(gameInfo, path, data, romByteCount, meta)
        return eb_retro_load_game(gameInfo)
    }

    /// The paced frame loop.
    private func runFrames() {
        let fps = avInfo.fps > 1 ? avInfo.fps : 60.0988
        let period = 1_000_000_000.0 / fps
        // Fast-forward is capped rather than unbounded: uncapped it pins a core at
        // 100% and heats the phone until it throttles, which then costs more
        // frames than the cap did.
        let fastForwardPeriod = period / 4
        let ringCapacity = Double(eb_ring_capacity(audioRing))
        let targetFill = AudioOutput.targetFill

        var deadline = Double(eb_monotonic_nanos())
        var framesSinceFlush = 0

        while stopFlag.pointee == 0 {
            drainCommands()
            if stopFlag.pointee != 0 { break }

            eb_retro_run()

            let step: Double
            if isFastForwarding {
                step = fastForwardPeriod
            } else {
                // Steer the sleep by how full the audio ring is. Too full means we
                // are producing faster than the hardware consumes, so sleep
                // longer; too empty means the reverse. The gain is deliberately
                // gentle: an over-eager correction is audible as warbling.
                let fill = Double(eb_ring_available(audioRing)) / ringCapacity
                let error = fill - targetFill
                step = period + max(-2_000_000, min(2_000_000, error * 100_000_000))
            }
            deadline += step

            let now = Double(eb_monotonic_nanos())
            // A long stall (app suspended, debugger attached, thermal throttle)
            // would otherwise be repaid by running a burst of frames at full
            // speed, which sounds like a tape fast-forwarding.
            if deadline < now - period * 4 { deadline = now }
            if deadline > now {
                eb_sleep_until(UInt64(deadline), stopFlag)
            }

            framesSinceFlush += 1
            if framesSinceFlush >= 300 {
                framesSinceFlush = 0
                flushSRAMToDisk()
            }
        }
    }

    /// Re-reads the core's video and audio description, which can change when a
    /// savestate with a different display mode is loaded.
    private func refreshAVInfo() {
        environment.refreshAVInfo()
        let info = environment.avInfo
        avInfoStorage.withLock { $0 = info }
    }

    private func drainCommands() {
        let pending = commands.withLock { commands -> [Command] in
            defer { commands.removeAll() }
            return commands
        }
        for command in pending {
            switch command {
            case .reset:
                eb_retro_reset()
            case .saveState(let slot):
                report(writeState(to: slot))
            case .loadState(let slot):
                report(readState(from: slot))
                refreshAVInfo()
            case .flushSRAM:
                flushSRAMToDisk()
            }
        }
    }

    // MARK: - Saves

    /// Writes the core's state into a slot, and says what happened.
    ///
    /// The state size is queried on every save rather than cached: a core is free to
    /// report a different size once content is loaded, and a stale size would quietly
    /// truncate the dump.
    private func writeState(to slot: SaveSlot) -> SaveOutcome {
        let size = eb_retro_serialize_size()
        guard size > 0 else {
            log.error("core has no state to serialize")
            return SaveOutcome(slot: slot, succeeded: false,
                               message: "The core had no state to save.")
        }

        let buffer = UnsafeMutableRawPointer.allocate(byteCount: size, alignment: 16)
        defer { buffer.deallocate() }
        guard eb_retro_serialize(buffer, size) else {
            log.error("core refused to serialize")
            return SaveOutcome(slot: slot, succeeded: false,
                               message: "The core refused to save its state.")
        }

        do {
            let url = rom.stateURL(for: slot)
            try Data(bytes: buffer, count: size).write(to: url, options: .atomic)
            log.info("saved \(slot.title, privacy: .public) (\(size) bytes)")
            return SaveOutcome(slot: slot, succeeded: true, message: "Saved to \(slot.title)")
        } catch {
            log.error("could not write savestate: \(error.localizedDescription)")
            return SaveOutcome(slot: slot, succeeded: false,
                               message: "Could not write \(slot.title): \(error.localizedDescription)")
        }
    }

    private func readState(from slot: SaveSlot) -> SaveOutcome {
        guard let data = try? Data(contentsOf: rom.stateURL(for: slot)) else {
            log.error("\(slot.title, privacy: .public) is empty")
            return SaveOutcome(slot: slot, succeeded: false, message: "\(slot.title) is empty.")
        }

        let loaded = data.withUnsafeBytes { raw -> Bool in
            guard let base = raw.baseAddress else { return false }
            return eb_retro_unserialize(base, data.count)
        }

        guard loaded else {
            log.error("core refused the savestate")
            return SaveOutcome(slot: slot, succeeded: false,
                               message: "The core refused \(slot.title).")
        }
        log.info("loaded \(slot.title, privacy: .public) (\(data.count) bytes)")
        return SaveOutcome(slot: slot, succeeded: true, message: "Loaded \(slot.title)")
    }

    private func report(_ outcome: SaveOutcome) {
        saveOutcomeStorage.withLock { $0 = outcome }
    }

    /// Writes battery-backed save RAM next to the ROM's savestate.
    ///
    /// EarthBound saves to SRAM, so this is the difference between keeping a
    /// playthrough and losing it. The core keeps save RAM in memory and never
    /// writes it itself, so nothing is durable unless we do this.
    private func flushSRAMToDisk() {
        guard let pointer = eb_retro_get_memory_data(Libretro.Memory.saveRAM) else { return }
        let size = eb_retro_get_memory_size(Libretro.Memory.saveRAM)
        guard size > 0 else { return }

        let data = Data(bytes: pointer, count: size)
        // Written on a timer, so most of these calls have nothing new to say.
        if data == lastWrittenSRAM { return }

        do {
            try data.write(to: rom.sramURL, options: .atomic)
            lastWrittenSRAM = data
            lastSRAMFlush = Date()
        } catch {
            log.error("could not write SRAM: \(error.localizedDescription)")
        }
    }

    /// Loads SRAM from disk into the core. Called after `retro_load_game`, since
    /// the core only exposes the region once a game is loaded.
    private func restoreSRAMFromDisk() {
        guard let data = try? Data(contentsOf: rom.sramURL) else { return }
        guard let pointer = eb_retro_get_memory_data(Libretro.Memory.saveRAM) else { return }
        let size = eb_retro_get_memory_size(Libretro.Memory.saveRAM)
        guard size > 0 else { return }

        let count = min(size, data.count)
        data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            pointer.copyMemory(from: base, byteCount: count)
        }
        lastWrittenSRAM = data
        log.info("restored \(count) bytes of SRAM")
    }

    // MARK: - Core callbacks

    /// Called by the core with a finished frame. A null `data` means "repeat the
    /// previous frame", which libretro permits; we honour it by publishing nothing.
    fileprivate func handleVideo(_ data: UnsafeRawPointer?, width: UInt32, height: UInt32,
                                 pitch: Int) {
        guard let data, width > 0, height > 0 else { return }

        let pixelWidth = Int(width)
        let pixelHeight = Int(height)
        guard pixelWidth <= FrameQueue.maximumWidth,
              pixelHeight <= FrameQueue.maximumHeight else { return }

        let destination = frames.beginFrame()
        PixelDecoder.decode(source: data,
                            width: pixelWidth,
                            height: pixelHeight,
                            pitch: pitch,
                            format: environment.pixelFormat,
                            into: destination)
        frames.commitFrame(width: pixelWidth, height: pixelHeight)
    }

    /// Called by the core with a batch of interleaved 16-bit stereo. Returns the
    /// number of frames consumed, which libretro treats as a promise.
    fileprivate func handleAudio(_ samples: UnsafePointer<Int16>, frameCount: Int) -> Int {
        let bytesPerFrame = 2 * MemoryLayout<Int16>.size
        let bytesWritten = eb_ring_write(audioRing, samples, frameCount * bytesPerFrame)
        return bytesWritten / bytesPerFrame
    }

    /// Runs the band analysis and parks the result for the draw loop.
    ///
    /// Deliberately fed the whole batch whether or not the ring kept it: the
    /// tactile response should follow what the game is doing, not what the audio
    /// device happened to have room for.
    fileprivate func analyseTactile(_ samples: UnsafePointer<Int16>, frameCount: Int) {
        guard !isFastForwarding, stopFlag.pointee == 0 else { return }
        let frame = analyzer.process(samples, frames: frameCount)
        tactileSlot.withLock { $0 = frame }
    }

    /// The core asks us to collect input for this frame. The UI already stored it
    /// atomically, so there is nothing newer to gather; the hook exists because the
    /// API requires it.
    fileprivate func pollInput() {}

    fileprivate func inputState(port: UInt32, device: UInt32, index: UInt32,
                                id: UInt32) -> Int16 {
        guard device == Libretro.Device.joypad else { return 0 }
        let mask = eb_input_mask(input, port)
        if id == Libretro.Device.joypadMask { return Int16(truncatingIfNeeded: mask) }
        // snes9x only ever asks for the twelve real joypad ids; anything else is
        // out of range and gets "not pressed".
        guard id < 16 else { return 0 }
        return (mask & (1 << id)) != 0 ? 1 : 0
    }
}

// MARK: - C entry points
//
// Top-level, non-capturing functions: libretro takes bare C function pointers.

private func ebVideoRefresh(_ data: UnsafeRawPointer?, _ width: UInt32, _ height: UInt32,
                            _ pitch: Int) {
    EmulatorSession.active?.handleVideo(data, width: width, height: height, pitch: pitch)
}

private func ebAudioBatch(_ data: UnsafePointer<Int16>?, _ frames: Int) -> Int {
    guard let data, frames > 0 else { return frames }
    guard let session = EmulatorSession.active else { return frames }
    let consumed = session.handleAudio(data, frameCount: frames)
    session.analyseTactile(data, frameCount: frames)
    return consumed
}

private func ebInputPoll() {
    EmulatorSession.active?.pollInput()
}

private func ebInputState(_ port: UInt32, _ device: UInt32, _ index: UInt32,
                          _ id: UInt32) -> Int16 {
    EmulatorSession.active?.inputState(port: port, device: device, index: index, id: id) ?? 0
}
