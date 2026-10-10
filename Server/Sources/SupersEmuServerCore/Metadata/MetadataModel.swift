import Foundation
import GRDB
import SupersEmuKit

/// What one provider knows about one game. Every field is optional.
public struct MetadataRecord: Sendable, Equatable {
    public var provider: String
    /// The provider's identifier for the game (libretro: the No-Intro/Redump entry name).
    public var providerRef: String?
    public var title: String?
    public var region: String?
    public var year: Int?
    public var publisher: String?
    public var developer: String?
    public var genres: [String]?
    public var description: String?
    public var players: Int?
    public var criticScore: CriticScore?
    public var source: MetadataSource?

    public init(provider: String, providerRef: String? = nil, title: String? = nil, region: String? = nil, year: Int? = nil,
                publisher: String? = nil, developer: String? = nil, genres: [String]? = nil, description: String? = nil,
                players: Int? = nil, criticScore: CriticScore? = nil, source: MetadataSource? = nil) {
        self.provider = provider
        self.providerRef = providerRef
        self.title = title
        self.region = region
        self.year = year
        self.publisher = publisher
        self.developer = developer
        self.genres = genres
        self.description = description
        self.players = players
        self.criticScore = criticScore
        self.source = source
    }

    func save(gameID: String, db: Database) throws {
        let genresJSON = try genres.map { String(decoding: try JSONEncoder().encode($0), as: UTF8.self) }
        try db.execute(sql: """
            INSERT OR REPLACE INTO game_metadata (game_id, provider, provider_ref, title, region, year, publisher, developer, genres,
                description, players, critic_score, critic_source, critic_url, source_name, source_url, updated_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """, arguments: [gameID, provider, providerRef, title, region, year, publisher, developer, genresJSON, description, players,
                             criticScore?.score, criticScore?.source, criticScore?.url, source?.name, source?.url, Date()])
    }

    init(row: Row) {
        let genresJSON: String? = row["genres"]
        let score: Int? = row["critic_score"]
        let sourceName: String? = row["source_name"]
        self.init(provider: row["provider"], providerRef: row["provider_ref"], title: row["title"], region: row["region"],
                  year: row["year"], publisher: row["publisher"], developer: row["developer"],
                  genres: genresJSON.flatMap { try? JSONDecoder().decode([String].self, from: Data($0.utf8)) },
                  description: row["description"], players: row["players"],
                  criticScore: score.map { CriticScore(score: $0, source: row["critic_source"] ?? "", url: row["critic_url"]) },
                  source: sourceName.map { MetadataSource(provider: row["provider"], name: $0, url: row["source_url"]) })
    }
}

/// Per-field merge across providers. Higher-precedence providers win field by field; unknown providers rank last.
public enum MetadataMerge {
    public static let precedence = ["manual", "igdb", "screenscraper", "thegamesdb", "libretro"]

    static func rank(_ provider: String) -> Int {
        precedence.firstIndex(of: provider) ?? precedence.count
    }

    public struct Merged: Sendable, Equatable {
        public var title, region, publisher, developer, description: String?
        public var year, players: Int?
        public var genres: [String]?
        public var criticScore: CriticScore?
        public var sources: [MetadataSource] = []
        /// Kind -> positions that have artwork from some provider.
        var artwork: [ArtworkKind: Set<Int>] = [:]

        public init() {}

        func artworkPath(_ gameID: String, _ kind: ArtworkKind) -> String? {
            artwork[kind]?.contains(0) == true ? "/v1/games/\(gameID)/artwork/\(kind.rawValue)" : nil
        }

        func screenshotPaths(_ gameID: String) -> [String]? {
            guard let positions = artwork[.screenshot], !positions.isEmpty else { return nil }
            return positions.sorted().map { "/v1/games/\(gameID)/artwork/screenshot/\($0)" }
        }
    }

    public static func merge(_ records: [MetadataRecord]) -> Merged {
        var merged = Merged()
        for record in records.sorted(by: { rank($0.provider) < rank($1.provider) }) {
            merged.title = merged.title ?? record.title
            merged.region = merged.region ?? record.region
            merged.year = merged.year ?? record.year
            merged.publisher = merged.publisher ?? record.publisher
            merged.developer = merged.developer ?? record.developer
            merged.description = merged.description ?? record.description
            merged.players = merged.players ?? record.players
            merged.criticScore = merged.criticScore ?? record.criticScore
            if merged.genres == nil, let genres = record.genres, !genres.isEmpty { merged.genres = genres }
            if let source = record.source { merged.sources.append(source) }
        }
        return merged
    }

    /// Merged metadata and artwork presence for every game in `gameIDsSQL` (a `SELECT id …` subquery).
    static func load(gameIDsSQL: String, arguments: StatementArguments, db: Database) throws -> [String: Merged] {
        var records: [String: [MetadataRecord]] = [:]
        for row in try Row.fetchAll(db, sql: "SELECT * FROM game_metadata WHERE game_id IN (\(gameIDsSQL))", arguments: arguments) {
            records[row["game_id"], default: []].append(MetadataRecord(row: row))
        }
        var result = records.mapValues(merge)
        for row in try Row.fetchAll(db, sql: "SELECT DISTINCT game_id, kind, position FROM game_artwork WHERE game_id IN (\(gameIDsSQL))",
                                    arguments: arguments) {
            guard let kind = ArtworkKind(rawValue: row["kind"]) else { continue }
            result[row["game_id"], default: Merged()].artwork[kind, default: []].insert(row["position"])
        }
        return result
    }
}
