import SwiftUI

@main
struct SupersEmuApp: App {
    @State private var library = GameLibrary()
    @State private var server = ServerSession()
    @State private var downloads = DownloadCenter()
    @State private var bios = BIOSCenter()

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
                #endif
        }
        #if os(macOS)
        ServerModeScene()
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
    @AppStorage("onboardingSkipped") private var onboardingSkipped = false
    @State private var playing: Game?

    /// M0 flows (and test launches with SUPERSEMU_IMPORT_DIR) go straight to the local library.
    private var showsOnboarding: Bool {
        let env = ProcessInfo.processInfo.environment
        return !server.isPaired && !onboardingSkipped && env["SUPERSEMU_IMPORT_DIR"] == nil && env["SUPERSEMU_SKIP_ONBOARDING"] == nil
    }

    var body: some View {
        Group {
            if let game = playing {
                PlayerView(session: GameSession(game: game)) {
                    playing = nil
                    library.refresh()
                    downloads.reload()
                }
            } else if showsOnboarding {
                OnboardingView { onboardingSkipped = true }
            } else {
                LibraryView { game in Task { await launch(game) } }
            }
        }
        .task {
            SaveSync.shared.provider.use { [server] in server.client() }
            await server.refresh()
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { Task { await server.refresh() } }
        }
        // Every successful refresh (including a LAN -> Tailscale switch) retries queued saves; overlapping
        // flushes coalesce inside the engine.
        .onChange(of: server.lastRefreshed) { _, refreshed in
            if refreshed != nil { Task { await SaveSync.shared.engine.flush() } }
            if refreshed != nil { Task { await bios.sync(using: server) } }
        }
    }

    /// Disc games need their BIOS in the system directory before the core loads them.
    private func launch(_ game: Game) async {
        if let system = downloads.downloaded[game.id]?.detail.game.system, system.requiresBIOS {
            await bios.sync(using: server)
            guard !bios.isMissing(system) else { return }
        }
        playing = game
    }
}
