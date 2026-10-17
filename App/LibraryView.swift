import SupersEmuKit
import SwiftUI
import UniformTypeIdentifiers

/// Home: console selector, featured game, Continue playing, then every game A–Z.
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
                                get: { system }, set: { selectedSystem = $0?.rawValue ?? "" }),
                                             statusLine: homeStatusLine(all.allGames.count))
                            if let featured = home.featured {
                                HomeHero(item: featured, theme: theme, primaryTitle: heroTitle(featured),
                                         primary: { heroAction(featured) }, details: { open(featured) })
                            }
                            if !home.currentlyPlaying.isEmpty {
                                CurrentlyPlayingRow(items: home.currentlyPlaying, select: open)
                            }
                            AlphabetGrid(games: home.allGames, letterAnchors: home.letterAnchors, select: open)
                        }
                    }
                    .padding(.vertical, 16)
                }
                .overlay(alignment: .trailing) {
                    if query.isEmpty, !home.allGames.isEmpty {
                        JumpRail(available: Set(home.letterAnchors.keys)) { letter, animated in
                            if animated {
                                withAnimation(.snappy) { proxy.scrollTo("letter-\(letter)", anchor: .top) }
                            } else {
                                proxy.scrollTo("letter-\(letter)", anchor: .top)
                            }
                        }
                    }
                }
            }
            .background {
                Brand.Colors.paper.ignoresSafeArea()
            }
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
                    profileMenu
                }
            }
            .sheet(isPresented: $isShowingControls) {
                NavigationStack {
                    ControlsView()
                        .toolbar {
                            ToolbarItem(placement: .confirmationAction) { Button("Done") { isShowingControls = false } }
                        }
                }
            }
            .fileImporter(isPresented: $isImporting, allowedContentTypes: [.data], allowsMultipleSelection: true) { result in
                if case .success(let urls) = result { library.importFiles(urls) }
            }
            .sheet(item: $selected) { item in
                NavigationStack { GameDetailView(item: liveItem(item), onPlay: onPlay, onStartFresh: onStartFresh) }
                    .environment(server)
                    .environment(downloads)
                    .environment(bios)
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
                        .foregroundStyle(Brand.Colors.ink)
                        .background(Brand.Colors.surface, in: Capsule())
                        .overlay { Capsule().stroke(Brand.Colors.line, lineWidth: 1) }
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

    private var profileMenu: some View {
        Menu {
            Button(statusText) {}
                .disabled(true)
            if server.isPaired {
                Button("Refresh Library", systemImage: "arrow.clockwise") { Task { await server.refresh() } }
            }
            Button("Import Games…", systemImage: "square.and.arrow.down.on.square") { isImporting = true }
                .accessibilityIdentifier("import-games")
            Button("Controls…", systemImage: "gamecontroller") { isShowingControls = true }
                .accessibilityIdentifier("library-controls")
            if server.isPaired {
                Button("Disconnect & Remove Downloads", systemImage: "rectangle.portrait.and.arrow.right", role: .destructive) {
                    server.signOut()
                    downloads.removeAll()
                }
            } else {
                Button("Connect to Server…", systemImage: "server.rack") { isConnecting = true }
                    .accessibilityIdentifier("connect-server")
            }
        } label: {
            if server.status == .connecting {
                ProgressView()
                    .controlSize(.regular)
                    .frame(width: 32, height: 32)
                    .accessibilityLabel("Server, connecting")
            } else {
                Image(systemName: "person.crop.circle")
                    .font(.system(size: 20))
                    .foregroundStyle(Brand.Colors.ink)
                    .overlay(alignment: .bottomTrailing) {
                        if server.isPaired {
                            Circle()
                                .fill(server.isOnline ? Color.green : Color.gray)
                                .frame(width: 8, height: 8)
                                .overlay(Circle().stroke(Brand.Colors.paper, lineWidth: 1))
                                .offset(x: 1, y: 1)
                        }
                    }
                    .frame(width: 32, height: 32)
                    .accessibilityLabel("Profile")
            }
        }
        .accessibilityIdentifier("profile-menu")
        .accessibilityValue(server.status == .connecting ? "Connecting" : "")
    }

    private func homeStatusLine(_ count: Int) -> String {
        if server.status == .connecting {
            return "\(count) GAMES · \(server.serverName.uppercased()) · CONNECTING"
        }
        guard server.isPaired else { return "\(count) GAMES · ON THIS DEVICE" }
        return "\(count) GAMES · \(server.serverName.uppercased()) · \(server.isOnline ? "CONNECTED" : "OFFLINE")"
    }

    private var statusText: String {
        if server.status == .connecting { return "\(server.serverName) · Connecting" }
        return server.isPaired ? "\(server.serverName) · \(server.isOnline ? "Connected" : "Offline")" : "Not connected"
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
            Image(systemName: "gamecontroller").font(.system(size: 56)).foregroundStyle(Brand.Colors.ink3)
            Text("Your library is empty").font(.title2.bold()).foregroundStyle(Brand.Colors.ink)
            Text(emptyText).multilineTextAlignment(.center).foregroundStyle(Brand.Colors.ink2)
            Button("Import Games") { isImporting = true }
                .buttonStyle(BrandPrimaryButtonStyle())
                .accessibilityIdentifier("import-games-empty")
            if !server.isPaired {
                Button("Connect to Server") { isConnecting = true }
                    .buttonStyle(BrandSecondaryButtonStyle())
                    .accessibilityIdentifier("connect-server-empty")
            }
        }
        .frame(maxWidth: 360)
        .padding(.top, 100)
        .frame(maxWidth: .infinity)
    }

    private var emptyText: String {
        if server.isPaired, server.isOnline { return "Add games on your server, or import games you own (SNES, Game Boy, Game Boy Color, GBA, Genesis, Sega CD, 32X, PlayStation, N64) onto this device." }
        if server.isPaired { return "Nothing is downloaded yet. Connect to your server to download games." }
        return "Import games you own (SNES, Game Boy, Game Boy Color, GBA, Genesis, Sega CD, 32X, PlayStation, N64), or connect to your SupersEmu Server."
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
                if item.isCloudOnly {
                    Text("CLOUD")
                        .font(.system(size: 9, weight: .semibold, design: .monospaced))
                        .tracking(1)
                        .foregroundStyle(Brand.Colors.ink)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 4)
                        .background(Brand.Colors.surface, in: RoundedRectangle(cornerRadius: 6))
                        .overlay { RoundedRectangle(cornerRadius: 6).stroke(Brand.Colors.line, lineWidth: 1) }
                        .padding(7)
                        .accessibilityIdentifier("badge-cloud")
                }
            }
            if case .downloading(let progress) = state {
                ProgressView(value: progress.fraction).tint(Brand.Colors.red)
            }
            Text(item.title).font(compact ? .caption.bold() : .subheadline.bold()).foregroundStyle(Brand.Colors.ink).lineLimit(2)
            Text(item.console).font(compact ? .caption2 : .caption).foregroundStyle(Brand.Colors.ink2).lineLimit(1)
            if !item.isCloudOnly {
                Color.clear.frame(width: 1, height: 1)
                    .accessibilityElement()
                    .accessibilityLabel(item.isLocalCopy ? "On this device" : "Downloaded")
                    .accessibilityIdentifier("badge-downloaded")
            }
        }
    }

    private var compact: Bool {
        #if os(iOS)
        sizeClass == .compact
        #else
        false
        #endif
    }
}
