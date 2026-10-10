#if os(macOS)
import SwiftUI
import SupersEmuKit

/// Everything the importer couldn't settle, why, and the fixes that are safe.
struct ReviewNeededView: View {
    let model: LibraryManagerModel
    @State private var pendingDelete: LibraryIssue?

    var body: some View {
        Form {
            if let error = model.error {
                Section { Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red) }
            }
            if model.issues.isEmpty {
                Section {
                    ContentUnavailableView("Nothing needs review", systemImage: "checkmark.seal",
                                           description: Text("Files the server can't sort on its own show up here."))
                }
            } else {
                Section {
                    ForEach(model.issues) { row($0) }
                } header: {
                    HStack {
                        Text("\(model.issues.count) item\(model.issues.count == 1 ? "" : "s")")
                        Spacer()
                        Button("Retry All") { Task { await model.scan() } }.disabled(!model.canImport)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Review Needed")
        .task { await model.refreshStorage(); await model.refreshIssues() }
        .confirmationDialog("Delete \(pendingDelete?.filename ?? "")?", isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
                            presenting: pendingDelete) { issue in
            Button("Delete", role: .destructive) { Task { await model.delete(issue) } }
        } message: { issue in
            Text(issue.incomingPath != nil ? "The file is removed from the server's Incoming folder." : "The queued copy is removed from the server.")
        }
    }

    private func row(_ issue: LibraryIssue) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: Self.icon(issue.kind)).font(.title2).foregroundStyle(.orange).frame(width: 28)
            VStack(alignment: .leading, spacing: 4) {
                Text(issue.filename).font(.headline).textSelection(.enabled)
                Text(Self.title(issue.kind)).font(.subheadline.weight(.medium))
                Text(issue.reason).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                if let hint = Self.hint(issue.kind, canPick: !issue.candidateSystems.isEmpty) { Text(hint).font(.callout).foregroundStyle(.secondary) }
                if let path = issue.incomingPath {
                    Text("Incoming/\(path)").font(.caption.monospaced()).foregroundStyle(.tertiary).lineLimit(1).truncationMode(.middle)
                }
                HStack {
                    if !issue.candidateSystems.isEmpty {
                        Menu("Pick Console") {
                            ForEach(issue.candidateSystems, id: \.self) { system in
                                Button(system.displayName) { Task { await model.assign(issue, to: system) } }
                            }
                        }
                        .fixedSize()
                    }
                    if issue.kind == .missingFiles { Button("Retry") { Task { await model.scan() } }.disabled(!model.canImport) }
                    if issue.incomingPath != nil, model.server.isLocal { Button("Show in Finder") { model.revealInIncoming(issue) } }
                    Button("Delete…", role: .destructive) { pendingDelete = issue }
                }
                .padding(.top, 2)
            }
        }
        .padding(.vertical, 4)
    }

    static func title(_ kind: LibraryIssue.Kind) -> String {
        switch kind {
        case .missingFiles: return "Missing files"
        case .unknownSystem: return "Unknown console"
        case .ambiguous: return "Couldn't tell which console"
        case .unsupportedFormat: return "Unsupported format"
        case .wrongBIOS: return "Not a known good BIOS"
        case .other: return "Needs attention"
        }
    }

    static func icon(_ kind: LibraryIssue.Kind) -> String {
        switch kind {
        case .missingFiles: return "doc.badge.ellipsis"
        case .unknownSystem: return "questionmark.square.dashed"
        case .ambiguous: return "questionmark.diamond"
        case .unsupportedFormat: return "nosign"
        case .wrongBIOS: return "cpu"
        case .other: return "exclamationmark.triangle"
        }
    }

    static func hint(_ kind: LibraryIssue.Kind, canPick: Bool) -> String? {
        switch kind {
        case .unknownSystem where !canPick, .ambiguous where !canPick: return "It doesn't look like a game SupersEmu can play. Delete it, or add a good copy."
        case .missingFiles: return "Add the missing files to the same folder (drop the whole folder again), then Retry."
        case .unknownSystem, .ambiguous: return "If you know which console it's for, pick it. Otherwise delete it."
        case .unsupportedFormat: return "Convert it to .chd or .cue/.bin, add the converted copy, then delete this one."
        case .wrongBIOS: return "Its name matches a BIOS but its contents don't. Dump the BIOS from your console again."
        case .other: return nil
        }
    }
}
#endif
