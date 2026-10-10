import Foundation
import GRDB
import HTTPTypes
import Hummingbird
import SupersEmuKit

// Track: server library. GET /v1/games/{id}, /v1/games/{id}/files/{file} (Range), artwork.
func registerLibraryRoutes(_ group: RouterGroup<SERequestContext>, store: ServerStore) {
    let fileIO = FileIO()
    let artwork = ArtworkStore(store: store)

    group.get("games/:id") { _, context -> GameDetail in
        let auth = try context.caller()
        try auth.require(.libraryRead)
        let id = try context.parameters.require("id")
        guard let detail = try LibraryAccess.detail(gameID: id, auth: auth, store: store) else { throw HTTPError(.notFound, message: "Game not found") }
        return detail
    }

    group.get("games/:id/files/:fileID") { request, context -> Response in
        let auth = try context.caller()
        try auth.require(.libraryRead)
        let gameID = try context.parameters.require("id"), fileID = try context.parameters.require("fileID")
        guard let file = try LibraryAccess.file(gameID: gameID, fileID: fileID, auth: auth, store: store),
              let size = (try? FileManager.default.attributesOfItem(atPath: file.url.path)[.size] as? NSNumber)?.intValue else {
            throw HTTPError(.notFound, message: "File not found")
        }

        // File IDs are content hashes, so the ETag is strong and the bytes never change.
        return try await LibraryHTTP.serveImmutableFile(request, context: context, fileIO: fileIO, path: file.url.path,
                                                        size: size, filename: file.filename, eTag: "\"\(fileID)\"")
    }

    @Sendable func serveArtwork(_ request: Request, _ context: SERequestContext, position: Int) async throws -> Response {
        let auth = try context.caller()
        try auth.require(.libraryRead)
        let id = try context.parameters.require("id")
        guard let kind = ArtworkKind(rawValue: try context.parameters.require("kind")) else {
            throw HTTPError(.notFound, message: "Unknown artwork kind")
        }
        let path: String? = try await store.db.read { db in
            guard try Permissions.canSee(gameID: id, auth: auth, db: db),
                  try Bool.fetchOne(db, sql: "SELECT needs_review = 0 FROM games WHERE id = ?", arguments: [id]) == true else { return nil }
            return try ArtworkStore.recordedPath(gameID: id, kind: kind, position: position, db: db)
        }
        guard let url = artwork.coverFile(cover: path) else { throw HTTPError(.notFound, message: "No \(kind.rawValue) artwork") }
        // Artwork can be replaced (metadata service, overrides), so clients revalidate with the content-hash ETag.
        let eTag = "\"\(try ArtworkStore.contentHash(of: url) ?? LibraryHTTP.sha256Hex(of: url))\""
        var headers: HTTPFields = [.eTag: eTag, .cacheControl: "private, no-cache"]
        if LibraryHTTP.ifNoneMatch(request, matches: eTag) { return Response(status: .notModified, headers: headers) }
        headers[.contentType] = ArtworkStore.contentType(for: url)
        return Response(status: .ok, headers: headers, body: try await fileIO.loadFile(path: url.path, context: context))
    }

    group.get("games/:id/artwork/:kind") { request, context in try await serveArtwork(request, context, position: 0) }
    group.get("games/:id/artwork/:kind/:position") { request, context in
        guard let position = Int(try context.parameters.require("position")), position >= 0 else {
            throw HTTPError(.notFound, message: "No artwork")
        }
        return try await serveArtwork(request, context, position: position)
    }
}

/// Permission-checked reads for single games. Games still in the review queue are never served.
enum LibraryAccess {
    struct StoredFile {
        var filename: String
        var url: URL
    }

    static func detail(gameID: String, auth: AuthContext, store: ServerStore) throws -> GameDetail? {
        try store.db.read { db in
            guard try Permissions.canSee(gameID: gameID, auth: auth, db: db),
                  let row = try Row.fetchOne(db, sql: """
                    SELECT g.*, COALESCE((SELECT SUM(size) FROM game_files f WHERE f.game_id = g.id), 0) AS total_size
                    FROM games g WHERE g.id = ? AND g.needs_review = 0
                    """, arguments: [gameID]) else { return nil }
            let files = try Row.fetchAll(db, sql: """
                SELECT * FROM game_files WHERE game_id = ? ORDER BY COALESCE(disc_number, 0), filename
                """, arguments: [gameID]).map { row in
                GameFileInfo(id: row["id"], filename: row["filename"], role: GameFileRole(rawValue: row["role"]) ?? .rom,
                             size: row["size"], discNumber: row["disc_number"])
            }
            let merged = try MetadataMerge.load(gameIDsSQL: "SELECT ?", arguments: [gameID], db: db)[gameID] ?? MetadataMerge.Merged()
            return GameDetail(game: LibraryQueries.summary(from: row, merged: merged), summary: merged.description ?? row["summary"],
                              files: files, developer: merged.developer, logoPath: merged.artworkPath(gameID, .logo),
                              titleScreenPath: merged.artworkPath(gameID, .title),
                              screenshotPaths: merged.screenshotPaths(gameID), sources: merged.sources.isEmpty ? nil : merged.sources)
        }
    }

    static func file(gameID: String, fileID: String, auth: AuthContext, store: ServerStore) throws -> StoredFile? {
        try store.db.read { db in
            guard try Permissions.canSee(gameID: gameID, auth: auth, db: db),
                  let row = try Row.fetchOne(db, sql: """
                    SELECT f.filename, f.stored_path FROM game_files f JOIN games g ON g.id = f.game_id
                    WHERE f.game_id = ? AND f.id = ? AND g.needs_review = 0
                    """, arguments: [gameID, fileID]) else { return nil }
            let storedPath: String = row["stored_path"]
            guard !storedPath.contains("..") else { return nil }
            return StoredFile(filename: row["filename"], url: store.paths.root.appendingPathComponent(storedPath))
        }
    }
}
