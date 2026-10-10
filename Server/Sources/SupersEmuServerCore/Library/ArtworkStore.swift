import Foundation
import GRDB

/// Artwork lives under `artwork/<gameID>/`; `games.cover_artwork` holds the path relative to the data dir.
/// M2 scraping calls `setCover` (the hook); serving only reads what's recorded here.
public struct ArtworkStore: Sendable {
    let store: ServerStore

    public init(store: ServerStore) {
        self.store = store
    }

    @discardableResult
    public func setCover(gameID: String, data: Data, fileExtension: String) throws -> URL {
        let ext = fileExtension.lowercased()
        guard Self.contentTypes[ext] != nil else { throw ArtworkError.unsupportedType(ext) }
        guard Self.isSafeComponent(gameID) else { throw ArtworkError.invalidGameID }
        guard try store.db.read({ try Bool.fetchOne($0, sql: "SELECT EXISTS(SELECT 1 FROM games WHERE id = ?)", arguments: [gameID]) }) == true else {
            throw ArtworkError.unknownGame
        }
        let directory = store.paths.artwork.appendingPathComponent(gameID, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("cover.\(ext)")
        try data.write(to: url, options: .atomic)
        try store.db.write { db in
            try db.execute(sql: "UPDATE games SET cover_artwork = ? WHERE id = ?", arguments: ["artwork/\(gameID)/cover.\(ext)", gameID])
        }
        return url
    }

    /// The cover file on disk, if one is recorded and present.
    public func coverFile(cover relativePath: String?) -> URL? {
        guard let relativePath, relativePath.hasPrefix("artwork/"), !relativePath.split(separator: "/").contains("..") else { return nil }
        let artworkRoot = store.paths.artwork.resolvingSymlinksInPath().standardizedFileURL.path
        let url = store.paths.root.appendingPathComponent(relativePath).resolvingSymlinksInPath().standardizedFileURL
        guard url.path.hasPrefix(artworkRoot + "/"),
              (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true else { return nil }
        return url
    }

    public enum ArtworkError: Error, Equatable {
        case unsupportedType(String), invalidGameID, unknownGame
    }

    static func isSafeComponent(_ id: String) -> Bool {
        !id.isEmpty && id.count <= 128 && id.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }
    }

    static let contentTypes = ["png": "image/png", "jpg": "image/jpeg", "jpeg": "image/jpeg", "webp": "image/webp"]

    static func contentType(for url: URL) -> String {
        contentTypes[url.pathExtension.lowercased()] ?? "application/octet-stream"
    }
}
