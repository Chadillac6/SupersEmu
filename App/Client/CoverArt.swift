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
            .fill(LinearGradient(colors: palette, startPoint: .topLeading, endPoint: .bottomTrailing))
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
            .task(id: item.coverPath) { await load() }
    }

    private var palette: [Color] {
        let hue = Double(UInt8(item.id.prefix(2), radix: 16) ?? UInt8(abs(item.id.hashValue) % 255)) / 255
        return [
            Color(hue: hue, saturation: 0.75, brightness: 0.9),
            Color(hue: (hue + 0.12).truncatingRemainder(dividingBy: 1), saturation: 0.8, brightness: 0.55),
        ]
    }

    private func load() async {
        guard let path = item.coverPath else { return }
        let file = AppPaths.covers.appendingPathComponent(item.id)
        if let data = try? Data(contentsOf: file), let image = Self.image(from: data) {
            self.image = image
            return
        }
        guard server.isOnline, let data = try? await server.data(atPath: path), let image = Self.image(from: data) else { return }
        try? FileManager.default.createDirectory(at: AppPaths.covers, withIntermediateDirectories: true)
        try? data.write(to: file, options: .atomic)
        self.image = image
    }

    private static func image(from data: Data) -> Image? {
        #if os(macOS)
        NSImage(data: data).map { Image(nsImage: $0) }
        #else
        UIImage(data: data).map { Image(uiImage: $0) }
        #endif
    }
}
