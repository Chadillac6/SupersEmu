import SwiftUI
import SupersEmuKit

/// Saved codes for one game: toggle, edit, delete, add one, or paste many.
struct CheatsView: View {
    let gameID: String
    let title: String
    let system: SystemID
    @Environment(\.dismiss) private var dismiss
    @State private var library = CheatLibrary.shared
    @State private var editing: CheatRecord?
    @State private var isAdding = false
    @State private var isPasting = false
    @State private var selection: UUID?
    @State private var errorMessage: String?

    private var cheats: [CheatRecord] { library.cheats(for: gameID) }

    var body: some View {
        NavigationStack {
            List(selection: $selection) {
                Section {
                    if cheats.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("No cheats yet").font(.headline)
                            Text("Add a \(CheatCodec.formats(for: system).first?.displayName ?? "cheat") code, or paste a list with one code per line.")
                                .font(.callout).foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 6)
                        .accessibilityIdentifier("cheats-empty")
                    }
                    ForEach(cheats) { cheat in
                        CheatRow(cheat: cheat, system: system) { enabled in
                            var updated = cheat
                            updated.setEnabled(enabled)
                            save([updated])
                        }
                        .tag(cheat.id)
                        .contentShape(Rectangle())
                        .onTapGesture(count: 2) { editing = cheat }
                        .contextMenu {
                            Button("Edit") { editing = cheat }
                            Button("Delete", role: .destructive) { delete(cheat) }
                        }
                        .swipeActions {
                            Button("Delete", role: .destructive) { delete(cheat) }
                            Button("Edit") { editing = cheat }
                        }
                    }
                } footer: {
                    Text("New cheats start on. Cheats are matched to this exact ROM, and saves made with cheats on sync as usual.")
                }
                Section {
                    HStack(spacing: 8) {
                        if library.isSyncing { ProgressView().controlSize(.small) }
                        Image(systemName: library.statusIsProblem ? "exclamationmark.icloud" : "checkmark.icloud")
                            .foregroundStyle(library.statusIsProblem ? .orange : .secondary)
                        Text(library.statusText).font(.caption).foregroundStyle(.secondary)
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("cheats-sync-status")
                }
            }
            #if os(macOS)
            .onDeleteCommand { if let cheat = selected { delete(cheat) } }
            .onKeyPress(.space) {
                guard let cheat = selected else { return .ignored }
                var updated = cheat
                updated.setEnabled(!cheat.enabled)
                save([updated])
                return .handled
            }
            .onKeyPress(.return) {
                guard let cheat = selected else { return .ignored }
                editing = cheat
                return .handled
            }
            #endif
            .navigationTitle("Cheats")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }.accessibilityIdentifier("cheats-done")
                }
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        Button { isAdding = true } label: { Label("Add Code", systemImage: "plus") }
                            .keyboardShortcut("n", modifiers: .command)
                            .accessibilityIdentifier("cheats-add")
                        Button { isPasting = true } label: { Label("Paste Several Codes", systemImage: "doc.on.clipboard") }
                            .accessibilityIdentifier("cheats-paste")
                    } label: {
                        Label("Add", systemImage: "plus")
                    } primaryAction: {
                        isAdding = true
                    }
                    .accessibilityIdentifier("cheats-add-menu")
                }
            }
            .alert("Couldn't save cheat", isPresented: .init(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
                Button("OK", role: .cancel) {}
            } message: { Text(errorMessage ?? "") }
            .sheet(isPresented: $isAdding) {
                CheatEditor(gameID: gameID, system: system, existing: nil, defaultLabel: CheatCodec.defaultLabel(index: cheats.count + 1)) { save([$0]) }
            }
            .sheet(item: $editing) { cheat in
                CheatEditor(gameID: gameID, system: system, existing: cheat, defaultLabel: cheat.label) { save([$0]) }
            }
            .sheet(isPresented: $isPasting) {
                CheatPasteView(gameID: gameID, system: system, existingCount: cheats.count) { save($0) }
            }
        }
        .task {
            await library.load(gameID)
            await library.sync()
        }
        #if os(macOS)
        .frame(minWidth: 520, minHeight: 420)
        #endif
        .accessibilityIdentifier("cheats-view")
    }

    private var selected: CheatRecord? { cheats.first { $0.id == selection } }

    private func save(_ records: [CheatRecord]) {
        Task {
            do { try await library.save(records) } catch { errorMessage = error.localizedDescription }
        }
    }

    private func delete(_ cheat: CheatRecord) {
        Task {
            do { try await library.delete(cheat) } catch { errorMessage = error.localizedDescription }
        }
    }
}

struct CheatRow: View {
    let cheat: CheatRecord
    let system: SystemID
    let onToggle: (Bool) -> Void

    var body: some View {
        let result = CheatCodec.parse(cheat.code, system: system)
        Toggle(isOn: .init(get: { cheat.enabled }, set: onToggle)) {
            VStack(alignment: .leading, spacing: 2) {
                Text(cheat.label.isEmpty ? "Untitled cheat" : cheat.label)
                Text(cheat.code).font(.caption.monospaced()).foregroundStyle(.secondary)
                switch result {
                case .valid: EmptyView()
                case .invalid(let reason), .unsupported(_, _, let reason):
                    Label(reason, systemImage: "exclamationmark.triangle")
                        .font(.caption).foregroundStyle(.orange)
                }
            }
        }
        .accessibilityIdentifier("cheat-row-\(cheat.label)")
        .accessibilityValue(cheat.enabled ? "On" : "Off")
    }
}

/// Add or edit one code. Save stays off until the code is valid for this system.
struct CheatEditor: View {
    let gameID: String
    let system: SystemID
    let existing: CheatRecord?
    let defaultLabel: String
    let onSave: (CheatRecord) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var label = ""
    @State private var code = ""
    @FocusState private var codeFocused: Bool

    var body: some View {
        let result = CheatCodec.parse(code, system: system)
        NavigationStack {
            Form {
                Section("Name") {
                    TextField(defaultLabel, text: $label).accessibilityIdentifier("cheat-label")
                }
                Section {
                    Group {
                        if usesMultilineInput {
                            TextField("Code", text: $code, prompt: Text(placeholder), axis: .vertical)
                                .lineLimit(1...8)
                                .labelsHidden()
                        } else {
                            TextField("Code", text: $code, prompt: Text(placeholder))
                                .labelsHidden()
                                .onSubmit(save)
                        }
                    }
                    .font(.body.monospaced())
                    .autocorrectionDisabled()
                    #if os(iOS)
                    .textInputAutocapitalization(.characters)
                    #endif
                    .focused($codeFocused)
                    .accessibilityIdentifier("cheat-code")
                } header: {
                    Text(CheatCodec.formats(for: system).map(\.displayName).joined(separator: " or "))
                } footer: {
                    feedback(result).accessibilityIdentifier("cheat-code-feedback")
                }
            }
            .formStyle(.grouped)
            .navigationTitle(existing == nil ? "Add Cheat" : "Edit Cheat")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save", action: save).disabled(!result.isValid).accessibilityIdentifier("cheat-save")
                }
            }
        }
        .onAppear {
            label = existing?.label ?? ""
            code = existing?.code ?? ""
            codeFocused = true
        }
        #if os(macOS)
        .frame(minWidth: 420, minHeight: 300)
        #endif
    }

    private var usesMultilineInput: Bool { CheatCodec.allowsMultiline(system) }

    private var placeholder: String {
        switch system {
        case .snes: "C2C3-CF0D"
        case .genesis, .sega32x: "RFAA-A6VR"
        case .segacd: "FF0123:0063"
        case .gb, .gbc: "00A-17B-C49"
        case .gba: "XXXXXXXX XXXXXXXX"
        case .psx, .n64: "8009C6E4 03E7"
        }
    }

    @ViewBuilder private func feedback(_ result: CheatParseResult) -> some View {
        if code.trimmingCharacters(in: .whitespaces).isEmpty {
            Text("Codes look like \(placeholder). Lowercase and a missing dash are fine.")
        } else {
            switch result {
            case .valid(let format, let normalized, let address, let value):
                if usesMultilineInput {
                    let count = normalized.split(separator: "\n").count
                    let lineLabel = count == 1 ? "line" : "lines"
                    Label("Valid \(format.displayName) (\(count) \(lineLabel))", systemImage: "checkmark.circle").foregroundStyle(.green)
                } else {
                    Label("Valid \(format.displayName): \(normalized) → $\(String(address, radix: 16, uppercase: true)) = \(String(value, radix: 16, uppercase: true))",
                          systemImage: "checkmark.circle").foregroundStyle(.green)
                }
            case .invalid(let reason):
                Label(reason, systemImage: "xmark.circle").foregroundStyle(.red)
            case .unsupported(_, _, let reason):
                Label(reason, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
            }
        }
    }

    private func save() {
        guard case .valid(let format, let normalized, _, _) = CheatCodec.parse(code, system: system) else { return }
        let name = label.trimmingCharacters(in: .whitespaces).isEmpty ? defaultLabel : label.trimmingCharacters(in: .whitespaces)
        if var record = existing {
            if record.label != name { record.setLabel(name) }
            if record.code != normalized { record.setCode(normalized, format: format) }
            onSave(record)
        } else {
            onSave(CheatRecord(gameID: gameID, label: name, code: normalized, format: format))
        }
        dismiss()
    }
}

/// Paste many codes, review what was understood, then save the checked ones.
struct CheatPasteView: View {
    let gameID: String
    let system: SystemID
    let existingCount: Int
    let onSave: ([CheatRecord]) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var entries: [CheatBatchEntry] = []
    @State private var isReviewing = false

    var body: some View {
        NavigationStack {
            Group {
                if isReviewing { review } else { editor }
            }
            .navigationTitle(isReviewing ? "Review Codes" : "Paste Codes")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(isReviewing ? "Back" : "Cancel") { isReviewing ? (isReviewing = false) : dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if isReviewing {
                        Button("Save \(entries.filter(\.include).count)", action: save)
                            .disabled(!entries.contains(where: \.include))
                            .accessibilityIdentifier("cheat-batch-save")
                    } else {
                        Button("Review") {
                            entries = CheatCodec.parseBatch(text, system: system, existingCount: existingCount)
                            isReviewing = true
                        }
                        .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        .accessibilityIdentifier("cheat-batch-review")
                    }
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 520, minHeight: 420)
        #endif
    }

    private var editor: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(editorHelpText)
                .font(.callout).foregroundStyle(.secondary)
            TextEditor(text: $text)
                .font(.body.monospaced())
                .autocorrectionDisabled()
                .scrollContentBackground(.hidden)
                .padding(6)
                .background(Color.secondary.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
                .accessibilityIdentifier("cheat-batch-text")
        }
        .padding()
    }

    private var editorHelpText: String {
        let help = "One code per line. Words on the same line become its name, e.g. \"Infinite lives C2C3-CF0D\"."
        guard CheatCodec.allowsMultiline(system) else { return help }
        return help + " For a code that spans several lines, put its name on its own line above it."
    }

    private var review: some View {
        List {
            ForEach($entries) { $entry in
                VStack(alignment: .leading, spacing: 4) {
                    Toggle(isOn: $entry.include) {
                        TextField("Name", text: $entry.label).accessibilityIdentifier("cheat-batch-label-\(entry.id)")
                    }
                    .disabled(!entry.result.isValid)
                    Text(entry.result.normalized ?? entry.input).font(.caption.monospaced()).foregroundStyle(.secondary)
                    switch entry.result {
                    case .valid: Label("Valid", systemImage: "checkmark.circle").font(.caption).foregroundStyle(.green)
                    case .invalid(let reason): Label(reason, systemImage: "xmark.circle").font(.caption).foregroundStyle(.red)
                    case .unsupported(_, _, let reason): Label(reason, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange)
                    }
                }
                .accessibilityIdentifier("cheat-batch-entry-\(entry.id)")
            }
        }
    }

    private func save() {
        let records = entries.filter(\.include).compactMap { entry -> CheatRecord? in
            guard case .valid(let format, let code, _, _) = entry.result else { return nil }
            let label = entry.label.trimmingCharacters(in: .whitespaces)
            return CheatRecord(gameID: gameID, label: label.isEmpty ? CheatCodec.defaultLabel(index: existingCount + entry.id + 1) : label,
                               code: code, format: format)
        }
        onSave(records)
        dismiss()
    }
}

/// In-game Cheats list over the paused game. D-pad/arrows move, A/Start or Return toggles, B/Select or Esc closes.
struct CheatPicker: View {
    @Bindable var session: GameSession

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Cheats").font(.title3.bold())
            if session.cheats.isEmpty {
                Text("No cheats saved for this game. Add them from the game's details in your library.")
                    .font(.callout).foregroundStyle(.secondary)
                    .accessibilityIdentifier("cheat-picker-empty")
            }
            ScrollView {
                VStack(spacing: 6) {
                    ForEach(Array(session.cheats.enumerated()), id: \.element.id) { index, cheat in
                        row(cheat, index: index)
                    }
                }
            }
            .frame(maxHeight: 280)
            HStack {
                Text("↑↓ choose · A/Return toggle · B/Esc close")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Done") { session.closeCheatPicker() }
                    .keyboardShortcut(.cancelAction)
                    .accessibilityIdentifier("cheat-picker-done")
            }
        }
        .padding(22)
        .frame(width: 360)
        .brandPanel()
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("cheat-picker")
    }

    private func row(_ cheat: CheatRecord, index: Int) -> some View {
        let isSelected = index == session.cheatSelection
        let state = session.cheatStates[cheat.id] ?? .off
        return Button { session.setCheat(cheat.id, enabled: !cheat.enabled) } label: {
            HStack {
                Image(systemName: cheat.enabled ? "checkmark.circle.fill" : "circle")
                VStack(alignment: .leading, spacing: 2) {
                    Text(cheat.label).lineLimit(1)
                    Text(cheat.code).font(.caption.monospaced()).foregroundStyle(.secondary)
                }
                Spacer()
                Text(state.label)
                    .font(.caption)
                    .foregroundStyle(state == .rejected || state == .invalid ? .orange : .secondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .frame(maxWidth: .infinity, alignment: .leading)
            .foregroundStyle(isSelected ? .white : Brand.Colors.ink)
            .background(isSelected ? Brand.Colors.red : Brand.Colors.card, in: RoundedRectangle(cornerRadius: 10))
            .contentShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .keyboardShortcut(index == session.cheatSelection ? .defaultAction : nil)
        .accessibilityValue("\(cheat.enabled ? "On" : "Off"), \(state.label)")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityIdentifier("cheat-picker-\(index + 1)")
    }
}
