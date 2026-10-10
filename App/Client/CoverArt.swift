import SwiftUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// Cover art from the server (authenticated), cached on disk for offline use, with a generated fallback tile.
struct CoverArt: View {
    @Environment(ServerSession.self) private var server
    let item: LibraryItem
    @State private var image: Image?

    var body: some View {
        RoundedRectangle(cornerRadius: 14)
            .fill(LinearGradient(colors: ArtworkCache.palette(item.id), startPoint: .topLeading, endPoint: .bottomTrailing))
            .aspectRatio(3 / 4, contentMode: .fit)
            .overlay {
                if let image {
                    image.resizable().scaledToFill()
                } else {
                    VStack(spacing: 8) {
                        Image(systemName: "gamecontroller.fill").font(.system(size: 34))
                        Text(item.title).font(.caption.bold()).multilineTextAlignment(.center).lineLimit(3).padding(.horizontal, 8)
                    }
                    .foregroundStyle(.white.opacity(0.9))
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 14))
            .task(id: item.coverPath) { image = await ArtworkCache.image(item.coverPath, key: item.id, server: server) }
    }
}

/// Wide art for heroes and cards: the backdrop/screenshot, else the cover over a blurred copy of itself, else a gradient.
struct WideArt: View {
    @Environment(ServerSession.self) private var server
    let item: LibraryItem
    @State private var hero: Image?
    @State private var cover: Image?

    var body: some View {
        Rectangle()
            .fill(LinearGradient(colors: ArtworkCache.palette(item.id), startPoint: .topLeading, endPoint: .bottomTrailing))
            .overlay {
                if let hero {
                    hero.resizable().scaledToFill()
                } else if let cover {
                    ZStack(alignment: .trailing) {
                        cover.resizable().scaledToFill().blur(radius: 28).opacity(0.75)
                        cover.resizable().scaledToFit().clipShape(RoundedRectangle(cornerRadius: 10)).shadow(radius: 12).padding(18)
                    }
                }
            }
            .clipped()
            .task(id: item.heroPath ?? item.coverPath) {
                hero = await ArtworkCache.image(item.heroPath, key: ArtworkCache.key(item.id, item.heroPath), server: server)
                if hero == nil { cover = await ArtworkCache.image(item.coverPath, key: item.id, server: server) }
            }
    }
}

/// Any server artwork path (screenshots, logos), loaded like covers.
struct RemoteArtwork: View {
    @Environment(ServerSession.self) private var server
    let gameID: String
    let path: String
    var contentMode: ContentMode = .fill
    @State private var image: Image?

    var body: some View {
        Group {
            if let image {
                image.resizable().aspectRatio(contentMode: contentMode)
            } else {
                Color.white.opacity(0.06)
            }
        }
        .task(id: path) { image = await ArtworkCache.image(path, key: ArtworkCache.key(gameID, path), server: server) }
    }
}

enum ArtworkCache {
    /// Covers keep the bare game ID (older caches); other kinds add their path, e.g. `<id>-screenshot-0`.
    static func key(_ gameID: String, _ path: String?) -> String {
        guard let path, let range = path.range(of: "/artwork/") else { return gameID }
        return gameID + "-" + path[range.upperBound...].replacingOccurrences(of: "/", with: "-")
    }

    @MainActor static func image(_ path: String?, key: String, server: ServerSession) async -> Image? {
        guard let path else { return nil }
        let file = AppPaths.covers.appendingPathComponent(key)
        if let data = try? Data(contentsOf: file), let image = image(from: data) { return image }
        guard server.isOnline, let data = try? await server.data(atPath: path), let image = image(from: data) else { return nil }
        try? FileManager.default.createDirectory(at: AppPaths.covers, withIntermediateDirectories: true)
        try? data.write(to: file, options: .atomic)
        return image
    }

    static func palette(_ id: String) -> [Color] {
        let hue = Double(UInt8(id.prefix(2), radix: 16) ?? UInt8(abs(id.hashValue) % 255)) / 255
        return [
            Color(hue: hue, saturation: 0.75, brightness: 0.9),
            Color(hue: (hue + 0.12).truncatingRemainder(dividingBy: 1), saturation: 0.8, brightness: 0.55),
        ]
    }

    private static func image(from data: Data) -> Image? {
        #if os(macOS)
        NSImage(data: data).map { Image(nsImage: $0) }
        #else
        UIImage(data: data).map { Image(uiImage: $0) }
        #endif
    }
}
