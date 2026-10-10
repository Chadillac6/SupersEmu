import SwiftUI

@main
struct SupersEmuApp: App {
    @State private var library = GameLibrary()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(library)
                .preferredColorScheme(.dark)
        }
    }
}

struct RootView: View {
    @Environment(GameLibrary.self) private var library
    @State private var playing: Game?

    var body: some View {
        if let game = playing {
            PlayerView(session: GameSession(game: game)) {
                playing = nil
                library.refresh()
            }
        } else {
            LibraryView { playing = $0 }
        }
    }
}
