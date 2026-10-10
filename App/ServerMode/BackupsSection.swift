#if os(macOS)
import AppKit
import SwiftUI
import SupersEmuKit

/// Server mode › Backups: last result, destination, Back Up Now. Talks to /v1/admin/backups as the local admin.
struct BackupsSection: View {
    let model: ServerModeModel
    @State private var overview: BackupOverview?
    @State private var error: String?
    @State private var busy = false

    var body: some View {
        Section("Backups") {
            if let overview {
                LabeledContent("Last backup") { lastResult(overview) }
                LabeledContent("Destination") {
                    HStack(spacing: 6) {
                        if !overview.destinationAvailable {
                            Image(systemName: "externaldrive.badge.xmark").foregroundStyle(.orange).help("Not connected")
                        }
                        Text(overview.destination).textSelection(.enabled).lineLimit(1).truncationMode(.middle)
                        Button("Change…") { chooseDestination() }.disabled(busy)
                    }
                }
                LabeledContent("Schedule", value: schedule(overview))
                LabeledContent("Kept", value: "\(overview.backups.count) of the last \(overview.config.keep)"
                               + (overview.config.includeROMs ? ", with ROMs" : ", ROMs not included"))
            } else if model.health == nil {
                Text("Start the server to see backups.").foregroundStyle(.secondary)
            }
            HStack {
                Button("Back Up Now") { Task { await backUpNow() } }
                    .disabled(busy || model.health == nil || overview?.running == true)
                    .accessibilityIdentifier("back-up-now")
                if busy || overview?.running == true { ProgressView().controlSize(.small) }
            }
            if let error { Text(error).font(.callout).foregroundStyle(.red) }
        }
        .task(id: "\(model.source.rawValue)-\(model.health != nil)") { await load() }
    }

    @ViewBuilder private func lastResult(_ overview: BackupOverview) -> some View {
        if let last = overview.last {
            let when = last.at.formatted(date: .abbreviated, time: .shortened)
            if last.ok {
                Label("\(when) · OK (\(last.trigger.rawValue))", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .accessibilityIdentifier("backup-last-ok")
            } else {
                Label("\(when) · Failed: \(last.error ?? "unknown error")", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .lineLimit(2)
                    .accessibilityIdentifier("backup-last-failed")
            }
        } else {
            Text("Never").foregroundStyle(.secondary)
        }
    }

    private func schedule(_ overview: BackupOverview) -> String {
        guard overview.config.scheduleEnabled else { return "Off" }
        let next = overview.nextScheduledAt.map { ", next \($0.formatted(date: .abbreviated, time: .shortened))" } ?? ""
        return String(format: "Daily at %02d:00", overview.config.hour) + next
    }

    private func load() async {
        guard model.health != nil else { overview = nil; return }
        do {
            overview = try await model.adminClient().backups()
            error = nil
        } catch APIClientError.http(status: 404, _) {
            error = "This server doesn't support backups yet."
        } catch {
            self.error = "Couldn't load backups: \(error)"
        }
    }

    private func backUpNow() async {
        busy = true
        defer { busy = false }
        do {
            // Backups can take a while (especially with ROMs); don't use the window's short status timeout.
            _ = try await model.adminClient(timeout: 600).createBackup()
            error = nil
        } catch {
            self.error = "Backup failed: \(error)"
        }
        await load()
    }

    private func chooseDestination() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Back Up Here"
        panel.message = "Choose where server backups go, e.g. a folder on an external drive."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task {
            do {
                _ = try await model.adminClient().updateBackupConfig(.init(destination: url.path))
                error = nil
            } catch {
                self.error = "Couldn't change the destination: \(error)"
            }
            await load()
        }
    }
}
#endif
