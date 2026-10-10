import CryptoKit
import Foundation
import SupersEmuKit
@testable import SupersEmuServerCore
import XCTest

/// Multi-disc track: one library entry per game, and the file-list downloader fetches every disc.
extension ClientCacheTests {
    func testDownloadsEveryFileOfSyntheticMultiDiscGame() async throws {
        let disc1 = Self.randomBytes(300 * 1024 + 3)
        let disc2 = Self.randomBytes(200 * 1024 + 5)
        let playlist = Data("Synthetic Quest (Disc 1).chd\nSynthetic Quest (Disc 2).chd\n".utf8)
        let files: [(name: String, role: GameFileRole, disc: Int?, bytes: Data)] = [
            ("Synthetic Quest.m3u", .m3u, nil, playlist),
            ("Synthetic Quest (Disc 1).chd", .disc, 1, disc1),
            ("Synthetic Quest (Disc 2).chd", .disc, 2, disc2),
        ]
        let gameID = Self.sha(disc1)
        try insertFiles(gameID: gameID, title: "Synthetic Quest", system: .psx, files: files)
        let total = Int64(files.reduce(0) { $0 + $1.bytes.count })
        let updates = ProgressLog()
        try await withClient(app()) { client in
            let library = try await client.library()
            XCTAssertEqual(library.games.map(\.id), [gameID], "a multi-disc game is a single library entry (one tile)")
            XCTAssertEqual(library.games.first?.totalSize, total)
            let detail = try await client.gameDetail(gameID)
            XCTAssertEqual(detail.files.count, 3)
            XCTAssertEqual(detail.discCount, 2)
            XCTAssertEqual(detail.totalFileSize, total)
            _ = try await GameDownloader(client: client, cache: self.cache).download(gameID: gameID) { updates.append($0) }
        }
        let cached = try XCTUnwrap(cache.cachedGame(gameID), "all three files verify against their SHA-256")
        XCTAssertEqual(cached.detail.files.count, 3)
        for file in files {
            let url = cacheRoot.appendingPathComponent(gameID).appendingPathComponent(file.name)
            XCTAssertEqual(try Data(contentsOf: url), file.bytes, file.name)
        }
        XCTAssertEqual(cache.launchFileURL(for: cached)?.lastPathComponent, "Synthetic Quest.m3u", "disc games launch from the playlist")
        XCTAssertEqual(updates.values.last, DownloadProgress(receivedBytes: total, totalBytes: total))
    }

    /// Sync (not async) so GRDB's blocking `write` is used, matching `insertGame`.
    func insertFiles(gameID: String, title: String, system: SystemID,
                     files: [(name: String, role: GameFileRole, disc: Int?, bytes: Data)]) throws {
        let stored = store.paths.games.appendingPathComponent(gameID, isDirectory: true)
        try FileManager.default.createDirectory(at: stored, withIntermediateDirectories: true)
        for file in files { try file.bytes.write(to: stored.appendingPathComponent(file.name)) }
        try store.db.write { db in
            try db.execute(sql: "INSERT INTO games (id, title, system, created_at) VALUES (?, ?, ?, ?)",
                           arguments: [gameID, title, system.rawValue, Date()])
            for file in files {
                try db.execute(sql: "INSERT INTO game_files (id, game_id, filename, role, size, stored_path, disc_number) VALUES (?, ?, ?, ?, ?, ?, ?)",
                               arguments: [Self.sha(file.bytes), gameID, file.name, file.role.rawValue, file.bytes.count,
                                           "games/\(gameID)/\(file.name)", file.disc])
            }
        }
    }

    static func sha(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
}
