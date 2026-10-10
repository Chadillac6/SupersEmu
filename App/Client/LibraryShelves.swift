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

    var isCloudOnly: Bool { source == .server && !isDownloaded }
}

/// One letter of "All Games A-Z".
struct LetterSection: Identifiable, Equatable {
    let id: String
    let items: [LibraryItem]
}

/// What the Home screen shows for the selected console (nil is "All").
struct HomeSections: Equatable {
    /// Consoles the library has, for the selector.
    var systems: [SystemID]
    /// Most recently played, else the newest game.
    var featured: LibraryItem?
    var currentlyPlaying: [LibraryItem]
    var letters: [LetterSection]
}

enum LibraryShelves {
    static let recentlyAddedLimit = 12

    @MainActor static func items(server: [GameSummary], firstSeen: [String: Date], downloads: DownloadCenter, local: [Game]) -> [LibraryItem] {
        // A local copy of a server game shows once, with the server's metadata, and plays from the local file if not downloaded.
        let localByID = Dictionary(local.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let serverIDs = Set(server.map(\.id))
        let serverItems = server.map { summary in
            let playable = downloads.playableGame(summary.id) ?? localByID[summary.id]
            return LibraryItem(
                id: summary.id, title: summary.title, console: summary.system.displayName, system: summary.system,
                year: summary.year, genre: summary.genre, coverPath: summary.coverPath, size: summary.totalSize,
                addedAt: summary.addedAt ?? firstSeen[summary.id], source: .server, isDownloaded: downloads.isDownloaded(summary.id),
                playable: playable, lastPlayed: lastPlayed(summary.id), heroPath: summary.heroPath ?? summary.backdropPath,
                logoPath: summary.logoPath, genres: summary.genres, players: summary.players, criticScore: summary.criticScore?.score)
        }
        let localItems = local.filter { !serverIDs.contains($0.id) }.map { game in
            LibraryItem(
                id: game.id, title: game.title, console: game.console, system: CoreRegistry.systemID(forConsole: game.console).flatMap(SystemID.init(rawValue:)), year: nil, genre: nil, coverPath: nil,
                size: (try? FileManager.default.attributesOfItem(atPath: game.fileURL.path)[.size] as? NSNumber)?.int64Value ?? 0,
                addedAt: nil, source: .local, isDownloaded: true, playable: game, lastPlayed: lastPlayed(game.id))
        }
        return serverItems + localItems
    }

    static let alphabet = ["#"] + (UnicodeScalar("A").value...UnicodeScalar("Z").value).map { String(UnicodeScalar($0)!) }

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
        let groups = Dictionary(grouping: sorted, by: { letter(for: $0.title) })
        return HomeSections(systems: systems, featured: playing.first ?? newest ?? sorted.first, currentlyPlaying: playing,
                            letters: alphabet.compactMap { letter in groups[letter].map { LetterSection(id: letter, items: $0) } })
    }

    /// "A"-"Z" by the first letter (accents folded), "#" for everything else.
    static func letter(for title: String) -> String {
        let first = title.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil).uppercased().first.map(String.init) ?? "#"
        return alphabet.contains(first) ? first : "#"
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
