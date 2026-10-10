#if os(macOS)
import SwiftUI
import SupersEmuKit

/// Where the library lives, free space, and Move Library (copy, verify, switch, then remove the old copy).
struct StorageView: View {
    let model: LibraryManagerModel
    @State private var confirmMoveBack = false

    var body: some View {
        Form {
            if let storage = model.storage {
                locationSection(storage)
                moveSection(storage)
            } else {
                Section { ProgressView() }
            }
            if let error = model.error {
                Section { Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red) }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Storage")
        .task {
            await model.refreshStorage()
            while !Task.isCancelled, model.storage?.move?.isRunning != true {
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                await model.refreshStorage()
            }
        }
        .alert("Move the library back to the data folder?", isPresented: $confirmMoveBack) {
            Button("Move Back") { Task { await model.move(to: model.storage?.dataDirectory ?? "") } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Games are copied back and checked before the copy on the drive is removed.")
        }
    }

    private func locationSection(_ storage: StorageStatus) -> some View {
        Section("Library") {
            if !storage.available {
                Label("The drive with your library isn't connected. Connect it and the server picks it up again; until then games can't be played or added.",
                      systemImage: "externaldrive.badge.exclamationmark")
                    .foregroundStyle(.red)
            }
            LabeledContent("Location") {
                Text(storage.libraryDirectory).textSelection(.enabled).lineLimit(1).truncationMode(.middle)
            }
            LabeledContent("Free space", value: storage.freeBytes.map(LibraryImportView.bytes) ?? "Unknown")
            LabeledContent("Library size", value: LibraryImportView.bytes(storage.libraryBytes))
            LabeledContent("Settings and saves") {
                Text(storage.dataDirectory).textSelection(.enabled).lineLimit(1).truncationMode(.middle)
            }
            if model.server.isLocal, storage.available {
                Button("Show in Finder") { NSWorkspace.shared.open(URL(fileURLWithPath: storage.libraryDirectory, isDirectory: true)) }
            }
        }
    }

    private func moveSection(_ storage: StorageStatus) -> some View {
        Section("Move Library") {
            Text("Moves games, BIOS files, artwork and Incoming to another folder or an external drive. Everything is copied and verified first; the server switches only when every file matches, then removes the old copy. Settings, users and saves stay in the data folder.")
                .font(.callout).foregroundStyle(.secondary)
            if let move = storage.move { moveStatus(move) }
            if model.server.isLocal {
                HStack {
                    Button("Move Library…") { model.chooseMoveDestination() }
                    if !storage.isDefault { Button("Move Back to Data Folder…") { confirmMoveBack = true } }
                }
                .disabled(storage.move?.isRunning == true || !storage.available)
            } else {
                Text("Moving the library is done in Server Mode on the server Mac.").font(.callout).foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder private func moveStatus(_ move: StorageMove) -> some View {
        switch move.phase {
        case .done:
            Label("Moved to \(move.destination)", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
        case .failed:
            Label(move.error ?? "The move failed; nothing was changed.", systemImage: "xmark.octagon.fill").foregroundStyle(.red)
        default:
            ProgressView(value: Double(move.bytesDone), total: Double(max(move.bytesTotal, 1))) {
                Text(Self.phase(move.phase))
            } currentValueLabel: {
                Text("\(LibraryImportView.bytes(move.bytesDone)) of \(LibraryImportView.bytes(move.bytesTotal)) · \(move.destination)")
            }
        }
    }

    static func phase(_ phase: StorageMove.Phase) -> String {
        switch phase {
        case .copying: return "Copying…"
        case .verifying: return "Verifying every file…"
        case .switching: return "Switching to the new location…"
        case .cleaning: return "Removing the old copy…"
        case .done: return "Done"
        case .failed: return "Failed"
        }
    }
}
#endif
