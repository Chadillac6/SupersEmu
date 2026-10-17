import SupersEmuKit
import SwiftUI

struct GameDetailView: View {
    @Environment(ServerSession.self) private var server
    @Environment(DownloadCenter.self) private var downloads
    @Environment(BIOSCenter.self) private var bios
    @Environment(\.dismiss) private var dismiss
    let item: LibraryItem
    let onPlay: (Game) -> Void
    let onStartFresh: (Game) -> Void
    @State private var detail: GameDetail?
    @State private var isConfirmingStartOver = false
    @State private var isShowingCheats = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                header
                VStack(alignment: .leading, spacing: 18) {
                    tags
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
                    if let summary = gameDetail?.summary, !summary.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(summary).foregroundStyle(.secondary).accessibilityIdentifier("detail-intro")
                            if let source = gameDetail?.summarySource, let url = source.url.flatMap(URL.init(string:)) {
                                Link("From \(source.name)", destination: url).font(.caption)
                            }
                        }
                    }
                    reviews
                    screenshots
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
        }
        .background(Brand.Colors.paper.ignoresSafeArea())
        .frame(minWidth: 360, idealWidth: 680, minHeight: 360, idealHeight: 760)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() }.accessibilityIdentifier("detail-done") }
        }
        .task(id: item.id) {
            if item.system?.requiresBIOS == true { await bios.sync(using: server) }
            guard item.source == .server, server.isOnline else { return }
            detail = try? await server.detail(for: item.id)
        }
    }

    private var header: some View {
        WideArt(item: item)
            .frame(height: 260)
            .overlay {
                LinearGradient(colors: [.clear, Brand.Colors.paper], startPoint: .center, endPoint: .bottom)
            }
            .overlay(alignment: .topLeading) {
                if let logo = item.logoPath ?? gameDetail?.logoPath {
                    RemoteArtwork(gameID: item.id, path: logo, contentMode: .fit) { EmptyView() }
                        .frame(maxWidth: 260, maxHeight: 80, alignment: .leading)
                        .padding(20)
                        .accessibilityHidden(true)
                }
            }
            .overlay(alignment: .bottomLeading) {
                HStack(alignment: .bottom, spacing: 18) {
                    CoverArt(item: item).frame(width: 110).shadow(radius: 10)
                    VStack(alignment: .leading, spacing: 6) {
                        Text(item.title).font(Brand.serifTitle).foregroundStyle(Brand.Colors.ink).lineLimit(3)
                            .accessibilityIdentifier("detail-title")
                        Text(metadata).font(Brand.eyebrow).tracking(1.2).foregroundStyle(Brand.Colors.ink2)
                        AvailabilityBadge(item: item, state: downloads.states[item.id])
                    }
                }
                .padding(.horizontal, 24)
                .offset(y: 40)
            }
            .padding(.bottom, 40)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("detail-hero")
    }

    private var tags: some View {
        let values = facts
        return VStack(spacing: 0) {
            ForEach(Array(values.enumerated()), id: \.offset) { index, fact in
                HStack(alignment: .firstTextBaseline) {
                    Text(fact.label.uppercased())
                        .font(Brand.eyebrow)
                        .tracking(1.2)
                        .foregroundStyle(Brand.Colors.ink3)
                    Spacer(minLength: 20)
                    Text(fact.value)
                        .foregroundStyle(Brand.Colors.ink)
                        .multilineTextAlignment(.trailing)
                }
                .padding(.vertical, 10)
                if index < values.count - 1 {
                    Rectangle().fill(Brand.Colors.line).frame(height: 1)
                }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("detail-tags")
    }

    private var facts: [(label: String, value: String)] {
        var rows: [(String, String)] = [("System", item.console)]
        if let year = item.year { rows.append(("Year", String(year))) }
        let genres = item.genres ?? item.genre.map { [$0] } ?? []
        if !genres.isEmpty { rows.append(("Genre", genres.joined(separator: ", "))) }
        if let players = item.players { rows.append(("Players", players > 1 ? "1–\(players)" : "1")) }
        if let publisher = gameDetail?.game.publisher, !publisher.isEmpty { rows.append(("Publisher", publisher)) }
        if let region = gameDetail?.game.region, !region.isEmpty { rows.append(("Region", region)) }
        return rows.map { (label: $0.0, value: $0.1) }
    }

    /// Critic score (IGDB, only when the server has a key), the Wikipedia reception summary and an IGN link.
    @ViewBuilder private var reviews: some View {
        let score = gameDetail?.game.criticScore
        let reception = gameDetail?.reception
        let link = gameDetail?.reviewLink.flatMap { link in URL(string: link.url).map { (link.name, $0) } }
        if score != nil || reception != nil || link != nil {
            VStack(alignment: .leading, spacing: 12) {
                Text("Reviews").font(.headline)
                if let score {
                    HStack(spacing: 12) {
                        Text("\(score.score)")
                            .font(.title2.bold().monospacedDigit())
                            .frame(width: 54, height: 54)
                            .foregroundStyle(.white)
                            .background(Self.scoreColor(score.score), in: RoundedRectangle(cornerRadius: 12))
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Critic score").font(.subheadline.bold())
                            Text(score.source).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("critic-score")
                }
                if let reception {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(reception.text).foregroundStyle(.secondary)
                        if let url = reception.url.flatMap(URL.init(string:)) {
                            Link(reception.source, destination: url).font(.caption)
                        }
                    }
                    .accessibilityIdentifier("reception")
                }
                if let (name, url) = link {
                    Link(destination: url) { Label("Read on \(name)", systemImage: "arrow.up.right.square") }
                        .accessibilityIdentifier("review-link")
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Brand.Colors.card, in: RoundedRectangle(cornerRadius: Brand.Radii.card))
            .overlay(RoundedRectangle(cornerRadius: Brand.Radii.card).stroke(Brand.Colors.line, lineWidth: 1))
        }
    }

    @ViewBuilder private var screenshots: some View {
        let paths = [gameDetail?.titleScreenPath].compactMap { $0 } + (gameDetail?.screenshotPaths ?? [])
        if !paths.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                Text("Screenshots").font(.headline)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 12) {
                        ForEach(paths, id: \.self) { path in
                            RemoteArtwork(gameID: item.id, path: path)
                                .frame(width: 220, height: 160)
                                .clipShape(RoundedRectangle(cornerRadius: 10))
                        }
                    }
                }
            }
            .accessibilityIdentifier("screenshots")
        }
    }

    static func scoreColor(_ score: Int) -> Color {
        score >= 75 ? Color(red: 79 / 255, green: 122 / 255, blue: 82 / 255)
            : score >= 50 ? Color(red: 176 / 255, green: 138 / 255, blue: 46 / 255) : Brand.Colors.red
    }

    private var metadata: String {
        var parts = [item.console]
        if let year = item.year { parts.append(String(year)) }
        if let genre = item.genre { parts.append(genre) }
        if item.size > 0 { parts.append(Self.size(item.size)) }
        return parts.joined(separator: " · ").uppercased()
    }

    private var cheatsTitle: String {
        let count = CheatLibrary.shared.cheats(for: item.id).count
        return count == 0 ? "Cheats" : "Cheats (\(count))"
    }

    private func stackedActions(_ game: Game) -> some View {
        VStack(spacing: 10) {
            playButton(game)
            HStack(spacing: 10) { secondaryActions(game, fill: true) }
        }
        .frame(maxWidth: 560)
        .frame(maxWidth: .infinity)
    }

    private var playIsDisabled: Bool {
        bios.isMissing(item.system) || bios.isSyncing && item.system?.requiresBIOS == true
    }

    private func playButton(_ game: Game) -> some View {
        Button {
            dismiss()
            onPlay(game)
        } label: {
            Label(game.hasResumePoint ? "Resume" : "Play", systemImage: "play.fill")
                .lineLimit(1)
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(BrandPrimaryButtonStyle())
        .controlSize(.large)
        .disabled(playIsDisabled)
        .accessibilityIdentifier("detail-play")
    }

    @ViewBuilder private func secondaryActions(_ game: Game, fill: Bool) -> some View {
        if game.hasResumePoint {
            Button {
                isConfirmingStartOver = true
            } label: {
            Label("Start over", systemImage: "arrow.counterclockwise")
                    .lineLimit(1)
                    .frame(minWidth: fill ? nil : 140, maxWidth: fill ? .infinity : nil)
            }
            .buttonStyle(BrandSecondaryButtonStyle())
            .controlSize(.large)
            .disabled(playIsDisabled)
            .accessibilityIdentifier("detail-start-over")
        }

        if let system = item.system, CheatCodec.supportsCheats(system) {
            Button {
                isShowingCheats = true
            } label: {
                Label(cheatsTitle, systemImage: "wand.and.stars")
                    .lineLimit(1)
                    .frame(minWidth: fill ? nil : 110, maxWidth: fill ? .infinity : nil)
            }
            .buttonStyle(BrandSecondaryButtonStyle())
            .controlSize(.large)
            .keyboardShortcut("c", modifiers: [.command, .shift])
            .help("Cheats (Shift-Command-C)")
            .accessibilityIdentifier("detail-cheats")
        }
    }

    @ViewBuilder private var actions: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let game = playableGame {
                stackedActions(game)
                .sheet(isPresented: $isShowingCheats) {
                    if let system = item.system {
                        CheatsView(gameID: item.id, title: item.title, system: system)
                    }
                }
                .task {
                    if let system = item.system, CheatCodec.supportsCheats(system) { await CheatLibrary.shared.load(item.id) }
                }
                .confirmationDialog("Start over from the beginning?", isPresented: $isConfirmingStartOver, titleVisibility: .visible) {
                    Button("Start over", role: .destructive) {
                        dismiss()
                        onStartFresh(game)
                    }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text("Unsaved progress since your last in-game save will be lost. In-game saves are kept.")
                }
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
                    } else if item.playable != nil {
                        Label("On this device", systemImage: "internaldrive").foregroundStyle(.secondary)
                    } else if server.isOnline {
                        downloadButton(title: "Download (\(Self.size(item.size)))")
                    } else {
                        Label("Unavailable offline. Connect to \(server.serverName) to download this game.", systemImage: "icloud.slash")
                            .foregroundStyle(.secondary)
                            .accessibilityIdentifier("unavailable-offline")
                    }
                }
            }
        }
    }

    /// The server's detail, or the downloaded copy's when offline.
    private var gameDetail: GameDetail? { detail ?? downloads.downloaded[item.id]?.detail }

    private var playableGame: Game? {
        item.source == .server ? downloads.playableGame(item.id) ?? item.playable : item.playable
    }

    private func downloadButton(title: String) -> some View {
        Button { downloads.start(item.id, session: server) } label: {
            Label(title, systemImage: "arrow.down.circle.fill").frame(maxWidth: .infinity)
        }
        .buttonStyle(BrandPrimaryButtonStyle())
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
            .background(Brand.Colors.surface, in: Capsule())
            .overlay(Capsule().stroke(Brand.Colors.line, lineWidth: 1))
            .accessibilityIdentifier("availability-badge")
    }

    private var text: String {
        if case .downloading(let progress) = state { return "\(Int(progress.fraction * 100))%" }
        if case .failed = state { return "Download failed" }
        if item.isLocalCopy { return "On this device" }
        return item.isDownloaded ? "Downloaded" : "Cloud"
    }

    private var symbol: String {
        if case .downloading = state { return "arrow.down.circle" }
        if case .failed = state { return "exclamationmark.triangle" }
        if item.isLocalCopy { return "internaldrive" }
        return item.isDownloaded ? "checkmark.circle.fill" : "icloud"
    }
}
