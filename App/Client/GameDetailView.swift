import SupersEmuKit
import SwiftUI

struct GameDetailView: View {
    @Environment(ServerSession.self) private var server
    @Environment(DownloadCenter.self) private var downloads
    @Environment(BIOSCenter.self) private var bios
    @Environment(\.dismiss) private var dismiss
    let item: LibraryItem
    let onPlay: (Game) -> Void
    @State private var detail: GameDetail?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack(alignment: .top, spacing: 20) {
                    CoverArt(item: item).frame(width: 150)
                    VStack(alignment: .leading, spacing: 8) {
                        Text(item.title).font(.title.bold()).accessibilityIdentifier("detail-title")
                        Text(metadata).foregroundStyle(.secondary)
                        AvailabilityBadge(item: item, state: downloads.states[item.id])
                    }
                }
                if let system = item.system, bios.isMissing(system) {
                    Label {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(system.missingBIOSMessage).font(.headline)
                            Text("Add the BIOS file to \(server.serverName) and it will sync to this device automatically.")
                                .font(.callout).foregroundStyle(.secondary)
                        }
                    } icon: {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("needs-bios")
                }
                actions
                if let detail = gameDetail, detail.discCount > 1 {
                    Label("\(detail.discCount) discs · \(Self.size(detail.totalFileSize)) total", systemImage: "opticaldisc")
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("disc-count")
                }
                if let summary = detail?.summary, !summary.isEmpty {
                    Text(summary).foregroundStyle(.secondary)
                }
                if let files = gameDetail?.files, files.count > 1 {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Files").font(.headline)
                        ForEach(files) { file in
                            Text("\(file.filename) · \(Self.size(file.size))").font(.callout).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .padding(24)
        }
        .frame(minWidth: 360, idealWidth: 520, minHeight: 360)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() }.accessibilityIdentifier("detail-done") }
        }
        .task(id: item.id) {
            if item.system?.requiresBIOS == true { await bios.sync(using: server) }
            guard item.source == .server, server.isOnline else { return }
            detail = try? await server.detail(for: item.id)
        }
    }

    private var metadata: String {
        var parts = [item.console]
        if let year = item.year { parts.append(String(year)) }
        if let genre = item.genre { parts.append(genre) }
        if item.size > 0 { parts.append(Self.size(item.size)) }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder private var actions: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let game = playableGame {
                Button {
                    dismiss()
                    onPlay(game)
                } label: {
                    Label(game.hasResumePoint ? "Resume" : "Play", systemImage: "play.fill").frame(minWidth: 140)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(bios.isMissing(item.system) || bios.isSyncing && item.system?.requiresBIOS == true)
                .accessibilityIdentifier("detail-play")
            }
            if item.source == .server {
                switch downloads.states[item.id] {
                case .downloading(let progress):
                    VStack(alignment: .leading, spacing: 6) {
                        ProgressView(value: progress.fraction).accessibilityIdentifier("download-progress")
                        HStack {
                            Text("Downloading \(Self.size(progress.receivedBytes)) of \(Self.size(progress.totalBytes))")
                                .font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                            Spacer()
                            Button("Cancel") { downloads.cancel(item.id) }.accessibilityIdentifier("download-cancel")
                        }
                    }
                case .failed(let message):
                    Label(message, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    downloadButton(title: "Retry Download")
                case nil:
                    if downloads.isDownloaded(item.id) {
                        if playableGame == nil {
                            Label("\(item.console) games can't be played in this version yet.", systemImage: "info.circle")
                                .foregroundStyle(.secondary)
                                .accessibilityIdentifier("unsupported-system")
                        }
                        Button(role: .destructive) { downloads.remove(item.id) } label: {
                            Label("Remove Download", systemImage: "trash")
                        }
                        .accessibilityIdentifier("remove-download")
                    } else if server.isOnline {
                        downloadButton(title: "Download (\(Self.size(item.size)))")
                    } else {
                        Text("Connect to \(server.serverName) to download this game.").foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    /// The server's detail, or the downloaded copy's when offline.
    private var gameDetail: GameDetail? { detail ?? downloads.downloaded[item.id]?.detail }

    private var playableGame: Game? {
        item.source == .server ? downloads.playableGame(item.id) : item.playable
    }

    private func downloadButton(title: String) -> some View {
        Button { downloads.start(item.id, session: server) } label: {
            Label(title, systemImage: "arrow.down.circle.fill").frame(minWidth: 140)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        .disabled(!server.isOnline)
        .accessibilityIdentifier("download-game")
    }

    static func size(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}

/// "Downloaded" / "Cloud" / "On this device" / live percentage.
struct AvailabilityBadge: View {
    let item: LibraryItem
    let state: DownloadCenter.State?

    var body: some View {
        Label(text, systemImage: symbol)
            .font(.caption.bold())
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(.ultraThinMaterial, in: Capsule())
            .accessibilityIdentifier("availability-badge")
    }

    private var text: String {
        if case .downloading(let progress) = state { return "\(Int(progress.fraction * 100))%" }
        if case .failed = state { return "Download failed" }
        switch item.source {
        case .local: return "On this device"
        case .server: return item.isDownloaded ? "Downloaded" : "Cloud"
        }
    }

    private var symbol: String {
        if case .downloading = state { return "arrow.down.circle" }
        if case .failed = state { return "exclamationmark.triangle" }
        switch item.source {
        case .local: return "internaldrive"
        case .server: return item.isDownloaded ? "checkmark.circle.fill" : "icloud"
        }
    }
}
