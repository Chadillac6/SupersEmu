import SupersEmuKit
import SwiftUI
import UniformTypeIdentifiers

/// Home: console selector and theme, hero, Now Playing, Downloaded, then Not Downloaded.
struct LibraryView: View {
    @Environment(GameLibrary.self) private var library
    @Environment(ServerSession.self) private var server
    @Environment(DownloadCenter.self) private var downloads
    @Environment(BIOSCenter.self) private var bios
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var sizeClass
    #endif
    @AppStorage("home.system") private var selectedSystem = ""
    let onPlay: (Game) -> Void
    let onStartFresh: (Game) -> Void
    @State private var isImporting = false
    @State private var isConnecting = false
    @State private var selected: LibraryItem?
    @State private var query = ""
    @State private var isShowingControls = false

    private var items: [LibraryItem] {
        LibraryShelves.items(server: server.games, firstSeen: server.firstSeen, downloads: downloads, local: library.games)
    }

    /// Offline, only games that launch without the server are listed.
    private var online: Bool { server.isOnline || !server.isPaired }

    private var compact: Bool {
        #if os(iOS)
        sizeClass == .compact
        #else
        false
        #endif
    }

    var body: some View {
        let all = LibraryShelves.home(items, system: nil, online: online)
        let system = SystemID(rawValue: selectedSystem).flatMap { all.systems.contains($0) ? $0 : nil }
        let home = system == nil ? all : LibraryShelves.home(items, system: system, online: online)
        let theme = SystemTheme.theme(for: system)
        NavigationStack {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 26) {
                        ConnectionBanner()
                        if !query.isEmpty {
                            searchResults
                        } else if all.allGames.isEmpty {
                            emptyState
                        } else {
                            SystemSelectorBar(theme: theme, systems: all.systems, selection: Binding(
                                get: { system }, set: { selectedSystem = $0?.rawValue ?? "" }))
                            if let featured = home.featured {
                                HomeHero(item: featured, theme: theme, primaryTitle: heroTitle(featured),
                                         primary: { heroAction(featured) }, details: { open(featured) })
                            }
                            if !home.currentlyPlaying.isEmpty {
                                CurrentlyPlayingRow(items: home.currentlyPlaying, select: open)
                            }
                            if !home.downloaded.isEmpty {
                                GameGridSection(title: "Downloaded", identifier: "shelf-downloaded",
                                                games: home.downloaded, letterAnchors: home.letterAnchors, select: open)
                            }
                            if !home.notDownloaded.isEmpty {
                                GameGridSection(title: "Not Downloaded", identifier: "shelf-not-downloaded",
                                                games: home.notDownloaded, letterAnchors: home.letterAnchors, select: open)
                            }
                        }
                    }
                    .padding(.vertical, 16)
                }
                .overlay(alignment: .trailing) {
                    #if os(macOS)
                    if query.isEmpty, !home.allGames.isEmpty {
                        JumpRail(available: Set(home.letterAnchors.keys)) { letter, animated in
                            if animated {
                                withAnimation(.snappy) { proxy.scrollTo("letter-\(letter)", anchor: .top) }
                            } else {
                                proxy.scrollTo("letter-\(letter)", anchor: .top)
                            }
                        }
                    }
                    #endif
                }
            }
            .background {
                ZStack {
                    LinearGradient(colors: theme.background, startPoint: .top, endPoint: .bottom)
                    RadialGradient(colors: [theme.accent.opacity(0.35), .clear], center: .topLeading, startRadius: 0, endRadius: 700)
                }
                .ignoresSafeArea()
            }
            .animation(.easeInOut(duration: 0.35), value: theme.id)
            .tint(theme.accent)
            .navigationTitle(system?.displayName ?? "SupersEmu")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .searchable(text: $query, prompt: "Search games")
            .refreshable {
                ArtworkCache.revalidateAll()
                await server.refresh()
            }
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button("Import Games", systemImage: "plus") { isImporting = true }
                        .accessibilityIdentifier("import-games")
                }
                ToolbarItem(placement: .primaryAction) { serverMenu }
                #if os(iOS)
                ToolbarItem(placement: .primaryAction) {
                    Button("Controls", systemImage: "gamecontroller") { isShowingControls = true }
                        .accessibilityIdentifier("library-controls")
                }
                #endif
            }
            #if os(iOS)
            .sheet(isPresented: $isShowingControls) {
                NavigationStack {
                    ControlsView()
                        .toolbar {
                            ToolbarItem(placement: .confirmationAction) { Button("Done") { isShowingControls = false } }
                        }
                }
            }
            #endif
            .fileImporter(isPresented: $isImporting, allowedContentTypes: [.data], allowsMultipleSelection: true) { result in
                if case .success(let urls) = result { library.importFiles(urls) }
            }
            .sheet(item: $selected) { item in
                NavigationStack { GameDetailView(item: liveItem(item), onPlay: onPlay, onStartFresh: onStartFresh) }
                    .environment(server)
                    .environment(downloads)
                    .environment(bios)
                    .preferredColorScheme(.dark)
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
            .preferredColorScheme(.dark)
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

    private func heroPlayable(_ item: LibraryItem) -> Game? {
        let game = item.source == .server ? downloads.playableGame(item.id) ?? item.playable : item.playable
        return bios.isMissing(item.system) || (bios.isSyncing && item.system?.requiresBIOS == true) ? nil : game
    }

    private func heroTitle(_ item: LibraryItem) -> String {
        guard let game = heroPlayable(item) else { return item.isCloudOnly ? "Get Game" : "View Game" }
        return game.hasResumePoint ? "Resume" : "Play"
    }

    /// Plays straight away when it can; otherwise the pop-up has the download/BIOS controls.
    private func heroAction(_ item: LibraryItem) {
        if let game = heroPlayable(item) { onPlay(game) } else { open(item) }
    }

    /// The sheet keeps the tapped item; re-resolve it so badges and buttons follow downloads.
    private func liveItem(_ item: LibraryItem) -> LibraryItem {
        items.first { $0.id == item.id && $0.source == item.source } ?? item
    }

    private var serverMenu: some View {
        Menu {
            if server.isPaired {
                Section(statusText) {
                    Button("Refresh Library", systemImage: "arrow.clockwise") { Task { await server.refresh() } }
                    Button("Disconnect & Remove Downloads", systemImage: "rectangle.portrait.and.arrow.right", role: .destructive) {
                        server.signOut()
                        downloads.removeAll()
                    }
                }
            } else {
                Button("Connect to Server…", systemImage: "server.rack") { isConnecting = true }
                    .accessibilityIdentifier("connect-server")
            }
        } label: {
            if server.status == .connecting {
                ProgressView()
                    .controlSize(.regular)
                    .frame(width: 28, height: 28)
                    .tint(.white)
                    .accessibilityLabel("Server, connecting")
            } else {
                Image(systemName: server.isOnline ? "server.rack" : "exclamationmark.icloud")
                    .frame(width: 28, height: 28)
                    .foregroundStyle(.white)
                    .accessibilityLabel("Server")
            }
        }
        .accessibilityIdentifier("server-menu")
        .accessibilityValue(server.status == .connecting ? "Connecting" : "")
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
                LazyVGrid(columns: GameGridLayout.columns(compact: compact, regularSpacing: 18),
                          spacing: GameGridLayout.rowSpacing(compact: compact, regularSpacing: 22)) {
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
        if server.isPaired, server.isOnline { return "Add games on your server, or import games you own (SNES, Game Boy, GBA, Genesis) onto this device." }
        if server.isPaired { return "Nothing is downloaded yet. Connect to your server to download games." }
        return "Import games you own (SNES, Game Boy, GBA, Genesis), or connect to your SupersEmu Server."
    }
}

struct GameCard: View {
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var sizeClass
    #endif
    let item: LibraryItem
    let state: DownloadCenter.State?

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 4 : 6) {
            ZStack(alignment: .bottomLeading) {
                CoverArt(item: item)
                    .opacity(item.isCloudOnly ? 0.85 : 1)
                HStack {
                    if item.playable?.hasResumePoint == true {
                        Label("Continue", systemImage: "play.fill").labelStyle(.iconOnly)
                            .font(compact ? .caption2.bold() : .caption.bold())
                            .padding(compact ? 4 : 6).background(.ultraThinMaterial, in: Circle())
                    }
                    Spacer()
                    badge
                }
                .padding(compact ? 5 : 8)
            }
            if case .downloading(let progress) = state {
                ProgressView(value: progress.fraction).tint(.accentColor)
            }
            Text(item.title).font(compact ? .caption.bold() : .subheadline.bold()).lineLimit(2)
            Text(item.console).font(compact ? .caption2 : .caption).foregroundStyle(.secondary).lineLimit(1)
        }
    }

    private var compact: Bool {
        #if os(iOS)
        sizeClass == .compact
        #else
        false
        #endif
    }

    @ViewBuilder private var badge: some View {
        let symbol: String = {
            if case .downloading = state { return "arrow.down.circle.fill" }
            if item.isLocalCopy { return "internaldrive.fill" }
            return item.isDownloaded ? "checkmark.circle.fill" : "icloud.fill"
        }()
        Image(systemName: symbol)
            .font(compact ? .caption2.bold() : .caption.bold())
            .padding(compact ? 4 : 6)
            .background(.ultraThinMaterial, in: Circle())
            .accessibilityLabel(item.isCloudOnly ? "In the cloud" : item.isLocalCopy ? "On this device" : "Downloaded")
            .accessibilityIdentifier(item.isCloudOnly ? "badge-cloud" : "badge-downloaded")
    }
}
