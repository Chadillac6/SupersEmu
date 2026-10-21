import CryptoKit
import Foundation
import GRDB
import HTTPTypes
import Hummingbird
import HummingbirdTesting
import SupersEmuKit
@testable import SupersEmuServerCore
import XCTest

/// Download/cache manager (client track) against a live in-process SupersEmu Server: real store,
/// real token auth, permissions and the library track's `GET /v1/games/{id}` + Range file routes.
final class ClientCacheTests: XCTestCase {
    var store: ServerStore!
    var token: String!
    var cacheRoot: URL!
    var cache: GameCache { GameCache(root: cacheRoot) }
    var rangeRequests: RequestLog!

    override func setUp() async throws {
        store = try ServerStore.inMemory()
        let admin = try store.createUser(displayName: "Chad", role: .admin)
        token = try store.createDeviceToken(userID: admin.id, deviceName: "Test Mac").token
        cacheRoot = FileManager.default.temporaryDirectory.appendingPathComponent("cache-\(UUID().uuidString)", isDirectory: true)
        rangeRequests = RequestLog()
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: cacheRoot)
        try? FileManager.default.removeItem(at: store.paths.root)
    }

    /// Inserts a game row + file directly (as the library track's import would) and returns its detail.
    @discardableResult
    /// `servedBytes` lets a test store different bytes than the advertised SHA-256 (corruption).
    func insertGame(title: String, bytes: Data, filename: String = "Test.sfc", servedBytes: Data? = nil) throws -> GameDetail {
        let sha = SHA256.hash(data: bytes).hexString
        let stored = store.paths.games.appendingPathComponent(sha, isDirectory: true)
        try FileManager.default.createDirectory(at: stored, withIntermediateDirectories: true)
        try (servedBytes ?? bytes).write(to: stored.appendingPathComponent(filename))
        try store.db.write { db in
            try db.execute(sql: "INSERT INTO games (id, title, system, created_at) VALUES (?, ?, 'snes', ?)", arguments: [sha, title, Date()])
            try db.execute(sql: "INSERT INTO game_files (id, game_id, filename, role, size, stored_path) VALUES (?, ?, ?, 'rom', ?, ?)",
                           arguments: [sha, sha, filename, bytes.count, "games/\(sha)/\(filename)"])
        }
        let summary = GameSummary(id: sha, title: title, system: .snes, year: nil, genre: nil, coverPath: nil, totalSize: Int64(bytes.count))
        return GameDetail(game: summary, summary: nil, files: [GameFileInfo(id: sha, filename: filename, role: .rom, size: Int64(bytes.count), discNumber: nil)])
    }

    func app(ignoreRange: Bool = false) -> some ApplicationProtocol {
        let responder = RangeObservingResponder(inner: buildRouter(store: store).buildResponder(), log: rangeRequests, ignoreRange: ignoreRange)
        return Application(responder: responder, configuration: .init())
    }

    func withClient(_ app: some ApplicationProtocol, _ body: @escaping (APIClient) async throws -> Void) async throws {
        try await app.test(.live) { client in
            let port = try XCTUnwrap(client.port)
            try await body(APIClient(baseURL: URL(string: "http://localhost:\(port)")!, token: self.token))
        }
    }

    static func randomBytes(_ count: Int) -> Data { Data((0..<count).map { _ in UInt8.random(in: 0...255) }) }

    func testDownloadVerifiesAndCachesGame() async throws {
        let bytes = Self.randomBytes(3 * 1024 * 1024 + 17)
        let detail = try insertGame(title: "Alpha", bytes: bytes)
        let updates = ProgressLog()
        try await withClient(app()) { client in
            let library = try await client.library()
            XCTAssertEqual(library.games.map(\.id), [detail.game.id])
            XCTAssertNotNil(library.games.first?.addedAt)
            let cached = try await GameDownloader(client: client, cache: self.cache).download(gameID: detail.game.id) { updates.append($0) }
            XCTAssertEqual(cached.detail.game.id, detail.game.id)
            XCTAssertEqual(cached.detail.files, detail.files)
        }
        let cached = try XCTUnwrap(cache.cachedGame(detail.game.id))
        let launch = try XCTUnwrap(cache.launchFileURL(for: cached))
        XCTAssertEqual(launch.path, cacheRoot.appendingPathComponent(detail.game.id).appendingPathComponent("Test.sfc").path)
        XCTAssertEqual(try Data(contentsOf: launch), bytes)
        XCTAssertEqual(cache.cachedGames().map(\.detail.game.title), ["Alpha"])
        XCTAssertEqual(updates.values.last, DownloadProgress(receivedBytes: Int64(bytes.count), totalBytes: Int64(bytes.count)))
        XCTAssertGreaterThan(updates.values.count, 1)
    }

    func testResumesPartialDownloadWithRange() async throws {
        let bytes = Self.randomBytes(2 * 1024 * 1024)
        let detail = try insertGame(title: "Bravo", bytes: bytes)
        let file = detail.files[0]
        try FileManager.default.createDirectory(at: cache.directory(for: detail.game.id), withIntermediateDirectories: true)
        try bytes.prefix(1_000_000).write(to: cache.partialURL(gameID: detail.game.id, file: file))
        let updates = ProgressLog()
        try await withClient(app()) { client in
            try await GameDownloader(client: client, cache: self.cache).download(gameID: detail.game.id) { updates.append($0) }
        }
        XCTAssertEqual(rangeRequests.values, ["bytes=1000000-"])
        XCTAssertEqual(updates.values.first?.receivedBytes, 1_000_000)
        XCTAssertEqual(try Data(contentsOf: cache.fileURL(gameID: detail.game.id, file: file)), bytes)
        XCTAssertFalse(FileManager.default.fileExists(atPath: cache.partialURL(gameID: detail.game.id, file: file).path))
    }

    func testRestartsWhenServerIgnoresRange() async throws {
        let bytes = Self.randomBytes(500_000)
        let detail = try insertGame(title: "Charlie", bytes: bytes)
        let file = detail.files[0]
        try FileManager.default.createDirectory(at: cache.directory(for: detail.game.id), withIntermediateDirectories: true)
        try bytes.prefix(1000).write(to: cache.partialURL(gameID: detail.game.id, file: file))
        try await withClient(app(ignoreRange: true)) { client in
            try await GameDownloader(client: client, cache: self.cache).download(gameID: detail.game.id)
        }
        XCTAssertEqual(try Data(contentsOf: cache.fileURL(gameID: detail.game.id, file: file)), bytes)
    }

    func testChecksumMismatchDiscardsFile() async throws {
        let bytes = Self.randomBytes(100_000)
        var corrupted = bytes
        corrupted[0] ^= 0xFF
        let detail = try insertGame(title: "Delta", bytes: bytes, servedBytes: corrupted)
        try await withClient(app()) { client in
            do {
                try await GameDownloader(client: client, cache: self.cache).download(gameID: detail.game.id)
                XCTFail("Expected checksum mismatch")
            } catch let error as DownloadError {
                XCTAssertEqual(error, .checksumMismatch(filename: "Test.sfc"))
            }
        }
        XCTAssertNil(cache.cachedGame(detail.game.id))
        XCTAssertEqual(cache.bytesOnDisk(for: detail.game.id), 0)
    }

    func testCancelKeepsPartialForResume() async throws {
        let bytes = Self.randomBytes(48 * 1024 * 1024)
        let detail = try insertGame(title: "Echo", bytes: bytes)
        try await withClient(app()) { client in
            let downloader = GameDownloader(client: client, cache: self.cache)
            let started = self.expectation(description: "bytes arrived")
            let once = ProgressLog()
            let task = Task {
                try await downloader.download(gameID: detail.game.id) { progress in
                    if progress.receivedBytes > 0, once.values.isEmpty { once.append(progress); started.fulfill() }
                }
            }
            await self.fulfillment(of: [started], timeout: 30)
            task.cancel()
            _ = await task.result
            XCTAssertNil(self.cache.cachedGame(detail.game.id))
            let partial = self.cache.bytesOnDisk(for: detail.game.id)
            XCTAssertGreaterThan(partial, 0)
            try await downloader.download(gameID: detail.game.id)
            XCTAssertEqual(self.rangeRequests.values.count, 1)
        }
        XCTAssertEqual(try Data(contentsOf: cache.fileURL(gameID: detail.game.id, file: detail.files[0])), bytes)
    }

    func testRejectsUnsafeIDsAndKeepsSubdirectories() async throws {
        let cache = GameCache(root: cacheRoot)
        let sha = String(repeating: "a", count: 64)
        let summary = GameSummary(id: "game", title: "T", system: .psx, year: nil, genre: nil, coverPath: nil, totalSize: 1)
        let downloader = GameDownloader(client: APIClient(baseURL: URL(string: "http://localhost:1")!, token: "t"), cache: cache)
        for detail in [
            GameDetail(game: summary, summary: nil, files: [GameFileInfo(id: "../../escape", filename: "a.bin", role: .disc, size: 1, discNumber: 1)]),
            GameDetail(game: GameSummary(id: "../x", title: "T", system: .psx, year: nil, genre: nil, coverPath: nil, totalSize: 1),
                       summary: nil, files: [GameFileInfo(id: sha, filename: "a.bin", role: .disc, size: 1, discNumber: 1)]),
            GameDetail(game: summary, summary: nil, files: [
                GameFileInfo(id: sha, filename: "Track 01.bin", role: .disc, size: 1, discNumber: 1),
                GameFileInfo(id: String(repeating: "b", count: 64), filename: "./Track 01.bin", role: .disc, size: 1, discNumber: 2)]),
            GameDetail(game: summary, summary: nil, files: [
                GameFileInfo(id: sha, filename: "Track.bin", role: .disc, size: 1, discNumber: 1),
                GameFileInfo(id: String(repeating: "b", count: 64), filename: "TRACK.BIN", role: .disc, size: 1, discNumber: 2)]),
            GameDetail(game: summary, summary: nil, files: [
                GameFileInfo(id: sha, filename: "Disc 1", role: .disc, size: 1, discNumber: 1),
                GameFileInfo(id: String(repeating: "b", count: 64), filename: "Disc 1/Track.bin", role: .disc, size: 1, discNumber: 2)]),
            GameDetail(game: summary, summary: nil, files: [GameFileInfo(id: sha, filename: "Manifest.json", role: .rom, size: 1, discNumber: nil)]),
        ] {
            do {
                _ = try await downloader.download(detail)
                XCTFail("expected invalidFile")
            } catch let error as DownloadError {
                guard case .invalidFile = error else { return XCTFail("\(error)") }
            }
        }
        let disc1 = GameFileInfo(id: sha, filename: "Disc 1/Track 01.bin", role: .disc, size: 1, discNumber: 1)
        let disc2 = GameFileInfo(id: String(repeating: "b", count: 64), filename: "Disc 2/Track 01.bin", role: .disc, size: 1, discNumber: 2)
        XCTAssertNotEqual(cache.fileURL(gameID: "game", file: disc1), cache.fileURL(gameID: "game", file: disc2))
        XCTAssertTrue(cache.fileURL(gameID: "game", file: disc1).path.hasPrefix(cache.directory(for: "game").path + "/"))
        XCTAssertEqual(cache.fileURL(gameID: "game", file: GameFileInfo(id: sha, filename: "../../etc/passwd", role: .rom, size: 1, discNumber: nil)).lastPathComponent, "passwd")
        XCTAssertTrue(cache.fileURL(gameID: "game", file: GameFileInfo(id: sha, filename: "../../etc/passwd", role: .rom, size: 1, discNumber: nil))
            .path.hasPrefix(cache.directory(for: "game").path + "/"))
    }

    func testRemoveAndSizeStayInsideCache() throws {
        let victim = cacheRoot.deletingLastPathComponent().appendingPathComponent("victim-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: victim, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: victim) }
        try Data("keep".utf8).write(to: victim.appendingPathComponent("save.srm"))
        try FileManager.default.createDirectory(at: cacheRoot, withIntermediateDirectories: true)
        for id in ["../\(victim.lastPathComponent)", "..", ".", "", "a/../../\(victim.lastPathComponent)"] {
            XCTAssertNil(cache.containedDirectory(for: id), id)
            XCTAssertEqual(cache.bytesOnDisk(for: id), 0, id)
            XCTAssertThrowsError(try cache.remove(id), id)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: victim.appendingPathComponent("save.srm").path))
        XCTAssertEqual(cache.containedDirectory(for: "game")?.lastPathComponent, "game")
        XCTAssertTrue(GameCache.isDirectChild(cacheRoot.appendingPathComponent("game"), of: cacheRoot))
        XCTAssertFalse(GameCache.isDirectChild(cacheRoot.appendingPathComponent("a/../../b"), of: cacheRoot))
    }

    func testDownloadRejectsDetailForAnotherGame() async throws {
        let detail = try insertGame(title: "Decoy", bytes: Self.randomBytes(1000))
        let downloader = GameDownloader(client: APIClient(baseURL: URL(string: "http://localhost:1")!, token: "t"), cache: cache)
        do {
            _ = try await downloader.download(gameID: "../../..")
            XCTFail("expected invalidFile")
        } catch let error as DownloadError {
            guard case .invalidFile = error else { return XCTFail("\(error)") }
        }
        let responder = PathRewritingResponder(inner: buildRouter(store: store).buildResponder(),
                                               from: "/v1/games/requested", to: "/v1/games/\(detail.game.id)")
        try await withClient(Application(responder: responder, configuration: .init())) { client in
            do {
                _ = try await GameDownloader(client: client, cache: self.cache).download(gameID: "requested")
                XCTFail("expected invalidFile")
            } catch let error as DownloadError {
                guard case .invalidFile = error else { return XCTFail("\(error)") }
            }
        }
        XCTAssertNil(cache.cachedGame(detail.game.id))
        XCTAssertNil(cache.cachedGame("requested"))
    }

    func testRedownloadsStaleSameNamedFile() async throws {
        let bytes = Self.randomBytes(40_000)
        let detail = try insertGame(title: "Stale", bytes: bytes)
        let cache = GameCache(root: cacheRoot)
        let stale = cache.fileURL(gameID: detail.game.id, file: detail.files[0])
        try FileManager.default.createDirectory(at: stale.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Self.randomBytes(40_000).write(to: stale)
        try await withClient(app()) { client in
            _ = try await GameDownloader(client: client, cache: cache).download(gameID: detail.game.id)
        }
        XCTAssertEqual(try Data(contentsOf: stale), bytes)
    }

    func testRemoveDownload() async throws {
        let detail = try insertGame(title: "Foxtrot", bytes: Self.randomBytes(10_000))
        try await withClient(app()) { client in
            try await GameDownloader(client: client, cache: self.cache).download(gameID: detail.game.id)
        }
        XCTAssertNotNil(cache.cachedGame(detail.game.id))
        try cache.remove(detail.game.id)
        XCTAssertNil(cache.cachedGame(detail.game.id))
        XCTAssertTrue(cache.cachedGames().isEmpty)
    }

    func testDownloadRequiresToken() async throws {
        let detail = try insertGame(title: "Golf", bytes: Self.randomBytes(1000))
        try await withClient(app()) { client in
            var anonymous = client
            anonymous.token = nil
            do {
                try await GameDownloader(client: anonymous, cache: self.cache).download(detail)
                XCTFail("Expected 401")
            } catch let error as DownloadError {
                XCTAssertEqual(error, .http(status: 401))
            }
        }
    }

    func testPairingLinkRoundTripAndTypedAddress() throws {
        let payload = PairingPayload(serverName: "Chad's Mac mini",
                                     urls: [URL(string: "https://mac-mini.local:8487")!, URL(string: "https://games.supersemu.com:8487")!],
                                     certificateSHA256: "ab12", code: "123456")
        let link = try PairingLinkParser.link(for: payload)
        XCTAssertTrue(link.hasPrefix("supersemu://pair?d="))
        XCTAssertFalse(link.dropFirst("supersemu://pair?d=".count).contains("="), "base64url without padding")
        XCTAssertEqual(PairingLinkParser.payload(fromLink: "  \(link)\n"), payload)
        XCTAssertNil(PairingLinkParser.payload(fromLink: "https://example.com/pair?d=abc"))
        XCTAssertNil(PairingLinkParser.payload(fromLink: "supersemu://pair?d=!!!"))

        XCTAssertEqual(PairingLinkParser.serverURL(fromAddress: "mac-mini.local")?.absoluteString, "https://mac-mini.local:8487")
        XCTAssertEqual(PairingLinkParser.serverURL(fromAddress: "192.168.1.20:9000")?.absoluteString, "https://192.168.1.20:9000")
        XCTAssertEqual(PairingLinkParser.serverURL(fromAddress: "http://localhost:8487")?.absoluteString, "http://localhost:8487")
        XCTAssertEqual(PairingLinkParser.serverURL(fromAddress: "https://games.supersemu.com/")?.absoluteString, "https://games.supersemu.com:8487")
        XCTAssertNil(PairingLinkParser.serverURL(fromAddress: "  "))
        XCTAssertEqual(PairingLinkParser.payload(address: "mac-mini.local", code: "123 456")?.code, "123456")
        XCTAssertNil(PairingLinkParser.payload(address: "mac-mini.local", code: "12345"))
    }

    func testLibraryDecodesWithoutAddedAt() throws {
        let json = #"{"games":[{"id":"a","title":"A","system":"snes","totalSize":1}]}"#
        let library = try SupersEmuJSON.decoder().decode(LibraryResponse.self, from: Data(json.utf8))
        XCTAssertNil(library.games[0].addedAt)
    }

    func testSameSizeCorruptionIsNotPlayable() async throws {
        let detail = try insertGame(title: "Golf", bytes: Self.randomBytes(10_000))
        try await withClient(app()) { client in
            try await GameDownloader(client: client, cache: self.cache).download(gameID: detail.game.id)
        }
        let cached = try XCTUnwrap(cache.cachedGame(detail.game.id))
        let url = try XCTUnwrap(cache.launchFileURL(for: cached))
        var bytes = try Data(contentsOf: url)
        bytes[0] ^= 0xFF
        try bytes.write(to: url)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(5)], ofItemAtPath: url.path)
        XCTAssertNil(cache.cachedGame(detail.game.id), "a same-size modified ROM must fail verification")
    }
}

final class RequestLog: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String] = []
    func append(_ value: String) { lock.withLock { items.append(value) } }
    var values: [String] { lock.withLock { items } }
}

final class ProgressLog: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [DownloadProgress] = []
    func append(_ value: DownloadProgress) { lock.withLock { items.append(value) } }
    var values: [DownloadProgress] { lock.withLock { items } }
}

/// Wraps the real server: records `Range` request headers, or strips them to mimic a server/proxy that ignores Range.
struct RangeObservingResponder<Inner: HTTPResponder>: HTTPResponder where Inner.Context == SERequestContext {
    let inner: Inner
    let log: RequestLog
    let ignoreRange: Bool

    func respond(to request: Request, context: SERequestContext) async throws -> Response {
        guard let range = request.headers[.range] else { return try await inner.respond(to: request, context: context) }
        guard ignoreRange else {
            log.append(range)
            return try await inner.respond(to: request, context: context)
        }
        var head = request.head
        head.headerFields[.range] = nil
        return try await inner.respond(to: Request(head: head, body: request.body), context: context)
    }

}

/// Answers one game's detail request with another game's detail, as a malicious server could.
struct PathRewritingResponder<Inner: HTTPResponder>: HTTPResponder where Inner.Context == SERequestContext {
    let inner: Inner
    let from: String
    let to: String

    func respond(to request: Request, context: SERequestContext) async throws -> Response {
        var head = request.head
        if head.path == from { head.path = to }
        return try await inner.respond(to: Request(head: head, body: request.body), context: context)
    }
}
