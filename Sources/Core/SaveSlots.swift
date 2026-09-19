//
//  SaveSlots.swift
//  EarthboundWrapper
//
//  Where savestates live, and what each one knows about itself.
//
//  A savestate is the emulator's own memory dump: it captures the console
//  mid-frame, which suits an RPG exactly, because EarthBound only writes a real
//  save when you phone Dad. A snapshot means never having to.
//
//  Slots are files named after the ROM, so a game's slots travel with it and two
//  games can never collide. They sit next to the battery save in the same Saves
//  directory, which is the directory the Files app exposes.
//

import Foundation

/// One place a savestate can live.
///
/// `auto` is written for you whenever the app leaves the foreground, so reopening a
/// game resumes where you stopped without being asked. The numbered slots are the
/// player's, and nothing writes them except a deliberate action.
enum SaveSlot: Hashable, Identifiable, Sendable {
    case auto
    case manual(Int)

    /// Enough to cover a playthrough's chapters without turning the settings screen
    /// into a file browser.
    static let manualCount = 8

    static var manual: [SaveSlot] { (1...manualCount).map { .manual($0) } }
    static var all: [SaveSlot] { [.auto] + manual }

    /// Stable identity for `ForEach`, and the number persisted in settings.
    var id: Int {
        switch self {
        case .auto: return 0
        case .manual(let index): return index
        }
    }

    var title: String {
        switch self {
        case .auto: return "Automatic"
        case .manual(let index): return "Slot \(index)"
        }
    }

    /// What a manual slot appends to the ROM's name. The automatic slot keeps the
    /// bare `.state` suffix it had before slots existed, so a savestate written by an
    /// older build still loads.
    var fileSuffix: String {
        switch self {
        case .auto: return ""
        case .manual(let index): return ".slot\(index)"
        }
    }

    init?(id: Int) {
        if id == 0 {
            self = .auto
        } else if (1...Self.manualCount).contains(id) {
            self = .manual(id)
        } else {
            return nil
        }
    }
}

/// What is actually on disk for one slot.
///
/// Read from the file's own attributes rather than from a sidecar index. There is
/// then only one thing that can be wrong about a slot, and a savestate deleted from
/// the Files app cannot leave a stale row behind.
struct SaveSlotInfo: Identifiable, Sendable {
    let slot: SaveSlot
    let url: URL
    let savedAt: Date?
    let byteCount: Int

    var id: Int { slot.id }
    var isEmpty: Bool { savedAt == nil }

    /// "Empty", or how long ago the state was taken and how big it is.
    var detail: String {
        guard let savedAt else { return "Empty" }
        let age = savedAt.formatted(.relative(presentation: .named))
        let size = ByteCountFormatter.string(fromByteCount: Int64(byteCount), countStyle: .file)
        return "\(age) · \(size)"
    }
}

extension RomDescriptor {
    /// Where a slot's savestate lives.
    func stateURL(for slot: SaveSlot) -> URL {
        Self.savesDirectory.appendingPathComponent(name + slot.fileSuffix + ".state")
    }

    func hasState(in slot: SaveSlot) -> Bool {
        FileManager.default.fileExists(atPath: stateURL(for: slot).path)
    }

    /// True when there is anything to resume from or load: the automatic slot or any
    /// manual one. This is what the library list badges.
    var hasAnySavedState: Bool {
        let directory = Self.savesDirectory
        return SaveSlot.all.contains { slot in
            FileManager.default.fileExists(atPath: stateFileURL(in: directory, for: slot).path)
        }
    }

    /// Every slot in order, with the date and size of whatever is in it.
    func saveStateSlots() -> [SaveSlotInfo] {
        // The directory is resolved once rather than per slot. `savesDirectory`
        // creates it if it is missing, and asking for it nine times to answer one
        // question is nine syscalls that cannot say anything new.
        let directory = Self.savesDirectory
        return SaveSlot.all.map { slot in
            let url = stateFileURL(in: directory, for: slot)
            let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
            return SaveSlotInfo(slot: slot,
                                url: url,
                                savedAt: attributes?[.modificationDate] as? Date,
                                byteCount: (attributes?[.size] as? NSNumber)?.intValue ?? 0)
        }
    }

    func eraseState(in slot: SaveSlot) {
        try? FileManager.default.removeItem(at: stateURL(for: slot))
    }

    private func stateFileURL(in directory: URL, for slot: SaveSlot) -> URL {
        directory.appendingPathComponent(name + slot.fileSuffix + ".state")
    }
}
