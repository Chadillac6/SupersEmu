#if os(macOS)
import SwiftUI
import SupersEmuKit

/// BIOS files from Chad's own consoles: what's present, missing or wrong, and which games need them.
/// SupersEmu never bundles or downloads BIOS files. Dreamcast's BIOS is optional (Flycast has a built-in one).
struct BIOSView: View {
    let model: LibraryManagerModel

    private var systems: [SystemID] { SystemID.allCases.filter(\.usesBIOS) }

    var body: some View {
        Form {
            Section {
                DropZone(title: "Drop BIOS files from your own consoles here",
                         subtitle: "Files are checked against known good dumps. SupersEmu never downloads BIOS files.",
                         systemImage: "cpu")
                Button("Add BIOS Files…") { model.chooseAndImport(title: "Add BIOS Files") }.disabled(!model.canImport)
                if let progress = model.progress {
                    ProgressView(value: Double(progress.bytesDone), total: Double(max(progress.bytesTotal, 1))) {
                        Text(progress.scanning ? "Checking…" : "Uploading \(progress.current)")
                    }
                }
                if let error = model.error { Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red) }
            }
            ForEach(systems, id: \.self) { system in
                Section(system.displayName) {
                    Text(Self.purpose(system)).font(.callout).foregroundStyle(.secondary)
                    readiness(system)
                    ForEach(model.bios.filter { $0.system == system }, id: \.filename) { row($0) }
                    if system.requiresBIOS { gamesNeeding(system) }
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("BIOS")
        .task { await model.refreshStorage(); await model.refreshBIOS() }
    }

    private func row(_ status: BIOSStatus) -> some View {
        LabeledContent {
            switch status.state {
            case .present: Label("Present", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
            case .missing: Label(status.required ? "Missing" : "Not added", systemImage: "circle.dashed").foregroundStyle(status.required ? .orange : .secondary)
            case .wrongHash: Label("Wrong file", systemImage: "xmark.octagon.fill").foregroundStyle(.red)
            }
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(status.filename).font(.body.monospaced())
                Text("\(status.region)\(status.required ? "" : " · optional")").font(.caption).foregroundStyle(.secondary)
                if status.state == .wrongHash {
                    Text("A file with this name was added but it isn't a known good dump; it was not stored. See Review Needed.")
                        .font(.caption).foregroundStyle(.red)
                }
            }
        }
    }

    /// Any one good BIOS is enough for a system (region matching isn't implemented), so say so up front.
    @ViewBuilder private func readiness(_ system: SystemID) -> some View {
        let present = model.bios.contains { $0.system == system && $0.state == .present }
        if present {
            Label("Ready", systemImage: "checkmark.seal.fill").foregroundStyle(.green)
        } else if system.requiresBIOS {
            Label("Needs one BIOS file before these games can start", systemImage: "exclamationmark.circle.fill").foregroundStyle(.orange)
        } else {
            Label("Optional: games start without it", systemImage: "info.circle").foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private func gamesNeeding(_ system: SystemID) -> some View {
        let games = model.biosGames.filter { $0.system == system }
        if games.isEmpty {
            Text("No \(system.displayName) games in the library yet.").font(.callout).foregroundStyle(.secondary)
        } else {
            DisclosureGroup("\(games.count) game\(games.count == 1 ? "" : "s") need\(games.count == 1 ? "s" : "") it") {
                ForEach(games) { Text($0.title) }
            }
        }
    }

    static func purpose(_ system: SystemID) -> String {
        switch system {
        case .psx: return "PlayStation games start through the console's BIOS. Add the one for your games' region (USA, Japan or Europe); without it they won't boot."
        case .segacd: return "Sega CD games boot through the Sega CD BIOS for their region. The core can't run them without it."
        case .dreamcast: return "Optional. Dreamcast games start with the emulator's built-in BIOS; adding dc_boot.bin and dc_flash.bin from your own Dreamcast helps the few games that need the real one."
        case .ps2: return "PlayStation 2 games need a BIOS from your own PS2 (any region works). Games play on the Mac only. Any known PS2 BIOS revision is accepted, not just the ones listed."
        default: return "Games for this console need its BIOS."
        }
    }
}
#endif
