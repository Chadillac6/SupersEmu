import Foundation
import GRDB
import Logging
import SupersEmuKit

/// Runs every provider over imported games in the background: match, store a `game_metadata` row, then fetch artwork.
/// Failures leave the game as imported (filename title, generated tile) and are retried on the next pass.
public actor MetadataService {
    let store: ServerStore
    let providers: [any MetadataProvider]
    let http: RateLimitedFetcher
    private let artwork: ArtworkStore
    private var running = false
    private var rerun = false
    private let logger = Logger(label: "supersemu-metadata")

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

    private func enrich(with provider: any MetadataProvider) async throws -> Int {
        let pending = try await store.db.read { db in
            try Row.fetchAll(db, sql: """
                SELECT g.id, g.system, g.title, j.match_status, j.dataset_version, j.artwork_status, j.artwork_version,
                    m.provider_ref FROM games g
                LEFT JOIN metadata_jobs j ON j.game_id = g.id AND j.provider = ?
                LEFT JOIN game_metadata m ON m.game_id = g.id AND m.provider = j.provider
                WHERE g.needs_review = 0 AND (j.game_id IS NULL OR j.match_status IS NULL OR j.dataset_version IS NOT ?
                    OR (j.match_status = 'matched'))
                ORDER BY g.created_at DESC
                """, arguments: [provider.id, provider.version])
        }
        var changed = 0
        var unavailable = Set<SystemID>()
        for row in pending {
            let id: String = row["id"]
            guard let system = SystemID(rawValue: row["system"]), !unavailable.contains(system) else { continue }
            let status: String? = row["match_status"]
            let previousRef: String? = row["provider_ref"]
            if status == nil || (row["dataset_version"] as String?) != provider.version {
                let title = try await knownTitle(gameID: id, excluding: provider.id) ?? row["title"]
                let game = MetadataLookup(gameID: id, system: system, title: title, files: try candidateFiles(gameID: id))
                let result = (try? await provider.lookup(game)) ?? .unavailable
                switch result {
                case .unavailable:
                    unavailable.insert(system)
                    continue
                case .unmatched:
                    try artwork.removeProviderArtwork(provider: provider.id, gameID: id)
                    try await recordJob(id, provider, match: "unmatched", clearingRecord: true)
                    changed += 1
                    continue
                case .matched(let record):
                    if previousRef != nil, previousRef != record.providerRef {
                        try artwork.removeProviderArtwork(provider: provider.id, gameID: id)
                    }
                    try await store.db.write { db in try record.save(gameID: id, db: db) }
                    try await recordJob(id, provider, match: "matched", clearingRecord: false)
                    logger.info("\(provider.id) matched \(id.prefix(12)) to \"\(record.providerRef ?? record.title ?? "?")\"")
                    changed += 1
                }
            } else if status != "matched" || ((row["artwork_status"] as String?) != nil
                        && (row["artwork_version"] as String?) == provider.artworkVersion(system: system)) {
                continue
            }
            try await fetchArtwork(gameID: id, system: system, provider: provider)
        }
        return changed
    }

    /// The highest-precedence title another provider found, so name-searching providers search the canonical title.
    private func knownTitle(gameID: String, excluding provider: String) async throws -> String? {
        try await store.db.read { db in
            try Row.fetchAll(db, sql: "SELECT provider, title FROM game_metadata WHERE game_id = ? AND provider != ? AND title IS NOT NULL",
                             arguments: [gameID, provider])
                .min { MetadataMerge.rank($0["provider"]) < MetadataMerge.rank($1["provider"]) }?["title"]
        }
    }

    private func recordJob(_ gameID: String, _ provider: any MetadataProvider, match: String, clearingRecord: Bool) async throws {
        try await store.db.write { db in
            if clearingRecord {
                try db.execute(sql: "DELETE FROM game_metadata WHERE game_id = ? AND provider = ?", arguments: [gameID, provider.id])
            }
            try db.execute(sql: """
                INSERT OR REPLACE INTO metadata_jobs (game_id, provider, match_status, artwork_status, dataset_version, updated_at)
                VALUES (?, ?, ?, NULL, ?, ?)
                """, arguments: [gameID, provider.id, match, provider.version, Date()])
        }
    }

    /// Marks artwork done unless a request failed on the network, in which case the next pass retries.
    private func fetchArtwork(gameID: String, system: SystemID, provider: any MetadataProvider) async throws {
        let record = try await store.db.read { db in
            try Row.fetchOne(db, sql: "SELECT * FROM game_metadata WHERE game_id = ? AND provider = ?", arguments: [gameID, provider.id])
                .map(MetadataRecord.init(row:))
        }
        guard let record else { return }
        for candidate in provider.artwork(for: record, system: system) {
            var found = false
            for url in candidate.urls {
                let data: Data?
                do {
                    data = try await http.get(url)
                } catch {
                    logger.info("Artwork for \(gameID.prefix(12)) deferred: \(error)")
                    return
                }
                guard let data else { continue }
                guard let ext = Self.imageExtension(data) else { break }
                try artwork.setProviderArtwork(candidate.kind, position: candidate.position, provider: provider.id, gameID: gameID,
                                               data: data, fileExtension: ext, sourceURL: url.absoluteString)
                found = true
                break
            }
            if !found {
                try artwork.removeProviderArtwork(provider: provider.id, gameID: gameID, kind: candidate.kind, position: candidate.position)
            }
        }
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

    /// ROM, or every track of the first disc (lookup stops at the first match), resolved and contained under the store root.
    private func candidateFiles(gameID: String) throws -> [URL] {
        let rows = try store.db.read { db in
            try Row.fetchAll(db, sql: """
                SELECT stored_path, disc_number FROM game_files WHERE game_id = ? AND role IN ('rom', 'disc')
                ORDER BY COALESCE(disc_number, 1), filename
                """, arguments: [gameID])
        }
        let firstDisc: Int? = rows.first?["disc_number"]
        let root = store.paths.root.resolvingSymlinksInPath().standardizedFileURL.path
        return rows.filter { ($0["disc_number"] as Int?) == firstDisc }.compactMap { row in
            let path: String = row["stored_path"]
            let url = store.paths.root.appendingPathComponent(path).resolvingSymlinksInPath().standardizedFileURL
            return url.path.hasPrefix(root + "/") ? url : nil
        }
    }
}
