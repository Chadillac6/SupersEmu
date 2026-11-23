import Foundation
import SupersEmuKit

extension LibraryShelves {
    @MainActor static func items(server: [GameSummary], firstSeen: [String: Date], downloads: DownloadCenter, local: [Game]) -> [LibraryItem] {
        // A local copy of a server game shows once, with the server's metadata, and plays from the local file if not downloaded.
        let localByID = Dictionary(local.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let serverIDs = Set(server.map(\.id))
        let serverItems = server.map { summary in
            let playable = downloads.playableGame(summary.id) ?? localByID[summary.id]
            return LibraryItem(
                id: summary.id, title: summary.title, console: summary.system.displayName, system: summary.system,
                year: summary.year, genre: summary.genre, coverPath: summary.coverPath, size: summary.totalSize,
                addedAt: summary.addedAt ?? firstSeen[summary.id], source: .server,
                isDownloaded: downloads.isDownloaded(summary.id),
                playable: playable, lastPlayed: lastPlayed(summary.id), heroPath: summary.heroPath ?? summary.backdropPath,
                logoPath: summary.logoPath, genres: summary.genres, players: summary.players, criticScore: summary.criticScore?.score,
                hasLocalCopy: localByID[summary.id] != nil)
        }
        let localItems = local.filter { !serverIDs.contains($0.id) }.map { game in
            LibraryItem(
                id: game.id, title: game.title, console: game.console, system: CoreRegistry.systemID(forConsole: game.console).flatMap(SystemID.init(rawValue:)), year: nil, genre: nil, coverPath: nil,
                size: (try? FileManager.default.attributesOfItem(atPath: game.fileURL.path)[.size] as? NSNumber)?.int64Value ?? 0,
                addedAt: nil, source: .local, isDownloaded: true, playable: game, lastPlayed: lastPlayed(game.id))
        }
        return visible(serverItems + localItems)
    }

    private static func lastPlayed(_ gameID: String) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: AppPaths.autoState(for: gameID).path)[.modificationDate]) as? Date
    }
}
