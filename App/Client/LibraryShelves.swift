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

    var isCloudOnly: Bool { source == .server && !isDownloaded }
}

struct Shelf: Identifiable, Equatable {
    let id: String
    let title: String
    let items: [LibraryItem]
}

enum LibraryShelves {
    static let recentlyAddedLimit = 12

    @MainActor static func items(server: [GameSummary], firstSeen: [String: Date], downloads: DownloadCenter, local: [Game]) -> [LibraryItem] {
        let serverItems = server.map { summary in
            let playable = downloads.playableGame(summary.id)
            return LibraryItem(
                id: summary.id, title: summary.title, console: summary.system.displayName, system: summary.system,
                year: summary.year, genre: summary.genre, coverPath: summary.coverPath, size: summary.totalSize,
                addedAt: summary.addedAt ?? firstSeen[summary.id], source: .server, isDownloaded: downloads.isDownloaded(summary.id),
                playable: playable, lastPlayed: lastPlayed(summary.id))
        }
        let localItems = local.map { game in
            LibraryItem(
                id: game.id, title: game.title, console: game.console, system: CoreRegistry.systemID(forConsole: game.console).flatMap(SystemID.init(rawValue:)), year: nil, genre: nil, coverPath: nil,
                size: (try? FileManager.default.attributesOfItem(atPath: game.fileURL.path)[.size] as? NSNumber)?.int64Value ?? 0,
                addedAt: nil, source: .local, isDownloaded: true, playable: game, lastPlayed: lastPlayed(game.id))
        }
        return serverItems + localItems
    }

    /// Continue Playing, Recently Added, one row per console, then "On this device".
    /// Offline, only games that can launch without the server are shown.
    static func shelves(_ items: [LibraryItem], online: Bool) -> [Shelf] {
        let visible = online ? items : items.filter { $0.playable != nil }
        let server = visible.filter { $0.source == .server }
        var shelves: [Shelf] = []

        var seen = Set<String>()
        let continuing = visible
            .filter { $0.lastPlayed != nil && $0.playable != nil }
            .sorted { $0.lastPlayed! > $1.lastPlayed! }
            .filter { seen.insert($0.id).inserted }
        if !continuing.isEmpty { shelves.append(Shelf(id: "continue", title: "Continue Playing", items: continuing)) }

        let recent = server.filter { $0.addedAt != nil }.sorted { ($0.addedAt!, $1.title) > ($1.addedAt!, $0.title) }
        if online, !recent.isEmpty {
            shelves.append(Shelf(id: "recent", title: "Recently Added", items: Array(recent.prefix(recentlyAddedLimit))))
        }

        for system in SystemID.allCases {
            let games = server.filter { $0.system == system }.sorted(by: titleOrder)
            if !games.isEmpty { shelves.append(Shelf(id: "system-\(system.rawValue)", title: system.displayName, items: games)) }
        }

        let local = visible.filter { $0.source == .local }.sorted(by: titleOrder)
        if !local.isEmpty { shelves.append(Shelf(id: "local", title: "On this device", items: local)) }
        return shelves
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

    private static func lastPlayed(_ gameID: String) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: AppPaths.autoState(for: gameID).path)[.modificationDate]) as? Date
    }
}
