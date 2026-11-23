import Foundation
import SupersEmuKit

/// One tile in the library: a game on the server (downloaded or cloud-only) or one imported on this device.
struct LibraryItem: Identifiable, Hashable {
    enum Source: Hashable { case server, local }

    let id: String
    let title: String
    let console: String
    let system: SystemID?
    let year: Int?
    let genre: String?
    let coverPath: String?
    let size: Int64
    let addedAt: Date?
    let source: Source
    let isDownloaded: Bool
    /// Set when the game can launch right now (local import or downloaded server game).
    let playable: Game?
    let lastPlayed: Date?
    var heroPath: String?
    var logoPath: String?
    var genres: [String]?
    var players: Int?
    var criticScore: Int?
    var hasLocalCopy = false

    var isCloudOnly: Bool { source == .server && !isDownloaded && !hasLocalCopy }
    /// A server game the user also imported locally (and hasn't downloaded from the server).
    var isLocalCopy: Bool { source == .local || (hasLocalCopy && !isDownloaded) }
}

/// What the Home screen shows for the selected console (nil is "All").
struct HomeSections: Equatable {
    /// Consoles the library has, for the selector.
    var systems: [SystemID]
    /// Most recently played, else the newest game.
    var featured: LibraryItem?
    var currentlyPlaying: [LibraryItem]
    var allGames: [LibraryItem]
    var downloaded: [LibraryItem]
    var notDownloaded: [LibraryItem]
}

enum LibraryShelves {
    static let recentlyAddedLimit = 12

    /// Drops consoles this device can't show, such as PS2 on iPhone and iPad.
    static func visible(_ items: [LibraryItem], on platform: DevicePlatform = .current) -> [LibraryItem] {
        items.filter { $0.system?.isShown(on: platform) ?? true }
    }

    /// Offline, only games that can launch without the server are shown.
    static func home(_ items: [LibraryItem], system: SystemID?, online: Bool) -> HomeSections {
        let visible = online ? items : items.filter { $0.playable != nil }
        let systems = SystemID.allCases.filter { system in visible.contains { $0.system == system } }
        let shown = system.map { system in visible.filter { $0.system == system } } ?? visible

        var seen = Set<String>()
        let playing = shown
            .filter { $0.lastPlayed != nil && $0.playable != nil }
            .sorted { $0.lastPlayed! > $1.lastPlayed! }
            .filter { seen.insert($0.id).inserted }
        seen = []
        let sorted = shown.sorted(by: titleOrder).filter { seen.insert($0.id).inserted }
        let newest = sorted.filter { $0.addedAt != nil }.max { $0.addedAt! < $1.addedAt! }
        let downloaded = sorted.filter { !$0.isCloudOnly }
        let notDownloaded = sorted.filter(\.isCloudOnly)
        return HomeSections(systems: systems, featured: playing.first ?? newest ?? sorted.first, currentlyPlaying: playing,
                            allGames: sorted, downloaded: downloaded, notDownloaded: notDownloaded)
    }

    /// Games `home` leaves out offline because they can't launch without the server.
    static func offlineUnavailableCount(_ items: [LibraryItem]) -> Int {
        items.filter { $0.source == .server && !$0.isDownloaded }.count
    }

    static func search(_ items: [LibraryItem], query: String, online: Bool) -> [LibraryItem] {
        let visible = online ? items : items.filter { $0.playable != nil }
        let query = query.trimmingCharacters(in: .whitespaces)
        var seen = Set<String>()
        return visible
            .filter { $0.title.localizedCaseInsensitiveContains(query) || $0.console.localizedCaseInsensitiveContains(query) }
            .sorted(by: titleOrder)
            .filter { seen.insert($0.id).inserted }
    }

    private static func titleOrder(_ a: LibraryItem, _ b: LibraryItem) -> Bool {
        a.title.localizedStandardCompare(b.title) == .orderedAscending
    }
}
