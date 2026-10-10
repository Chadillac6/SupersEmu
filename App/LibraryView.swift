import SwiftUI
import UniformTypeIdentifiers

struct LibraryView: View {
    @Environment(GameLibrary.self) private var library
    let onPlay: (Game) -> Void
    @State private var isImporting = false

    var body: some View {
        NavigationStack {
            ScrollView {
                if library.games.isEmpty {
                    emptyState
                } else {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 20)], spacing: 24) {
                        ForEach(library.games) { game in
                            Button { onPlay(game) } label: { GameCard(game: game) }
                                .buttonStyle(.plain)
                                .accessibilityIdentifier("game-card")
                                .accessibilityLabel(game.title)
                        }
                    }
                    .padding(20)
                }
            }
            .navigationTitle("SupersEmu")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button("Import Games", systemImage: "plus") { isImporting = true }
                        .accessibilityIdentifier("import-games")
                }
            }
            .fileImporter(isPresented: $isImporting, allowedContentTypes: [.data], allowsMultipleSelection: true) { result in
                if case .success(let urls) = result { library.importFiles(urls) }
            }
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

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "gamecontroller").font(.system(size: 56)).foregroundStyle(.secondary)
            Text("Your library is empty").font(.title2.bold())
            Text("Import SNES games (.sfc, .smc) you own. SupersEmu names and organises them for you.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            Button("Import Games") { isImporting = true }
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("import-games-empty")
        }
        .frame(maxWidth: 360)
        .padding(.top, 120)
        .frame(maxWidth: .infinity)
    }
}

struct GameCard: View {
    let game: Game

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack(alignment: .bottomLeading) {
                RoundedRectangle(cornerRadius: 16)
                    .fill(LinearGradient(colors: palette, startPoint: .topLeading, endPoint: .bottomTrailing))
                    .aspectRatio(3 / 4, contentMode: .fit)
                    .overlay {
                        Image(systemName: "gamecontroller.fill")
                            .font(.system(size: 44))
                            .foregroundStyle(.white.opacity(0.85))
                    }
                if game.hasResumePoint {
                    Label("Continue", systemImage: "play.fill")
                        .font(.caption.bold())
                        .padding(.horizontal, 8).padding(.vertical, 5)
                        .background(.ultraThinMaterial, in: Capsule())
                        .padding(10)
                }
            }
            Text(game.title).font(.headline).lineLimit(2)
            Text(game.console).font(.caption).foregroundStyle(.secondary)
        }
    }

    private var palette: [Color] {
        let hue = Double(UInt8(game.id.prefix(2), radix: 16) ?? 0) / 255
        return [
            Color(hue: hue, saturation: 0.75, brightness: 0.9),
            Color(hue: (hue + 0.12).truncatingRemainder(dividingBy: 1), saturation: 0.8, brightness: 0.55),
        ]
    }
}
