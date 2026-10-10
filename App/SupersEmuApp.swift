import SwiftUI

@main
struct SupersEmuApp: App {
    @State private var library = GameLibrary()
    @State private var server = ServerSession()
    @State private var downloads = DownloadCenter()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(library)
                .environment(server)
                .environment(downloads)
                .preferredColorScheme(.dark)
        }
    }
}

struct RootView: View {
    @Environment(GameLibrary.self) private var library
    @Environment(ServerSession.self) private var server
    @Environment(DownloadCenter.self) private var downloads
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
                LibraryView { playing = $0 }
            }
        }
        .task { await server.refresh() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { Task { await server.refresh() } }
        }
    }
}
