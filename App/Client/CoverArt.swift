import SwiftUI
import Observation
#if os(macOS)
import AppKit
#else
import UIKit
#endif

@MainActor @Observable
final class ArtworkRevision {
    static let shared = ArtworkRevision()
    private(set) var value = 0

    func increment() { value &+= 1 }
}

/// Cover art from the server (authenticated), cached on disk for offline use, with a generated fallback tile.
struct CoverArt: View {
    @Environment(ServerSession.self) private var server
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var sizeClass
    #endif
    let item: LibraryItem
    @State private var image: Image?

    var body: some View {
        RoundedRectangle(cornerRadius: compact ? 10 : 14)
            .fill(Brand.Colors.card)
            .overlay {
                LinearGradient(colors: ArtworkCache.palette(item.id).map { $0.opacity(0.22) },
                               startPoint: .topLeading, endPoint: .bottomTrailing)
            }
            .aspectRatio(4 / 3, contentMode: .fit)
            .overlay {
                if let image {
                    image.resizable().scaledToFit()
                        .padding(6)
                } else {
                    VStack(spacing: 8) {
                        Image(systemName: "gamecontroller.fill").font(.system(size: compact ? 22 : 34))
                        Text(item.title).font(compact ? .caption2.bold() : .caption.bold())
                            .multilineTextAlignment(.center).lineLimit(3).padding(.horizontal, 8)
                    }
                    .foregroundStyle(Brand.Colors.ink2)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: compact ? 10 : 14))
            .contentShape(RoundedRectangle(cornerRadius: compact ? 10 : 14))
            .task(id: ArtworkCache.taskID(item.coverPath, server)) {
                await ArtworkCache.load(item.coverPath, key: item.id, server: server) { image = $0 }
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

/// Wide art for heroes and cards: the backdrop/screenshot, else the cover over a blurred copy of itself, else a gradient.
struct WideArt: View {
    @Environment(ServerSession.self) private var server
    let item: LibraryItem
    var preferCover = false
    /// Widest the sharp cover gets in a hero, leaving the rest of the card for its text.
    static let heroCoverFraction: CGFloat = 0.42
    @State private var hero: Image?
    @State private var cover: Image?

    var body: some View {
        Rectangle()
            .fill(LinearGradient(colors: ArtworkCache.palette(item.id), startPoint: .topLeading, endPoint: .bottomTrailing))
            .overlay {
                if let hero {
                    hero.resizable().scaledToFill()
                } else if let cover {
                    cover.resizable().scaledToFill().blur(radius: 28).opacity(0.75)
                }
            }
            // A separate overlay so the oversized blurred fill can't stretch the sharp cover past the card.
            .overlay(alignment: .trailing) {
                if hero == nil, let cover {
                    GeometryReader { proxy in
                        cover.resizable().scaledToFit().clipShape(RoundedRectangle(cornerRadius: 10)).shadow(radius: 12)
                            .padding(18)
                            .frame(maxWidth: proxy.size.width * (preferCover ? Self.heroCoverFraction : 1), maxHeight: proxy.size.height, alignment: .trailing)
                            .frame(width: proxy.size.width, height: proxy.size.height, alignment: .trailing)
                    }
                }
            }
            .clipped()
            // Clipping the pixels alone does not clip SwiftUI mouse hit testing.
            .contentShape(Rectangle())
            .task(id: ArtworkCache.taskID(preferCover ? item.coverPath : item.heroPath ?? item.coverPath, server)) {
                hero = nil
                cover = nil
                if !preferCover {
                    await ArtworkCache.load(item.heroPath, key: ArtworkCache.key(item.id, item.heroPath), server: server) { hero = $0 }
                }
                if hero == nil { await ArtworkCache.load(item.coverPath, key: item.id, server: server) { cover = $0 } }
            }
    }
}

/// Any server artwork path (screenshots, logos), loaded like covers. The placeholder shows until the image loads.
struct RemoteArtwork<Placeholder: View>: View {
    @Environment(ServerSession.self) private var server
    let gameID: String
    let path: String
    var contentMode: ContentMode = .fill
    @ViewBuilder let placeholder: () -> Placeholder
    @State private var image: Image?

    var body: some View {
        Group {
            if let image {
                image.resizable().aspectRatio(contentMode: contentMode)
            } else {
                placeholder()
            }
        }
        .task(id: ArtworkCache.taskID(path, server)) {
            await ArtworkCache.load(path, key: ArtworkCache.key(gameID, path), server: server) { image = $0 }
        }
    }
}

extension RemoteArtwork where Placeholder == Color {
    init(gameID: String, path: String, contentMode: ContentMode = .fill) {
        self.init(gameID: gameID, path: path, contentMode: contentMode) { Brand.Colors.card }
    }
}

enum ArtworkCache {
    /// Covers keep the bare game ID (older caches); other kinds add their path, e.g. `<id>-screenshot-0`.
    static func key(_ gameID: String, _ path: String?) -> String {
        guard let path, let range = path.range(of: "/artwork/") else { return gameID }
        return gameID + "-" + path[range.upperBound...].replacingOccurrences(of: "/", with: "-")
    }

    /// Reruns artwork tasks on reconnect, so art that couldn't load offline appears.
    @MainActor static func taskID(_ path: String?, _ server: ServerSession) -> String {
        "\(path ?? "")|\(server.isOnline)|\(ArtworkRevision.shared.value)"
    }

    @MainActor private static var revalidated = Set<String>()

    /// Pull to refresh: art is fetched again as views next load it.
    @MainActor static func revalidateAll() {
        revalidated.removeAll()
        ArtworkRevision.shared.increment()
    }

    /// The disk copy straight away (works offline), then once per launch the server's, as replaced art keeps its path.
    @MainActor static func load(_ path: String?, key: String, server: ServerSession, show: (Image?) -> Void) async {
        guard let path else { return show(nil) }
        let file = AppPaths.covers.appendingPathComponent(key)
        let cached = try? Data(contentsOf: file)
        let cachedImage = cached.flatMap(image(from:))
        show(cachedImage)
        if !server.isOnline { revalidated.removeAll() }
        guard server.isOnline, cachedImage == nil || !revalidated.contains(key) else { return }
        guard let data = try? await server.data(atPath: path), let image = image(from: data) else { return }
        revalidated.insert(key)
        guard data != cached else { return }
        try? FileManager.default.createDirectory(at: AppPaths.covers, withIntermediateDirectories: true)
        try? data.write(to: file, options: .atomic)
        show(image)
    }

    static func palette(_ id: String) -> [Color] {
        let hue = Double(UInt8(id.prefix(2), radix: 16) ?? UInt8(abs(id.hashValue) % 255)) / 255
        return [
            Color(hue: hue, saturation: 0.75, brightness: 0.9),
            Color(hue: (hue + 0.12).truncatingRemainder(dividingBy: 1), saturation: 0.8, brightness: 0.55),
        ]
    }

    static func image(from data: Data) -> Image? {
        #if os(macOS)
        NSImage(data: data).map { Image(nsImage: $0) }
        #else
        UIImage(data: data).map { Image(uiImage: $0) }
        #endif
    }
}
