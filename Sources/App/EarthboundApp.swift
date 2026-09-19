//
//  EarthboundApp.swift
//  EarthboundWrapper
//
//  Entry point and the ROM library.
//
//  The library is the whole first screen, because there is nothing else the app
//  needs to say. When it is empty the screen explains how to get a ROM in, since
//  the app cannot ship with one and a bare "Import" button is a poor hint.
//

import SwiftUI
import UniformTypeIdentifiers

@main
struct EarthboundApp: App {
    @State private var settings = AppSettings()
    @State private var library = RomLibrary()

    var body: some Scene {
        WindowGroup {
            LibraryScreen()
                .environment(settings)
                .environment(library)
                .preferredColorScheme(.dark)
                .onOpenURL { url in
                    // AirDrop, "Open in", and the share sheet all arrive here.
                    library.handleIncomingURL(url)
                }
                .onAppear {
                    // A ROM dropped into the app's Documents folder by the Files app
                    // lands next to the library rather than in it.
                    library.adoptLooseROMsInDocuments()
                }
        }
    }
}

struct LibraryScreen: View {
    @Environment(AppSettings.self) private var settings
    @Environment(RomLibrary.self) private var library

    @State private var activeRom: RomDescriptor?
    @State private var showImporter = false
    @State private var showSettings = false

    var body: some View {
        NavigationStack {
            Group {
                if library.roms.isEmpty {
                    emptyState
                } else {
                    romList
                }
            }
            .navigationTitle("Earthbound Wrapper")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        showSettings = true
                    } label: {
                        Image(systemName: "gearshape")
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showImporter = true
                    } label: {
                        Image(systemName: "plus")
                    }
                }
            }
            .safeAreaInset(edge: .bottom) { coreFooter }
        }
        .fileImporter(isPresented: $showImporter,
                      allowedContentTypes: importableTypes,
                      allowsMultipleSelection: false) { result in
            switch result {
            case .success(let urls):
                guard let url = urls.first else { return }
                if let rom = library.importRom(from: url) { activeRom = rom }
            case .failure(let error):
                library.importFailure = error.localizedDescription
            }
        }
        .fullScreenCover(item: $activeRom) { rom in
            GameScreen(rom: rom)
                .environment(settings)
        }
        .sheet(isPresented: $showSettings) {
            LibrarySettingsSheet(settings: settings)
        }
        .alert("Could not import that file",
               isPresented: Binding(get: { library.importFailure != nil },
                                    set: { if !$0 { library.importFailure = nil } })) {
            Button("OK", role: .cancel) { library.importFailure = nil }
        } message: {
            Text(library.importFailure ?? "")
        }
    }

    // MARK: - Content

    private var romList: some View {
        List {
            ForEach(library.roms) { rom in
                Button {
                    activeRom = rom
                } label: {
                    HStack(spacing: 14) {
                        Image(systemName: "gamecontroller.fill")
                            .font(.title3)
                            .foregroundStyle(.tint)
                            .frame(width: 28)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(rom.name)
                                .foregroundStyle(.primary)
                            HStack(spacing: 8) {
                                if rom.hasAnySavedState {
                                    Label("state", systemImage: "bookmark.fill")
                                }
                                if rom.hasSRAM {
                                    Label("battery save", systemImage: "battery.100")
                                }
                            }
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Image(systemName: "play.circle.fill")
                            .font(.title2)
                            .foregroundStyle(.tint)
                    }
                }
                .swipeActions {
                    Button(role: .destructive) {
                        library.delete(rom)
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
    }

    private var emptyState: some View {
        ScrollView {
            VStack(spacing: 18) {
                Image(systemName: "gamecontroller")
                    .font(.system(size: 52))
                    .foregroundStyle(.secondary)
                Text("No ROMs yet")
                    .font(.title2.weight(.semibold))
                Text("This app is the console, not the cartridge. Add a Super Nintendo ROM and it will show up here.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)

                VStack(alignment: .leading, spacing: 12) {
                    instruction(icon: "plus.circle",
                                title: "Import from Files",
                                detail: "Tap the + button. .sfc, .smc, .fig and .swc all work.")
                    instruction(icon: "square.and.arrow.down",
                                title: "AirDrop it to this device",
                                detail: "Choose this app when iOS asks what to open it with.")
                    instruction(icon: "folder",
                                title: "Or drop it in Files",
                                detail: "On My iPhone → Earthbound Wrapper. It is scanned for ROMs on launch.")
                }
                .padding(18)
                .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 16))

                Button {
                    showImporter = true
                } label: {
                    Label("Import a ROM", systemImage: "plus")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            }
            .padding(24)
            .frame(maxWidth: 520)
            .frame(maxWidth: .infinity)
        }
    }

    private func instruction(icon: String, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.title3)
                .frame(width: 26)
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.subheadline.weight(.semibold))
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var coreFooter: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(.green)
                .frame(width: 7, height: 7)
            Text("Core: \(library.coreDescription)")
                .font(.caption2)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 8)
        .background(.bar)
    }

    /// Types the picker will offer: everything that is a file.
    ///
    /// Deliberately `[.data]` rather than the ROM extensions. A picker restricted to
    /// named types greys out any file whose type iOS has not associated with them,
    /// and `.sfc` has no system type at all -- it exists only because this app
    /// declares it. Whenever that declaration is not in effect, a filtered picker
    /// offers nothing the player can tap, which is a dead end that looks like a
    /// permissions problem and gives no clue what to do about it.
    ///
    /// So the picker is a convenience and not the boundary. `RomLibrary.importRom`
    /// decides whether a file is playable, and says why when it refuses.
    private var importableTypes: [UTType] { [.data] }
}
