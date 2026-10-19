import SwiftUI

struct DiagnosticsView: View {
    var game: Game?

    @AppStorage(DiagnosticsSettings.Key.showPerformanceOverlay)
    private var showPerformanceOverlay = DiagnosticsSettings.Default.showPerformanceOverlay
    @AppStorage(DiagnosticsSettings.Key.recordLogs) private var recordSessionLogs = DiagnosticsSettings.Default.recordLogs
    @AppStorage(DiagnosticsSettings.Key.detailedCoreLogs)
    private var detailedCoreLogging = DiagnosticsSettings.Default.detailedCoreLogs
    @AppStorage(N64Preset.defaultKey) private var defaultPresetRawValue = N64Preset.balanced.rawValue
    @State private var gamePresetRawValue = "use-default"
    @State private var logs: [DiagnosticsLog.LogFile] = []
    @State private var isConfirmingDelete = false

    private var defaultPresetBinding: Binding<String> {
        Binding(
            get: { N64Preset(rawValue: defaultPresetRawValue)?.rawValue ?? N64Preset.balanced.rawValue },
            set: { defaultPresetRawValue = $0 })
    }

    var body: some View {
        Form {
            Section {
                Toggle("Show performance stats", isOn: $showPerformanceOverlay)
                    .accessibilityIdentifier("diagnostics-show-performance")
                Toggle("Record session logs", isOn: $recordSessionLogs)
                    .accessibilityIdentifier("diagnostics-record-logs")
                Toggle("Detailed core logging", isOn: $detailedCoreLogging)
                    .accessibilityIdentifier("diagnostics-detailed-core-logs")
            }

            Section {
                Picker("Default", selection: defaultPresetBinding) {
                    ForEach(N64Preset.allCases) { preset in
                        Text(preset.title).tag(preset.rawValue)
                    }
                }
                .accessibilityIdentifier("diagnostics-n64-default-preset")

                if let game, GameSession.system(for: game) == "n64" {
                    Picker("For \(game.title)", selection: gamePresetBinding(for: game)) {
                        Text("Use default").tag("use-default")
                        ForEach(N64Preset.allCases) { preset in
                            Text(preset.title).tag(preset.rawValue)
                        }
                    }
                    .accessibilityIdentifier("diagnostics-n64-game-preset")
                }
            } header: {
                Text("N64 settings")
            } footer: {
                Text("Takes effect the next time you open the game.")
            }

            Section("Logs") {
                if logs.isEmpty {
                    Text("No session logs yet")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(logs) { file in
                        ShareLink(item: file.url) {
                            VStack(alignment: .leading, spacing: 4) {
                                HStack {
                                    Text(file.gameTitle)
                                    Spacer()
                                    Text(ByteCountFormatter.string(fromByteCount: file.size, countStyle: .file))
                                        .foregroundStyle(.secondary)
                                }
                                Text(file.date.formatted(date: .abbreviated, time: .shortened))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .accessibilityIdentifier("diagnostics-log-\(file.url.lastPathComponent)")
                    }
                }
                Button("Delete All Logs", role: .destructive) {
                    isConfirmingDelete = true
                }
                .disabled(logs.isEmpty)
                .accessibilityIdentifier("diagnostics-delete-all-logs")
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Diagnostics")
        .onAppear {
            if let game {
                gamePresetRawValue = N64Preset.preset(forGameID: game.id)?.rawValue ?? "use-default"
            }
            refreshLogs()
        }
        .alert("Delete all diagnostic logs?", isPresented: $isConfirmingDelete) {
            Button("Delete All Logs", role: .destructive) {
                DiagnosticsLog.deleteAll()
                refreshLogs()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This cannot be undone.")
        }
    }

    private func gamePresetBinding(for game: Game) -> Binding<String> {
        Binding(
            get: { gamePresetRawValue },
            set: { value in
                gamePresetRawValue = value
                let preset = value == "use-default" ? nil : N64Preset(rawValue: value)
                N64Preset.setPreset(preset, forGameID: game.id)
            })
    }

    private func refreshLogs() {
        logs = DiagnosticsLog.files()
    }
}
