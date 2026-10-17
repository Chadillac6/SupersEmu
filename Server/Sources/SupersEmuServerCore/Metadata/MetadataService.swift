import CryptoKit
import Foundation
import GRDB
import Hummingbird
import Logging
import SupersEmuKit

// GRDB rows are not Sendable; extract values before leaving the database queue.
private struct PendingMetadataJob: Sendable {
    var id: String
    var system: String
    var title: String
    var matchStatus: String?
    var datasetVersion: String?
    var artworkStatus: String?
    var artworkVersion: String?
    var searchTitle: String?
    var searchYear: Int?
    var providerRef: String?

    init(row: Row) {
        id = row["id"]
        system = row["system"]
        title = row["title"]
        matchStatus = row["match_status"]
        datasetVersion = row["dataset_version"]
        artworkStatus = row["artwork_status"]
        artworkVersion = row["artwork_version"]
        searchTitle = row["search_title"]
        searchYear = row["search_year"]
        providerRef = row["provider_ref"]
    }
}

private struct ProviderArtworkSlot: Hashable, Sendable {
    var kind: ArtworkKind
    var position: Int
}

private struct MetadataRecordFingerprint: Encodable {
    var provider: String
    var providerRef: String?
    var title: String?
    var region: String?
    var year: Int?
    var publisher: String?
    var developer: String?
    var genres: [String]?
    var description: String?
    var players: Int?
    var criticScore: CriticScore?
    var source: MetadataSource?
    var reception: ReceptionSummary?
    var reviewLink: ReviewLink?
    var artworkURLs: [String]
    var artworkCandidates: [String]

    init(record: MetadataRecord, artworkCandidates: [String]) {
        provider = record.provider
        providerRef = record.providerRef
        title = record.title
        region = record.region
        year = record.year
        publisher = record.publisher
        developer = record.developer
        genres = record.genres
        description = record.description
        players = record.players
        criticScore = record.criticScore
        source = record.source
        reception = record.reception
        reviewLink = record.reviewLink
        artworkURLs = (record.artworkURLs ?? [:]).map { "\($0.key.rawValue):\($0.value.absoluteString)" }.sorted()
        self.artworkCandidates = artworkCandidates.sorted()
    }
}

/// Runs every provider over imported games in the background: match, store a `game_metadata` row, then fetch artwork.
/// Failures leave the game as imported (filename title, generated tile) and are retried on the next pass.
public actor MetadataService {
    let store: ServerStore
    let providers: [any MetadataProvider]
    let http: RateLimitedFetcher
    private let artwork: ArtworkStore
    private var running = false
    private var rerun = false
    private var rematchGeneration = 0
    private var rematchedAt: [String: Int] = [:]
    private var rematchAllAt = 0
    private let logger = Logger(label: "supersemu-metadata")

    var pendingRematchCount: Int { rematchedAt.count }

    public init(store: ServerStore, http: RateLimitedFetcher, providers: [any MetadataProvider]) {
        self.store = store
        self.http = http
        self.providers = providers
        self.artwork = ArtworkStore(store: store)
    }

    /// The default: libretro only, at most one request a second.
    public init(store: ServerStore, catalog: MetadataCatalog = .pinned, fetcher: any MetadataFetching = URLSessionMetadataFetcher(),
                minimumInterval: Duration = .seconds(1)) {
        let http = RateLimitedFetcher(fetcher, minimumInterval: minimumInterval)
        self.init(store: store, http: http,
                  providers: [LibretroMetadataProvider(catalog: catalog, cacheRoot: store.paths.metadata, http: http)])
    }

    /// What the server runs: libretro and Wikipedia, plus IGDB and SteamGridDB once their keys are set (`MetadataKeys`).
    public static func standard(store: ServerStore, fetcher: any MetadataFetching = URLSessionMetadataFetcher(),
                                environment: [String: String] = ProcessInfo.processInfo.environment,
                                minimumInterval: Duration = .seconds(1)) -> MetadataService {
        let http = RateLimitedFetcher(fetcher, minimumInterval: minimumInterval)
        let paths = store.paths
        let keys: @Sendable () -> MetadataKeys = { MetadataKeys.load(paths: paths, environment: environment) }
        return MetadataService(store: store, http: http, providers: [
            LibretroMetadataProvider(cacheRoot: paths.metadata, http: http),
            WikipediaMetadataProvider(http: http),
            IGDBMetadataProvider(credentials: { keys().igdb }, http: http),
            SteamGridDBMetadataProvider(key: { keys()[.steamGridDB] }, http: http),
        ])
    }

    /// Starts a background pass (or queues one more if a pass is running). Never blocks the caller.
    public nonisolated func enqueue() {
        Task { await self.runUntilIdle() }
    }

    /// Retries pending games every `interval`, e.g. after the Mac mini was offline.
    public nonisolated func startPeriodicRetry(every interval: Duration = .seconds(30 * 60)) {
        Task {
            while !Task.isCancelled {
                await self.runUntilIdle()
                try? await Task.sleep(for: interval)
            }
        }
    }

    func runUntilIdle() async {
        if running { rerun = true; return }
        running = true
        repeat {
            rerun = false
            await enrichPending()
        } while rerun
        running = false
        rematchedAt.removeAll()
        rematchAllAt = 0
    }

    /// One pass over every game still waiting for a match or artwork. Returns how many games changed.
    @discardableResult
    public func enrichPending() async -> Int {
        var changed = 0
        for provider in providers where provider.isEnabled {
            do {
                changed += try await enrich(with: provider)
            } catch {
                logger.warning("Metadata pass (\(provider.id)) failed: \(error)")
            }
        }
        return changed
    }

    public func rematch(gameIDs: [String]?) async throws -> Int {
        try performRematch(gameIDs: gameIDs, audit: nil)
    }

    func rematch(gameIDs: [String]?, audit: @escaping @Sendable (Database) throws -> Void) async throws -> Int {
        try performRematch(gameIDs: gameIDs, audit: audit)
    }

    private func performRematch(gameIDs: [String]?, audit: (@Sendable (Database) throws -> Void)?) throws -> Int {
        let uniqueIDs = gameIDs.map { Array(Set($0)) }
        let queued = try store.db.read { db -> Int in
            guard let uniqueIDs else { return try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM games") ?? 0 }
            let existing = uniqueIDs.isEmpty ? 0 : try Int.fetchOne(db, sql: """
                SELECT COUNT(*) FROM games WHERE id IN (\(Array(repeating: "?", count: uniqueIDs.count).joined(separator: ",")))
                """, arguments: StatementArguments(uniqueIDs)) ?? 0
            guard existing == uniqueIDs.count else { throw HTTPError(.notFound, message: "Game not found") }
            return uniqueIDs.count
        }

        rematchGeneration += 1
        let generation = rematchGeneration
        if let uniqueIDs {
            for id in uniqueIDs { rematchedAt[id] = generation }
        } else {
            rematchAllAt = generation
        }

        try store.db.write { db in
            if let uniqueIDs {
                if !uniqueIDs.isEmpty {
                    try db.execute(sql: """
                        DELETE FROM metadata_jobs WHERE game_id IN (\(Array(repeating: "?", count: uniqueIDs.count).joined(separator: ",")))
                        """, arguments: StatementArguments(uniqueIDs))
                }
            } else {
                try db.execute(sql: "DELETE FROM metadata_jobs")
            }
            try audit?(db)
        }
        enqueue()
        return queued
    }

    private func enrich(with provider: any MetadataProvider) async throws -> Int {
        if provider.matchesByFileHash, !store.paths.storage.isAvailable {
            logger.warning("\(provider.id) skipped: library storage is unavailable")
            return 0
        }
        let pending: [PendingMetadataJob] = try await store.db.read { db in
            try Row.fetchAll(db, sql: """
                SELECT g.id, g.system, g.title, j.match_status, j.dataset_version, j.artwork_status, j.artwork_version,
                    j.search_title, j.search_year, m.provider_ref FROM games g
                LEFT JOIN metadata_jobs j ON j.game_id = g.id AND j.provider = ?
                LEFT JOIN game_metadata m ON m.game_id = g.id AND m.provider = j.provider
                WHERE g.needs_review = 0 AND (j.game_id IS NULL OR j.match_status IS NULL OR j.dataset_version IS NOT ?
                    OR j.match_status IN ('matched', 'unmatched', 'partial'))
                ORDER BY g.created_at DESC
                """, arguments: [provider.id, provider.version]).map(PendingMetadataJob.init(row:))
        }
        var changed = 0
        var unavailable = Set<SystemID>()
        for row in pending {
            let id: String = row.id
            guard let system = SystemID(rawValue: row.system), !unavailable.contains(system) else { continue }
            let status: String? = row.matchStatus
            let previousRef: String? = row.providerRef
            let knownMetadata = try await knownMetadata(gameID: id, excluding: provider.id)
            let title = knownMetadata.title ?? row.title
            let titleChanged = row.searchTitle != title
            let betterTitle = status == "unmatched" && titleChanged
            let changedSearchTitle = !provider.matchesByFileHash && status == "matched" && titleChanged
            let changedSearchYear = !provider.matchesByFileHash && row.searchYear != knownMetadata.year
            if status == nil || status == "partial" || row.datasetVersion != provider.version || betterTitle || changedSearchTitle
                || changedSearchYear {
                let files = try candidateFiles(gameID: id)
                if provider.matchesByFileHash {
                    guard !files.isEmpty else {
                        logger.warning("\(provider.id) skipped \(id.prefix(12)): no ROM files under the library root")
                        continue
                    }
                    if let unreadable = files.first(where: { !FileManager.default.isReadableFile(atPath: $0.path) }) {
                        logger.warning("\(provider.id) skipped \(id.prefix(12)): ROM not readable at \(unreadable.path)")
                        continue
                    }
                }
                let game = MetadataLookup(gameID: id, system: system, title: title, year: knownMetadata.year, files: files)
                let lookupGeneration = rematchGeneration
                let result: MetadataLookupResult
                do {
                    result = try await provider.lookup(game)
                } catch {
                    if provider.matchesByFileHash {
                        logger.warning("\(provider.id) skipped \(id.prefix(12)): ROM hashing failed: \(error)")
                        continue
                    }
                    result = .unavailable
                }
                if (rematchedAt[id] ?? 0) > lookupGeneration || rematchAllAt > lookupGeneration { continue }
                switch result {
                case .unavailable:
                    unavailable.insert(system)
                    continue
                case .unmatched:
                    try artwork.removeProviderArtwork(provider: provider.id, gameID: id)
                    try await recordJob(id, provider, match: "unmatched", searchTitle: title, searchYear: knownMetadata.year,
                                        clearingRecord: true)
                    changed += 1
                    continue
                case .matched(let record), .partial(let record):
                    var complete = false
                    if case .matched = result { complete = true }
                    if previousRef != nil, previousRef != record.providerRef {
                        try artwork.removeProviderArtwork(provider: provider.id, gameID: id)
                    }
                    try await store.db.write { db in try record.save(gameID: id, db: db) }
                    let recordHash = try Self.recordHash(record, system: system, provider: provider)
                    try await recordJob(id, provider, match: complete ? "matched" : "partial", searchTitle: title,
                                        searchYear: knownMetadata.year,
                                        recordHash: recordHash, clearingRecord: false)
                    logger.info("\(provider.id) matched \(id.prefix(12)) to \"\(record.providerRef ?? record.title ?? "?")\"")
                    changed += 1
                }
            } else if status != "matched" || (row.artworkStatus == "done"
                        && row.artworkVersion == provider.artworkVersion(system: system)) {
                continue
            }
            try await fetchArtwork(gameID: id, system: system, provider: provider)
        }
        return changed
    }

    /// The highest-precedence title and year other providers found, independently for each field.
    private func knownMetadata(gameID: String, excluding provider: String) async throws -> (title: String?, year: Int?) {
        try await store.db.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT provider, title, year FROM game_metadata
                WHERE game_id = ? AND provider != ? AND (title IS NOT NULL OR year IS NOT NULL)
                """, arguments: [gameID, provider])
            let title: String? = rows.filter { ($0["title"] as String?) != nil }
                .min { MetadataMerge.rank($0["provider"]) < MetadataMerge.rank($1["provider"]) }
                .flatMap { row -> String? in row["title"] }
            let year: Int? = rows.filter { ($0["year"] as Int?) != nil }
                .min { MetadataMerge.rank($0["provider"]) < MetadataMerge.rank($1["provider"]) }
                .flatMap { row -> Int? in row["year"] }
            return (title, year)
        }
    }

    private func recordJob(_ gameID: String, _ provider: any MetadataProvider, match: String, searchTitle: String, searchYear: Int?,
                           recordHash: String? = nil, clearingRecord: Bool) async throws {
        try await store.db.write { db in
            if clearingRecord {
                try db.execute(sql: "DELETE FROM game_metadata WHERE game_id = ? AND provider = ?", arguments: [gameID, provider.id])
            }
            try db.execute(sql: """
                INSERT INTO metadata_jobs (game_id, provider, match_status, artwork_status, dataset_version,
                    artwork_version, search_title, search_year, record_hash, updated_at)
                VALUES (?, ?, ?, NULL, ?, ?, ?, ?, ?, ?)
                ON CONFLICT (game_id, provider) DO UPDATE SET
                    match_status = excluded.match_status,
                    artwork_status = NULL,
                    dataset_version = excluded.dataset_version,
                    artwork_version = NULL,
                    search_title = excluded.search_title,
                    search_year = excluded.search_year,
                    record_hash = excluded.record_hash,
                    updated_at = excluded.updated_at
                WHERE metadata_jobs.match_status IS NOT excluded.match_status
                    OR metadata_jobs.dataset_version IS NOT excluded.dataset_version
                    OR metadata_jobs.search_title IS NOT excluded.search_title
                    OR metadata_jobs.search_year IS NOT excluded.search_year
                    OR metadata_jobs.record_hash IS NOT excluded.record_hash
                """, arguments: [gameID, provider.id, match, provider.version, nil as String?, searchTitle, searchYear, recordHash, Date()])
        }
    }

    private static func recordHash(_ record: MetadataRecord, system: SystemID, provider: any MetadataProvider) throws -> String {
        let candidates = provider.artwork(for: record, system: system).flatMap { candidate in
            candidate.urls.map { "\(candidate.kind.rawValue):\(candidate.position):\($0.absoluteString)" }
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(MetadataRecordFingerprint(record: record, artworkCandidates: candidates))
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// Marks artwork done unless a request failed on the network, in which case the next pass retries.
    private func fetchArtwork(gameID: String, system: SystemID, provider: any MetadataProvider) async throws {
        let record = try await store.db.read { db in
            try Row.fetchOne(db, sql: "SELECT * FROM game_metadata WHERE game_id = ? AND provider = ?", arguments: [gameID, provider.id])
                .map(MetadataRecord.init(row:))
        }
        guard let record else { return }
        let candidates = provider.artwork(for: record, system: system)
        let candidateSlots = Set(candidates.map { ProviderArtworkSlot(kind: $0.kind, position: $0.position) })
        let staleSlots = try await store.db.read { db in
            try Row.fetchAll(db, sql: "SELECT kind, position FROM game_artwork WHERE game_id = ? AND provider = ?",
                             arguments: [gameID, provider.id]).compactMap { row -> ProviderArtworkSlot? in
                guard let kind = ArtworkKind(rawValue: row["kind"]) else { return nil }
                let slot = ProviderArtworkSlot(kind: kind, position: row["position"])
                return candidateSlots.contains(slot) ? nil : slot
            }
        }
        for slot in staleSlots {
            try artwork.removeProviderArtwork(provider: provider.id, gameID: gameID, kind: slot.kind, position: slot.position)
        }
        var deferred = false
        for candidate in candidates {
            var found = false, invalid = false
            for url in candidate.urls {
                let data: Data?
                do {
                    data = try await http.get(url)
                } catch {
                    logger.info("Artwork for \(gameID.prefix(12)) deferred: \(error)")
                    try await store.db.write { db in
                        try db.execute(sql: """
                            UPDATE metadata_jobs SET artwork_status = 'failed', updated_at = ?
                            WHERE game_id = ? AND provider = ?
                            """, arguments: [Date(), gameID, provider.id])
                    }
                    return
                }
                guard let data else { continue }
                guard let ext = Self.imageExtension(data) else { invalid = true; continue }
                try artwork.setProviderArtwork(candidate.kind, position: candidate.position, provider: provider.id, gameID: gameID,
                                               data: data, fileExtension: ext, sourceURL: url.absoluteString)
                found = true
                break
            }
            if !found && invalid {
                logger.info("Artwork for \(gameID.prefix(12)) deferred: \(candidate.kind.rawValue) wasn't an image")
                deferred = true
            } else if !found {
                try artwork.removeProviderArtwork(provider: provider.id, gameID: gameID, kind: candidate.kind, position: candidate.position)
            }
        }
        if deferred { return }
        try await store.db.write { db in
            try db.execute(sql: """
                UPDATE metadata_jobs SET artwork_status = 'done', artwork_version = ?, updated_at = ? WHERE game_id = ? AND provider = ?
                """, arguments: [provider.artworkVersion(system: system), Date(), gameID, provider.id])
        }
    }

    static func imageExtension(_ data: Data) -> String? {
        if data.starts(with: [0x89, 0x50, 0x4E, 0x47]) { return "png" }
        if data.starts(with: [0xFF, 0xD8, 0xFF]) { return "jpg" }
        return nil
    }

    /// ROM, or every track of the first disc (lookup stops at the first match), resolved and contained under the library root.
    private func candidateFiles(gameID: String) throws -> [URL] {
        let rows = try store.db.read { db in
            try Row.fetchAll(db, sql: """
                SELECT stored_path, disc_number FROM game_files WHERE game_id = ? AND role IN ('rom', 'disc')
                ORDER BY COALESCE(disc_number, 1), filename
                """, arguments: [gameID])
        }
        let firstDisc: Int? = rows.first?["disc_number"]
        let root = store.paths.libraryRoot.resolvingSymlinksInPath().standardizedFileURL.path
        return rows.filter { ($0["disc_number"] as Int?) == firstDisc }.compactMap { row in
            let path: String = row["stored_path"]
            let url = store.paths.libraryFile(path).resolvingSymlinksInPath().standardizedFileURL
            return url.path.hasPrefix(root + "/") ? url : nil
        }
    }
}
