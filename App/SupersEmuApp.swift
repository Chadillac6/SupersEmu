import SupersEmuKit
import SwiftUI

@main
struct SupersEmuApp: App {
    @State private var library = GameLibrary()
    @State private var server = ServerSession()
    @State private var downloads = DownloadCenter()
    @State private var bios = BIOSCenter()

    init() {
        BrandFonts.register()
        #if os(macOS)
        ServerStatusMonitor.shared.startPolling()
        _ = AppUpdater.shared
        #endif
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(library)
                .environment(server)
                .environment(downloads)
                .environment(bios)
                #if os(macOS)
                .serverModeLaunchHook()
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
            NavigationStack {
                ControlsView()
            }
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
    @State private var systemAppearance = SystemAppearance()
    @Environment(\.openWindow) private var openWindow
    @State private var pendingUpdateNotice: PendingUpdateNotice?
    #endif
    @AppStorage("onboardingSkipped") private var onboardingSkipped = false
    @State private var playing: LaunchRequest?
    @State private var showsLaunchSplash = LaunchSplash.claimColdLaunch()

    /// M0 flows (and test launches with SUPERSEMU_IMPORT_DIR) go straight to the local library.
    private var showsOnboarding: Bool {
        let env = ProcessInfo.processInfo.environment
        return !server.isPaired && !onboardingSkipped && env["SUPERSEMU_IMPORT_DIR"] == nil && env["SUPERSEMU_SKIP_ONBOARDING"] == nil
    }

    var body: some View {
        Group {
            if let launch = playing {
                PlayerView(session: GameSession(game: launch.game, startFresh: launch.startFresh,
                                                  keepLocalOver: launch.keepLocalOver)) {
                    playing = nil
                    library.refresh()
                    downloads.reload()
                }
            } else if showsOnboarding {
                OnboardingView { onboardingSkipped = true }
            } else {
                LibraryView(
                    onPlay: { game in Task { await launch(game) } },
                    onStartFresh: { game in Task { await launch(game, startFresh: true) } },
                    onKeepLocal: { game, remote in Task { await launch(game, keepLocalOver: remote) } }
                )
            }
        }
        #if os(macOS)
        .environment(\.colorScheme, playing != nil ? .dark : systemAppearance.colorScheme)
        #endif
        .overlay {
            if showsLaunchSplash && playing == nil {
                LaunchSplash {
                    showsLaunchSplash = false
                }
            }
        }
        .task {
            #if os(macOS)
            AppUpdater.shared.finishServerUpdateIfNeeded()
            #if DEBUG
            if UpdateStatus.previewName(arguments: ProcessInfo.processInfo.arguments) == "whatsNew" {
                pendingUpdateNotice = PendingUpdateNotice(
                    version: "0.0.6",
                    build: "preview",
                    notes: "• Improved frame pacing\n• Clearer update status\n• Bug fixes and performance improvements"
                )
            } else {
                pendingUpdateNotice = AppUpdater.shared.consumePendingUpdateNotice()
            }
            #else
            pendingUpdateNotice = AppUpdater.shared.consumePendingUpdateNotice()
            #endif
            #endif
            SaveSync.shared.provider.use({ [server] in server.client() }, reachable: { [server] in server.isReachable })
            await server.refresh()
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                library.refresh()
                Task { await server.refresh() }
            }
        }
        .onChange(of: playing != nil) { _, isPlaying in
            if isPlaying { showsLaunchSplash = false }
        }
        // Every successful refresh (including a LAN -> public URL switch) retries queued saves; overlapping
        // flushes coalesce inside the engine.
        .onChange(of: server.lastRefreshed) { _, refreshed in
            if refreshed != nil { Task { await SaveSync.shared.engine.flush() } }
            if refreshed != nil { Task { await bios.sync(using: server) } }
            if refreshed != nil { Task { await CheatLibrary.shared.sync() } }
        }
        #if os(macOS)
        .onOpenURL { url in
            guard url.host == "server-mode" else { return }
            ServerModeNavigation.shared.requested = .server
            openWindow(id: ServerModeScene.windowID)
        }
        .sheet(item: $pendingUpdateNotice) { notice in
            UpdateWhatsNewSheet(notice: notice)
        }
        #endif
    }

    /// Disc games need their BIOS in the system directory before the core loads them.
    private func launch(_ game: Game, startFresh: Bool = false, keepLocalOver: SaveRevision? = nil) async {
        if let system = downloads.downloaded[game.id]?.detail.game.system, system.requiresBIOS {
            await bios.sync(using: server)
            guard !bios.isMissing(system) else { return }
        }
        playing = LaunchRequest(game: game, startFresh: startFresh, keepLocalOver: keepLocalOver)
    }

    private struct LaunchRequest {
        let game: Game
        let startFresh: Bool
        var keepLocalOver: SaveRevision?
    }
}

#if os(macOS)
private struct UpdateWhatsNewSheet: View {
    @Environment(\.dismiss) private var dismiss
    let notice: PendingUpdateNotice

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Updated to \(notice.version)")
                .font(.title2.bold())
            ScrollView {
                Text(notice.notes)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            Button("Done") { dismiss() }
                .keyboardShortcut(.defaultAction)
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .padding(24)
        .frame(minWidth: 420, minHeight: 280)
    }
}
#endif

#if os(macOS)
/// The app-wide light/dark setting, read from AppKit rather than the SwiftUI environment.
/// SwiftUI kept the library window dark after the player's dark scheme went away, so RootView sets the scheme itself.
@MainActor @Observable
final class SystemAppearance {
    private(set) var colorScheme: ColorScheme
    @ObservationIgnored private var observation: NSKeyValueObservation?

    init(application: NSApplication = .shared) {
        colorScheme = Self.colorScheme(of: application.effectiveAppearance)
        observation = application.observe(\.effectiveAppearance) { [weak self] application, _ in
            MainActor.assumeIsolated {
                self?.colorScheme = Self.colorScheme(of: application.effectiveAppearance)
            }
        }
    }

    nonisolated static func colorScheme(of appearance: NSAppearance) -> ColorScheme {
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? .dark : .light
    }
}
#endif
