import SwiftUI

@main
struct SupersEmuApp: App {
    @State private var library = GameLibrary()
    @State private var server = ServerSession()
    @State private var downloads = DownloadCenter()
    @State private var bios = BIOSCenter()

    #if os(macOS)
    init() {
        ServerStatusMonitor.shared.startPolling()
        _ = AppUpdater.shared
    }
    #endif

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(library)
                .environment(server)
                .environment(downloads)
                .environment(bios)
                .preferredColorScheme(.dark)
                #if os(macOS)
                .serverModeLaunchHook()
                .task { AppUpdater.shared.finishServerUpdateIfNeeded() }
                #endif
        }
        #if os(macOS)
        .commands {
            CommandGroup(after: .appInfo) {
                UpdateMenu(updater: AppUpdater.shared)
            }
        }
        #endif
        #if os(macOS)
        ServerModeScene()
        ServerMenuBar()
        Settings {
            ControlsView()
                .preferredColorScheme(.dark)
        }
        #endif
    }
}

struct RootView: View {
    @Environment(GameLibrary.self) private var library
    @Environment(ServerSession.self) private var server
    @Environment(DownloadCenter.self) private var downloads
    @Environment(BIOSCenter.self) private var bios
    @Environment(\.scenePhase) private var scenePhase
    #if os(macOS)
    @Environment(\.openWindow) private var openWindow
    #endif
    @AppStorage("onboardingSkipped") private var onboardingSkipped = false
    @State private var playing: LaunchRequest?

    /// M0 flows (and test launches with SUPERSEMU_IMPORT_DIR) go straight to the local library.
    private var showsOnboarding: Bool {
        let env = ProcessInfo.processInfo.environment
        return !server.isPaired && !onboardingSkipped && env["SUPERSEMU_IMPORT_DIR"] == nil && env["SUPERSEMU_SKIP_ONBOARDING"] == nil
    }

    var body: some View {
        Group {
            if let launch = playing {
                PlayerView(session: GameSession(game: launch.game, startFresh: launch.startFresh)) {
                    playing = nil
                    library.refresh()
                    downloads.reload()
                }
            } else if showsOnboarding {
                OnboardingView { onboardingSkipped = true }
            } else {
                LibraryView(
                    onPlay: { game in Task { await launch(game) } },
                    onStartFresh: { game in Task { await launch(game, startFresh: true) } }
                )
            }
        }
        .task {
            SaveSync.shared.provider.use({ [server] in server.client() }, reachable: { [server] in server.isReachable })
            await server.refresh()
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                library.refresh()
                Task { await server.refresh() }
            }
        }
        // Every successful refresh (including a LAN -> Tailscale switch) retries queued saves; overlapping
        // flushes coalesce inside the engine.
        .onChange(of: server.lastRefreshed) { _, refreshed in
            if refreshed != nil { Task { await SaveSync.shared.engine.flush() } }
            if refreshed != nil { Task { await bios.sync(using: server) } }
        }
        #if os(macOS)
        .onOpenURL { url in
            guard url.host == "server-mode" else { return }
            ServerModeNavigation.shared.requested = .server
            openWindow(id: ServerModeScene.windowID)
        }
        #endif
    }

    /// Disc games need their BIOS in the system directory before the core loads them.
    private func launch(_ game: Game, startFresh: Bool = false) async {
        if let system = downloads.downloaded[game.id]?.detail.game.system, system.requiresBIOS {
            await bios.sync(using: server)
            guard !bios.isMissing(system) else { return }
        }
        playing = LaunchRequest(game: game, startFresh: startFresh)
    }

    private struct LaunchRequest {
        let game: Game
        let startFresh: Bool
    }
}
