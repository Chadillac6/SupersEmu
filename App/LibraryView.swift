import SupersEmuKit
import SwiftUI
import UniformTypeIdentifiers

/// Netflix-style library: rows of cover art from the server plus games imported on this device.
struct LibraryView: View {
    @Environment(GameLibrary.self) private var library
    @Environment(ServerSession.self) private var server
    @Environment(DownloadCenter.self) private var downloads
    let onPlay: (Game) -> Void
    @State private var isImporting = false
    @State private var isConnecting = false
    @State private var selected: LibraryItem?
    @State private var query = ""

    private var items: [LibraryItem] {
        LibraryShelves.items(server: server.games, firstSeen: server.firstSeen, downloads: downloads, local: library.games)
    }

    /// Offline, only games that launch without the server are listed.
    private var online: Bool { server.isOnline || !server.isPaired }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 26) {
                    statusBanner
                    if !query.isEmpty {
                        searchResults
                    } else {
                        let shelves = LibraryShelves.shelves(items, online: online)
                        if shelves.isEmpty {
                            emptyState
                        } else {
                            ForEach(shelves) { shelf in ShelfRow(shelf: shelf, select: open) }
                        }
                    }
                }
                .padding(.vertical, 16)
            }
            .navigationTitle("SupersEmu")
            .searchable(text: $query, prompt: "Search games")
            .refreshable { await server.refresh() }
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button("Import Games", systemImage: "plus") { isImporting = true }
                        .accessibilityIdentifier("import-games")
                }
                ToolbarItem(placement: .primaryAction) { serverMenu }
            }
            .fileImporter(isPresented: $isImporting, allowedContentTypes: [.data], allowsMultipleSelection: true) { result in
                if case .success(let urls) = result { library.importFiles(urls) }
            }
            .sheet(item: $selected) { item in
                NavigationStack { GameDetailView(item: liveItem(item), onPlay: onPlay) }
                    .environment(server)
                    .environment(downloads)
            }
            .sheet(isPresented: $isConnecting) {
                NavigationStack {
                    OnboardingView(onSkip: nil)
                        .toolbar {
                            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { isConnecting = false } }
                        }
                }
                .environment(server)
                .frame(minWidth: 420, minHeight: 520)
            }
            .onChange(of: server.isPaired) { _, paired in if paired { isConnecting = false } }
            .safeAreaInset(edge: .bottom) {
                if let message = library.importMessage {
                    Text(message)
                        .font(.callout)
                        .padding(.horizontal, 16).padding(.vertical, 10)
                        .background(.thinMaterial, in: Capsule())
                        .padding(.bottom, 12)
                        .accessibilityIdentifier("import-message")
                }
            }
        }
    }

    private func open(_ item: LibraryItem) {
        selected = item
    }

    /// The sheet keeps the tapped item; re-resolve it so badges and buttons follow downloads.
    private func liveItem(_ item: LibraryItem) -> LibraryItem {
        items.first { $0.id == item.id && $0.source == item.source } ?? item
    }

    @ViewBuilder private var statusBanner: some View {
        switch server.status {
        case .offline(let message):
            HStack(spacing: 12) {
                Image(systemName: "wifi.slash")
                VStack(alignment: .leading, spacing: 2) {
                    Text(message).font(.callout.bold())
                    Text("Showing games you can play offline.").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Retry") { Task { await server.refresh() } }.accessibilityIdentifier("retry-server")
            }
            .padding(14)
            .background(.orange.opacity(0.18), in: RoundedRectangle(cornerRadius: 12))
            .padding(.horizontal, 20)
            .accessibilityIdentifier("offline-banner")
        case .connecting where server.games.isEmpty:
            ProgressView("Connecting to \(server.serverName)…").padding(.horizontal, 20)
        default:
            EmptyView()
        }
    }

    private var serverMenu: some View {
        Menu {
            if server.isPaired {
                Section(statusText) {
                    Button("Refresh Library", systemImage: "arrow.clockwise") { Task { await server.refresh() } }
                    Button("Disconnect This Device", systemImage: "rectangle.portrait.and.arrow.right", role: .destructive) { server.signOut() }
                }
            } else {
                Button("Connect to Server…", systemImage: "server.rack") { isConnecting = true }
                    .accessibilityIdentifier("connect-server")
            }
        } label: {
            Label("Server", systemImage: server.isOnline ? "server.rack" : "exclamationmark.icloud")
        }
        .accessibilityIdentifier("server-menu")
    }

    private var statusText: String {
        switch server.status {
        case .online: return "\(server.serverName) · Connected"
        case .connecting: return "\(server.serverName) · Connecting"
        case .offline: return "\(server.serverName) · Offline"
        case .notPaired: return "Not connected"
        }
    }

    private var searchResults: some View {
        let results = LibraryShelves.search(items, query: query, online: online)
        return Group {
            if results.isEmpty {
                Text("No games match \u{201C}\(query)\u{201D}").foregroundStyle(.secondary).frame(maxWidth: .infinity).padding(.top, 80)
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 130), spacing: 18)], spacing: 22) {
                    ForEach(results) { item in
                        Button { open(item) } label: { GameCard(item: item, state: downloads.states[item.id]) }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier("game-card")
                            .accessibilityLabel(item.title)
                    }
                }
                .padding(.horizontal, 20)
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "gamecontroller").font(.system(size: 56)).foregroundStyle(.secondary)
            Text("Your library is empty").font(.title2.bold())
            Text(emptyText).multilineTextAlignment(.center).foregroundStyle(.secondary)
            Button("Import Games") { isImporting = true }
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("import-games-empty")
            if !server.isPaired {
                Button("Connect to Server") { isConnecting = true }.accessibilityIdentifier("connect-server-empty")
            }
        }
        .frame(maxWidth: 360)
        .padding(.top, 100)
        .frame(maxWidth: .infinity)
    }

    private var emptyText: String {
        if server.isPaired, server.isOnline { return "Add games on your server, or import SNES games (.sfc, .smc) you own onto this device." }
        if server.isPaired { return "Nothing is downloaded yet. Connect to your server to download games." }
        return "Import SNES games (.sfc, .smc) you own, or connect to your SupersEmu Server."
    }
}

struct ShelfRow: View {
    @Environment(DownloadCenter.self) private var downloads
    let shelf: Shelf
    let select: (LibraryItem) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(shelf.title).font(.title3.bold()).padding(.horizontal, 20).accessibilityIdentifier("shelf-\(shelf.id)")
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: 16) {
                    ForEach(shelf.items) { item in
                        Button { select(item) } label: { GameCard(item: item, state: downloads.states[item.id]) }
                            .buttonStyle(.plain)
                            .frame(width: 132)
                            .accessibilityIdentifier("game-card")
                            .accessibilityLabel(item.title)
                    }
                }
                .padding(.horizontal, 20)
            }
        }
    }
}

struct GameCard: View {
    let item: LibraryItem
    let state: DownloadCenter.State?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack(alignment: .bottomLeading) {
                CoverArt(item: item)
                    .opacity(item.isCloudOnly ? 0.85 : 1)
                HStack {
                    if item.playable?.hasResumePoint == true {
                        Label("Continue", systemImage: "play.fill").labelStyle(.iconOnly).font(.caption.bold())
                            .padding(6).background(.ultraThinMaterial, in: Circle())
                    }
                    Spacer()
                    badge
                }
                .padding(8)
            }
            if case .downloading(let progress) = state {
                ProgressView(value: progress.fraction).tint(.accentColor)
            }
            Text(item.title).font(.subheadline.bold()).lineLimit(2)
            Text(item.console).font(.caption).foregroundStyle(.secondary).lineLimit(1)
        }
    }

    @ViewBuilder private var badge: some View {
        let symbol: String = {
            if case .downloading = state { return "arrow.down.circle.fill" }
            switch item.source {
            case .local: return "internaldrive.fill"
            case .server: return item.isDownloaded ? "checkmark.circle.fill" : "icloud.fill"
            }
        }()
        Image(systemName: symbol)
            .font(.caption.bold())
            .padding(6)
            .background(.ultraThinMaterial, in: Circle())
            .accessibilityLabel(item.isCloudOnly ? "In the cloud" : item.source == .local ? "On this device" : "Downloaded")
            .accessibilityIdentifier(item.isCloudOnly ? "badge-cloud" : "badge-downloaded")
    }
}
