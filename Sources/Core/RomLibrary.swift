//
//  RomLibrary.swift
//  EarthboundWrapper
//
//  Getting a ROM into the app, and keeping track of the ones that are there.
//
//  Two ways in, because the two ways people actually have a ROM on their phone are
//  different: the in-app picker for a file already in Files or iCloud Drive, and
//  the share sheet for a file that just arrived over AirDrop. The second one
//  arrives as an "open with" URL rather than through a picker, and it comes with a
//  security-scoped bookmark, which is why importing is not just a file copy.
//

import Foundation
import Observation
import os

@MainActor
@Observable
final class RomLibrary {
    /// ROMs available to play, newest first.
    private(set) var roms: [RomDescriptor] = []
    /// Set when an import failed, for the UI to show. Cleared on the next attempt.
    var importFailure: String?

    private let log = Logger(subsystem: "dev.nikan.earthbound", category: "library")

    /// Stored in the app's Documents directory rather than referenced in place, so
    /// a file in a temporary AirDrop folder survives the next launch. It also means
    /// the ROM is visible to the Files app, which is how a player replaces one.
    static var romsDirectory: URL {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let directory = documents.appendingPathComponent("Roms", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    /// snes9x accepts all of these. `.smc` and `.fig` are the same data with a
    /// 512-byte copier header, and `.swc` is the split variant; the core handles
    /// the header itself.
    static let acceptedExtensions: Set<String> = ["sfc", "smc", "fig", "swc", "bin"]

    static func isAccepted(_ url: URL) -> Bool {
        acceptedExtensions.contains(url.pathExtension.lowercased())
    }

    init() {
        refresh()
    }

    func refresh() {
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: Self.romsDirectory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles])) ?? []

        roms = contents
            .filter { Self.isAccepted($0) && !$0.hasDirectoryPath }
            .map(RomDescriptor.init(url:))
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    // MARK: - Importing

    /// Copies a ROM into the library.
    ///
    /// The incoming URL may be security-scoped (anything from the picker, the share
    /// sheet or AirDrop is), so access has to be opened and closed around the read.
    /// Forgetting to close it leaks a sandbox extension for the life of the process.
    @discardableResult
    func importRom(from source: URL) -> RomDescriptor? {
        defer { importFailure = nil }

        guard Self.isAccepted(source) else {
            let extensionName = source.pathExtension.isEmpty
                ? "no file extension" : ".\(source.pathExtension)"
            importFailure = "\(source.lastPathComponent) has \(extensionName). SNES ROMs are .sfc, .smc, .fig or .swc."
            return nil
        }

        let needsScope = source.startAccessingSecurityScopedResource()
        defer { if needsScope { source.stopAccessingSecurityScopedResource() } }

        let destination = Self.romsDirectory.appendingPathComponent(source.lastPathComponent)
        do {
            // Replace rather than merge: re-importing the same ROM is how you fix a
            // truncated AirDrop, and it should overwrite without asking.
            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: destination)
            }
            try FileManager.default.copyItem(at: source, to: destination)
            log.info("imported \(destination.lastPathComponent, privacy: .public)")
        } catch {
            importFailure = "Could not copy \(source.lastPathComponent): \(error.localizedDescription)"
            return nil
        }

        refresh()
        return roms.first { $0.url.lastPathComponent == destination.lastPathComponent }
    }

    /// Handles a URL the system opened the app with.
    ///
    /// The file arrives outside our container, so it is copied in rather than
    /// played from where it is: a URL that came with a security scope stops working
    /// as soon as the scope closes, which for an "open with" is immediately.
    @discardableResult
    func handleIncomingURL(_ url: URL) -> RomDescriptor? {
        if Self.isAccepted(url) {
            return importRom(from: url)
        }
        // A shared ZIP or a folder is out of scope; say so rather than appearing to
        // do nothing.
        importFailure = "\(url.lastPathComponent) is not a SNES ROM. Import a .sfc, .smc, .fig or .swc file."
        return nil
    }

    /// Opens a ROM dropped into the app's Documents directory by the Files app.
    /// The picker handles the in-app path; this is for `LSSupportsOpeningDocumentsInPlace`.
    func adoptLooseROMsInDocuments() {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: documents, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
        for url in contents where Self.isAccepted(url) && !url.hasDirectoryPath {
            let destination = Self.romsDirectory.appendingPathComponent(url.lastPathComponent)
            guard !FileManager.default.fileExists(atPath: destination.path) else { continue }
            try? FileManager.default.moveItem(at: url, to: destination)
        }
        refresh()
    }

    func delete(_ rom: RomDescriptor) {
        try? FileManager.default.removeItem(at: rom.url)
        // Saves are left behind on purpose: deleting a ROM by accident should not
        // also throw away a playthrough.
        refresh()
    }

    // MARK: - Core availability

    /// The core's own name and version. Doubles as proof that the C++ core linked
    /// and answered through the glue layer, which is the first thing worth knowing
    /// when a build misbehaves.
    var coreDescription: String {
        let info = RetroEnvironment.shared.systemInfo()
        return "\(info.libraryName) \(info.libraryVersion)"
    }
}
