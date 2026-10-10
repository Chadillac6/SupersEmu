import CryptoKit
import Foundation
import GRDB

/// Artwork served at `/v1/games/:id/artwork/<kind>[/<position>]`.
public enum ArtworkKind: String, CaseIterable, Sendable {
    case cover, backdrop, logo, title, screenshot
}

/// Artwork lives under `artwork/<gameID>/`. `setCover` is the manual override (`games.cover_artwork`); metadata providers
/// write `<provider>-<kind>-<position>-<sha256>.<ext>` recorded in `game_artwork`. Paths are relative to the data dir.
public struct ArtworkStore: Sendable {
    let store: ServerStore

    public init(store: ServerStore) {
        self.store = store
    }

    @discardableResult
    public func setCover(gameID: String, data: Data, fileExtension: String) throws -> URL {
        let ext = fileExtension.lowercased()
        guard Self.contentTypes[ext] != nil else { throw ArtworkError.unsupportedType(ext) }
        guard data.count <= Self.maxCoverSize else { throw ArtworkError.tooLarge }
        guard Self.isSafeComponent(gameID) else { throw ArtworkError.invalidGameID }
        guard try store.db.read({ try Bool.fetchOne($0, sql: "SELECT EXISTS(SELECT 1 FROM games WHERE id = ?)", arguments: [gameID]) }) == true else {
            throw ArtworkError.unknownGame
        }
        let directory = store.paths.artwork.appendingPathComponent(gameID, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        // Content-addressed name: a path never changes bytes, so the ETag (the hash) always matches what is streamed.
        let name = "cover-\(SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()).\(ext)"
        let url = directory.appendingPathComponent(name)
        // Write, record and clean up as one step so a concurrent update can't delete the cover just recorded.
        try Self.writeLock.withLock {
            try data.write(to: url, options: .atomic)
            try store.db.write { db in
                try db.execute(sql: "UPDATE games SET cover_artwork = ? WHERE id = ?", arguments: ["artwork/\(gameID)/\(name)", gameID])
            }
            let others = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
            for other in others where other != name && other.hasPrefix("cover") {
                try? FileManager.default.removeItem(at: directory.appendingPathComponent(other))
            }
        }
        return url
    }

    @discardableResult
    public func setProviderArtwork(_ kind: ArtworkKind, position: Int = 0, provider: String, gameID: String, data: Data,
                                   fileExtension: String, sourceURL: String? = nil) throws -> URL {
        let ext = fileExtension.lowercased()
        guard Self.contentTypes[ext] != nil else { throw ArtworkError.unsupportedType(ext) }
        guard data.count <= Self.maxCoverSize else { throw ArtworkError.tooLarge }
        guard Self.isSafeComponent(gameID), Self.isSafeComponent(provider), position >= 0 else { throw ArtworkError.invalidGameID }
        guard try store.db.read({ try Bool.fetchOne($0, sql: "SELECT EXISTS(SELECT 1 FROM games WHERE id = ?)", arguments: [gameID]) }) == true else {
            throw ArtworkError.unknownGame
        }
        let directory = store.paths.artwork.appendingPathComponent(gameID, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let prefix = "\(provider)-\(kind.rawValue)-\(position)-"
        let name = "\(prefix)\(SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()).\(ext)"
        let url = directory.appendingPathComponent(name)
        try Self.writeLock.withLock {
            try data.write(to: url, options: .atomic)
            try store.db.write { db in
                try db.execute(sql: """
                    INSERT INTO game_artwork (game_id, provider, kind, position, path, source_url, updated_at) VALUES (?, ?, ?, ?, ?, ?, ?)
                    ON CONFLICT (game_id, provider, kind, position) DO UPDATE SET path = excluded.path, source_url = excluded.source_url,
                        updated_at = excluded.updated_at
                    """, arguments: [gameID, provider, kind.rawValue, position, "artwork/\(gameID)/\(name)", sourceURL, Date()])
            }
            let others = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
            for other in others where other != name && other.hasPrefix(prefix) {
                try? FileManager.default.removeItem(at: directory.appendingPathComponent(other))
            }
        }
        return url
    }

    /// Drops images a provider stored for a game (every slot, or one), deleting only the files its rows recorded and
    /// nothing still referenced elsewhere. The manual cover is untouched.
    public func removeProviderArtwork(provider: String, gameID: String, kind: ArtworkKind? = nil, position: Int = 0) throws {
        guard Self.isSafeComponent(gameID), Self.isSafeComponent(provider) else { throw ArtworkError.invalidGameID }
        try Self.writeLock.withLock {
            let orphans = try store.db.write { db -> [String] in
                let filter = kind == nil ? "" : " AND kind = ? AND position = ?"
                var arguments: StatementArguments = [gameID, provider]
                if let kind { arguments += [kind.rawValue, position] }
                let paths = try String.fetchAll(db, sql: "SELECT path FROM game_artwork WHERE game_id = ? AND provider = ?\(filter)",
                                                arguments: arguments)
                try db.execute(sql: "DELETE FROM game_artwork WHERE game_id = ? AND provider = ?\(filter)", arguments: arguments)
                return try paths.filter { path in
                    try Bool.fetchOne(db, sql: """
                        SELECT EXISTS(SELECT 1 FROM game_artwork WHERE path = ?) OR EXISTS(SELECT 1 FROM games WHERE cover_artwork = ?)
                        """, arguments: [path, path]) != true
                }
            }
            let root = store.paths.artwork.standardizedFileURL.path + "/"
            for path in orphans {
                let url = store.paths.root.appendingPathComponent(path).standardizedFileURL
                if url.path.hasPrefix(root) { try? FileManager.default.removeItem(at: url) }
            }
        }
    }

    /// Recorded path for a kind/position: the manual cover first, then providers in `MetadataMerge` precedence.
    static func recordedPath(gameID: String, kind: ArtworkKind, position: Int, db: Database) throws -> String? {
        if kind == .cover, position == 0,
           let manual = try String.fetchOne(db, sql: "SELECT cover_artwork FROM games WHERE id = ?", arguments: [gameID]) {
            return manual
        }
        let rows = try Row.fetchAll(db, sql: "SELECT provider, path FROM game_artwork WHERE game_id = ? AND kind = ? AND position = ?",
                                    arguments: [gameID, kind.rawValue, position])
        return rows.min { MetadataMerge.rank($0["provider"]) < MetadataMerge.rank($1["provider"]) }?["path"]
    }

    private static let writeLock = NSLock()

    /// The content hash ending a `…-<sha256>.<ext>` filename, if present.
    static func contentHash(of url: URL) -> String? {
        let stem = url.deletingPathExtension().lastPathComponent
        guard let dash = stem.lastIndex(of: "-") else { return nil }
        let hash = String(stem[stem.index(after: dash)...])
        return hash.count == 64 && hash.allSatisfy(\.isHexDigit) ? hash : nil
    }

    /// The artwork file on disk, if one is recorded and present.
    public func coverFile(cover relativePath: String?) -> URL? {
        guard let relativePath, relativePath.hasPrefix("artwork/"), !relativePath.split(separator: "/").contains("..") else { return nil }
        let artworkRoot = store.paths.artwork.resolvingSymlinksInPath().standardizedFileURL.path
        let url = store.paths.root.appendingPathComponent(relativePath).resolvingSymlinksInPath().standardizedFileURL
        guard url.path.hasPrefix(artworkRoot + "/"),
              (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true else { return nil }
        return url
    }

    public enum ArtworkError: Error, Equatable {
        case unsupportedType(String), invalidGameID, unknownGame, tooLarge
    }

    public static let maxCoverSize = 32 * 1024 * 1024

    static func isSafeComponent(_ id: String) -> Bool {
        !id.isEmpty && id.count <= 128 && id.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }
    }

    static let contentTypes = ["png": "image/png", "jpg": "image/jpeg", "jpeg": "image/jpeg", "webp": "image/webp"]

    static func contentType(for url: URL) -> String {
        contentTypes[url.pathExtension.lowercased()] ?? "application/octet-stream"
    }
}
