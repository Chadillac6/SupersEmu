import Foundation
import GRDB
import Hummingbird
import HummingbirdTesting
import SupersEmuKit
import XCTest
@testable import SupersEmuServerCore

/// Answers requests from a handler and records them (method, URL, headers, body). Nil from the handler is a 404.
final class RequestStub: MetadataFetching, @unchecked Sendable {
    private let lock = NSLock()
    private var log: [URLRequest] = []
    private let handler: @Sendable (URLRequest) throws -> Data?

    init(_ handler: @escaping @Sendable (URLRequest) throws -> Data?) { self.handler = handler }

    var requests: [URLRequest] { lock.withLock { log } }

    func get(_ url: URL) async throws -> Data? { try await send(URLRequest(url: url)) }

    func send(_ request: URLRequest) async throws -> Data? {
        lock.withLock { log.append(request) }
        return try handler(request)
    }
}

final class FailureSwitch: @unchecked Sendable {
    var failing = true
}

final class MetadataProviderTests: XCTestCase {
    var store: ServerStore!
    var adminToken: String!
    var sources: URL!

    override func setUp() async throws {
        store = try ServerStore.inMemory()
        let admin = try store.createUser(displayName: "Chad", role: .admin)
        adminToken = try store.createDeviceToken(userID: admin.id, deviceName: "Chad's Mac").token
        sources = FileManager.default.temporaryDirectory.appendingPathComponent("se-prov-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: sources, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: sources)
        try? FileManager.default.removeItem(at: store.paths.root)
    }

    func importROM(_ name: String, seed: UInt8 = 7) async throws -> String {
        let url = sources.appendingPathComponent(name)
        try ROMFixtures.snes(seed: seed).write(to: url)
        return try await LibraryImporter(store: store).importPaths([url.path], auth: nil).imported[0].id
    }

    func json(_ object: Any) -> Data { try! JSONSerialization.data(withJSONObject: object) }

    func detail(_ id: String) async throws -> (GameDetail, String) {
        var result: (GameDetail, String)?
        try await buildApplication(store: store, configuration: .init()).test(.router) { client in
            try await client.execute(uri: "/v1/games/\(id)", method: .get, headers: [.authorization: "Bearer \(self.adminToken!)"]) {
                let body = Data(buffer: $0.body)
                result = (try SupersEmuJSON.decoder().decode(GameDetail.self, from: body), String(decoding: body, as: UTF8.self))
            }
        }
        return try XCTUnwrap(result)
    }

    func service(_ fetcher: RequestStub, _ providers: (RateLimitedFetcher) -> [any MetadataProvider]) -> MetadataService {
        let http = RateLimitedFetcher(fetcher, minimumInterval: .zero)
        return MetadataService(store: store, http: http, providers: providers(http))
    }

    // MARK: Wikipedia

    static let receptionExtract = """
        Super Metroid is a 1994 action-adventure game.

        == Gameplay ==
        Samus explores Zebes.

        == Reception ==
        Super Metroid received critical acclaim. Reviewers praised its atmosphere and music. It was named one of the \
        best games of all time by Electronic Gaming Monthly. Its pacing was later studied by speedrunners.

        === Accolades ===
        It won awards.

        == Legacy ==
        Later games followed.
        """

    func testWikipediaIntroAndReceptionWithAttribution() async throws {
        let id = try await importROM("Super Metroid (Japan, USA).sfc")
        let search = WikipediaMetadataProvider.searchURL(title: "Super Metroid", system: .snes)
        let summary = WikipediaMetadataProvider.summaryURL("Super Metroid")
        let extract = WikipediaMetadataProvider.extractURL("Super Metroid")
        let responses: [URL: Data] = [
            search: json(["query": ["search": [["title": "Metroid"], ["title": "Super Metroid (soundtrack)"], ["title": "Super Metroid"]]]]),
            WikipediaMetadataProvider.summaryURL("Super Metroid (soundtrack)"):
                json(["type": "standard", "title": "Super Metroid (soundtrack)", "description": "Album", "extract": "An album."]),
            summary: json(["type": "standard", "title": "Super Metroid", "description": "1994 video game",
                           "extract": "Super Metroid is a 1994 action-adventure game developed by Nintendo. It is the third Metroid game.",
                           "content_urls": ["desktop": ["page": "https://en.wikipedia.org/wiki/Super_Metroid"]]]),
            extract: json(["query": ["pages": [["extract": Self.receptionExtract]]]]),
        ]
        let fetcher = RequestStub { responses[$0.url!] }

        let changed = await service(fetcher) { [WikipediaMetadataProvider(http: $0)] }.enrichPending()
        XCTAssertEqual(changed, 1)
        XCTAssertEqual(fetcher.requests.map(\.url), [search, summary, extract], "the album page isn't fetched")

        let (game, _) = try await detail(id)
        XCTAssertEqual(game.summary, "Super Metroid is a 1994 action-adventure game developed by Nintendo. It is the third Metroid game.")
        XCTAssertEqual(game.summarySource, MetadataSource(provider: "wikipedia", name: "Wikipedia",
                                                          url: "https://en.wikipedia.org/wiki/Super_Metroid"))
        XCTAssertEqual(game.reception, ReceptionSummary(
            text: "Super Metroid received critical acclaim. Reviewers praised its atmosphere and music. It was named one of the best games of all time by Electronic Gaming Monthly.",
            source: "Wikipedia", url: "https://en.wikipedia.org/wiki/Super_Metroid#Reception"))
        XCTAssertEqual(game.game.year, 1994)
        XCTAssertNil(game.game.criticScore)
        XCTAssertNil(game.reviewLink)
    }

    func testWikipediaSkipsNonGamePagesAndHandlesMissingReception() async throws {
        XCTAssertEqual(WikipediaMetadataProvider.candidates(
            ["Sonic the Hedgehog (character)", "Sonic the Hedgehog", "Sonic the Hedgehog (1991 video game)", "Sonic Mania"],
            title: "Sonic the Hedgehog"),
            ["Sonic the Hedgehog (1991 video game)", "Sonic the Hedgehog", "Sonic the Hedgehog (character)"])
        XCTAssertNil(WikipediaMetadataProvider.reception(in: "Intro.\n\n== Plot ==\nStuff."))
        XCTAssertEqual(WikipediaMetadataProvider.year("1991 platform video game"), 1991)
        XCTAssertNil(WikipediaMetadataProvider.year("Video game series"))
        XCTAssertEqual(WikipediaMetadataProvider.reception(in: "== Critical reception ==\nGood. Very good.\n== Sales =="), "Good. Very good.")

        _ = try await importROM("Homebrew Demo.sfc")
        let fetcher = RequestStub { request in
            request.url!.absoluteString.contains("list=search")
                ? self.json(["query": ["search": [["title": "Demoscene"]]]]) : nil
        }
        let changed = await service(fetcher) { [WikipediaMetadataProvider(http: $0)] }.enrichPending()
        XCTAssertEqual(changed, 1)
        XCTAssertEqual(fetcher.requests.count, 1)
        let status = try await store.db.read { try String.fetchOne($0, sql: "SELECT match_status FROM metadata_jobs WHERE provider = 'wikipedia'") }
        XCTAssertEqual(status, "unmatched")
    }

    // MARK: IGDB

    func testUnmatchedGameIsSearchedAgainWhenABetterTitleAppears() async throws {
        let id = try await importROM("SM.sfc")
        let fetcher = RequestStub { request in
            let url = request.url!.absoluteString
            guard url.contains("list=search") else { return nil }
            return self.json(["query": ["search": url.contains("Super%20Metroid") ? [["title": "Super Metroid"]] : []]])
        }
        let metadata = service(fetcher) { [WikipediaMetadataProvider(http: $0)] }
        _ = await metadata.enrichPending()
        _ = await metadata.enrichPending()
        XCTAssertEqual(fetcher.requests.count, 1, "an unmatched title isn't searched again")

        try await store.db.write { db in
            try MetadataRecord(provider: "libretro", title: "Super Metroid").save(gameID: id, db: db)
        }
        _ = await metadata.enrichPending()
        XCTAssertEqual(fetcher.requests.count, 3, "searched again with the canonical title, then its summary")
        XCTAssertTrue(fetcher.requests[1].url!.absoluteString.contains("Super%20Metroid"))
        _ = await metadata.enrichPending()
        XCTAssertEqual(fetcher.requests.count, 3)
    }

    func testWikipediaReceptionFailureKeepsIntroAndRetries() async throws {
        _ = try await importROM("Super Metroid (Japan, USA).sfc")
        let extract = WikipediaMetadataProvider.extractURL("Super Metroid")
        let failure = FailureSwitch()
        let fetcher = RequestStub { request in
            let url = request.url!
            if url == extract {
                if failure.failing { throw URLError(.timedOut) }
                return self.json(["query": ["pages": [["extract": Self.receptionExtract]]]])
            }
            if url.absoluteString.contains("list=search") { return self.json(["query": ["search": [["title": "Super Metroid"]]]]) }
            return self.json(["type": "standard", "title": "Super Metroid", "description": "1994 video game", "extract": "Super Metroid is a 1994 game."])
        }
        let metadata = service(fetcher) { [WikipediaMetadataProvider(http: $0)] }
        let sql = "SELECT m.description, m.reception, j.match_status FROM game_metadata m JOIN metadata_jobs j "
            + "ON j.game_id = m.game_id AND j.provider = m.provider WHERE m.provider = 'wikipedia'"

        _ = await metadata.enrichPending()
        var saved = try await store.db.read { try Row.fetchOne($0, sql: sql) }
        XCTAssertEqual(saved?["description"], "Super Metroid is a 1994 game.")
        XCTAssertNil(saved?["reception"] as String?)
        XCTAssertEqual(saved?["match_status"], "partial")

        failure.failing = false
        _ = await metadata.enrichPending()
        saved = try await store.db.read { try Row.fetchOne($0, sql: sql) }
        XCTAssertNotNil(saved?["reception"] as String?)
        XCTAssertEqual(saved?["match_status"], "matched")
    }

    func testIGDBDisabledWithoutCredentials() async throws {
        let id = try await importROM("Super Metroid.sfc")
        let fetcher = RequestStub { _ in XCTFail("no request without credentials"); return nil }
        let provider = IGDBMetadataProvider(credentials: { nil }, http: RateLimitedFetcher(fetcher, minimumInterval: .zero))
        XCTAssertFalse(provider.isEnabled)
        let changed = await service(fetcher) { _ in [provider] }.enrichPending()
        XCTAssertEqual(changed, 0)
        XCTAssertTrue(fetcher.requests.isEmpty)
        let (game, _) = try await detail(id)
        XCTAssertNil(game.game.criticScore)
        XCTAssertNil(game.reviewLink)
    }

    func testIGDBScoreAndIGNLinkWithStubbedTwitchToken() async throws {
        let metroid = try await importROM("Super Metroid.sfc", seed: 1)
        let zelda = try await importROM("Legend of Zelda, The - A Link to the Past (USA).sfc", seed: 2)
        let fetcher = RequestStub { request in
            if request.url == IGDBMetadataProvider.tokenURL {
                return self.json(["access_token": "tok-123", "expires_in": 3600, "token_type": "bearer"])
            }
            guard request.url == IGDBMetadataProvider.gamesURL else { return nil }
            let body = String(decoding: request.httpBody ?? Data(), as: UTF8.self)
            if body.contains("Super Metroid") {
                return self.json([["id": 1103, "name": "Super Metroid", "url": "https://www.igdb.com/games/super-metroid",
                                   "aggregated_rating": 95.6, "total_rating": 93.2,
                                   "websites": [["url": "https://en.wikipedia.org/wiki/Super_Metroid"],
                                                ["url": "https://www.ign.com/games/super-metroid"]]]])
            }
            return self.json([["id": 1026, "name": "The Legend of Zelda: A Link to the Past", "total_rating": 91.4]])
        }
        let provider = IGDBMetadataProvider(credentials: { ("client-abc", "secret-xyz") },
                                            http: RateLimitedFetcher(fetcher, minimumInterval: .zero))
        let changed = await service(fetcher) { _ in [provider] }.enrichPending()
        XCTAssertEqual(changed, 2)

        let tokenRequests = fetcher.requests.filter { $0.url == IGDBMetadataProvider.tokenURL }
        XCTAssertEqual(tokenRequests.count, 1, "the token is reused")
        XCTAssertEqual(tokenRequests.first?.httpMethod, "POST")
        XCTAssertTrue(String(decoding: tokenRequests.first?.httpBody ?? Data(), as: UTF8.self).contains("client_secret=secret-xyz"))
        let queries = fetcher.requests.filter { $0.url == IGDBMetadataProvider.gamesURL }
        XCTAssertEqual(queries.count, 2)
        for query in queries {
            XCTAssertEqual(query.value(forHTTPHeaderField: "Client-ID"), "client-abc")
            XCTAssertEqual(query.value(forHTTPHeaderField: "Authorization"), "Bearer tok-123")
            XCTAssertTrue(String(decoding: query.httpBody ?? Data(), as: UTF8.self).contains("where platforms = (19)"))
        }
        XCTAssertFalse(fetcher.requests.contains { $0.url!.absoluteString.contains("secret-xyz") }, "the secret never goes in a URL")

        let (sm, smJSON) = try await detail(metroid)
        XCTAssertEqual(sm.game.criticScore, CriticScore(score: 96, source: "Critics via IGDB", url: "https://www.igdb.com/games/super-metroid"))
        XCTAssertEqual(sm.reviewLink, ReviewLink(name: "IGN", url: "https://www.ign.com/games/super-metroid"))
        XCTAssertFalse(smJSON.contains("secret-xyz") || smJSON.contains("tok-123") || smJSON.contains("client-abc"))
        let (lttp, _) = try await detail(zelda)
        XCTAssertEqual(lttp.game.criticScore?.score, 91)
        XCTAssertEqual(lttp.game.criticScore?.source, "IGDB")
        XCTAssertEqual(lttp.reviewLink?.url, "https://www.ign.com/search?q=The%20Legend%20of%20Zelda%20-%20A%20Link%20to%20the%20Past")
    }

    // MARK: SteamGridDB

    func testSteamGridDBHeroAndLogoServedThroughArtworkEndpoints() async throws {
        let id = try await importROM("Super Metroid.sfc")
        let hero = URL(string: "https://cdn2.steamgriddb.com/hero/abc.png")!
        let logo = URL(string: "https://cdn2.steamgriddb.com/logo/def.png")!
        let responses: [URL: Data] = [
            SteamGridDBMetadataProvider.searchURL("Super Metroid"):
                json(["success": true, "data": [["id": 9, "name": "Metroid"], ["id": 5250, "name": "Super Metroid"]]]),
            SteamGridDBMetadataProvider.imagesURL("heroes", gameID: 5250, mimes: "image/png,image/jpeg"):
                json(["success": true, "data": [["id": 9, "url": "https://10.0.0.5/internal.png"], ["id": 1, "url": hero.absoluteString]]]),
            SteamGridDBMetadataProvider.imagesURL("logos", gameID: 5250, mimes: "image/png"):
                json(["success": true, "data": [["id": 2, "url": logo.absoluteString]]]),
            hero: DatFixtures.png,
            logo: DatFixtures.png + Data([2]),
        ]
        let fetcher = RequestStub { responses[$0.url!] }
        let changed = await service(fetcher) { [SteamGridDBMetadataProvider(key: { "sgdb-key" }, http: $0)] }.enrichPending()
        XCTAssertEqual(changed, 1)
        for request in fetcher.requests {
            let isAPI = request.url!.host == "www.steamgriddb.com"
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), isAPI ? "Bearer sgdb-key" : nil, "\(request.url!)")
        }

        let (game, body) = try await detail(id)
        XCTAssertEqual(game.game.backdropPath, "/v1/games/\(id)/artwork/backdrop")
        XCTAssertEqual(game.game.heroPath, "/v1/games/\(id)/artwork/backdrop")
        XCTAssertEqual(game.game.logoPath, "/v1/games/\(id)/artwork/logo")
        XCTAssertFalse(body.contains("sgdb-key"))
        try await buildApplication(store: store, configuration: .init()).test(.router) { client in
            try await client.execute(uri: "/v1/games/\(id)/artwork/backdrop", method: .get,
                                     headers: [.authorization: "Bearer \(self.adminToken!)"]) {
                XCTAssertEqual($0.status, .ok)
                XCTAssertEqual(Data(buffer: $0.body), DatFixtures.png)
            }
            try await client.execute(uri: "/v1/games/\(id)/artwork/logo", method: .get, headers: [:]) {
                XCTAssertEqual($0.status, .unauthorized)
            }
        }
    }

    func testKeylessStandardServiceFallsBackToLibretroArt() async throws {
        let id = try await importROM("Super Metroid.sfc")
        let fetcher = RequestStub { request in
            XCTAssertNotEqual(request.url?.host, "api.igdb.com")
            XCTAssertNotEqual(request.url?.host, "www.steamgriddb.com")
            XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
            return nil
        }
        _ = await MetadataService.standard(store: store, fetcher: fetcher, environment: [:], minimumInterval: .zero).enrichPending()
        XCTAssertFalse(fetcher.requests.isEmpty)
        let providers = try await store.db.read { try String.fetchAll($0, sql: "SELECT DISTINCT provider FROM metadata_jobs ORDER BY provider") }
        XCTAssertFalse(providers.contains("igdb") || providers.contains("steamgriddb"))

        try await store.db.write { db in
            try db.execute(sql: """
                INSERT INTO game_artwork (game_id, provider, kind, position, path, updated_at)
                VALUES (?, 'libretro', 'screenshot', 0, 'artwork/x/snap.png', ?)
                """, arguments: [id, Date()])
        }
        let (game, _) = try await detail(id)
        XCTAssertNil(game.game.backdropPath)
        XCTAssertEqual(game.game.heroPath, "/v1/games/\(id)/artwork/screenshot/0", "libretro snap stands in for the hero")
    }

    // MARK: Keys

    func testKeysFileIsPrivateAndEnvironmentWins() throws {
        let paths = store.paths
        XCTAssertNil(MetadataKeys.load(paths: paths, environment: [:]).igdb)
        try MetadataKeys.set(.steamGridDB, to: "file-key", paths: paths)
        try MetadataKeys.set(.igdbClientID, to: "id", paths: paths)
        let attributes = try FileManager.default.attributesOfItem(atPath: MetadataKeys.url(paths).path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        XCTAssertEqual(MetadataKeys.load(paths: paths, environment: [:])[.steamGridDB], "file-key")
        XCTAssertNil(MetadataKeys.load(paths: paths, environment: [:]).igdb, "needs both halves")
        let env = ["SUPERSEMU_STEAMGRIDDB_KEY": "env-key", "SUPERSEMU_IGDB_CLIENT_SECRET": "s"]
        XCTAssertEqual(MetadataKeys.load(paths: paths, environment: env)[.steamGridDB], "env-key")
        XCTAssertEqual(MetadataKeys.load(paths: paths, environment: env).igdb?.secret, "s")
        try MetadataKeys.set(.steamGridDB, to: nil, paths: paths)
        XCTAssertNil(MetadataKeys.load(paths: paths, environment: [:])[.steamGridDB])
        XCTAssertFalse(BackupManager.items(paths: paths, includeROMs: false).contains("metadata.keys"), "keys stay out of backups")
    }

    // MARK: Migration

    func testReviewsMigrationKeepsExistingMetadata() throws {
        let queue = try DatabaseQueue()
        let migrator = ServerMigrations.migrator
        try migrator.migrate(queue, upTo: "v2_saves")
        try queue.write { db in
            XCTAssertFalse(try db.columns(in: "game_metadata").contains { $0.name == "reception" })
            try db.execute(sql: "INSERT INTO games (id, title, system, created_at) VALUES ('g1', 'Super Metroid', 'snes', ?)", arguments: [Date()])
            try db.execute(sql: """
                INSERT INTO game_metadata (game_id, provider, title, critic_score, critic_source, updated_at)
                VALUES ('g1', 'libretro', 'Super Metroid', 90, 'Old', ?)
                """, arguments: [Date()])
        }
        try migrator.migrate(queue)
        try queue.write { db in
            let old = try XCTUnwrap(try Row.fetchOne(db, sql: "SELECT * FROM game_metadata").map(MetadataRecord.init(row:)))
            XCTAssertEqual(old.title, "Super Metroid")
            XCTAssertEqual(old.criticScore?.score, 90)
            XCTAssertNil(old.reception)
            XCTAssertNil(old.reviewLink)
            XCTAssertNil(old.artworkURLs)

            let record = MetadataRecord(provider: "steamgriddb", providerRef: "5250",
                                        reception: ReceptionSummary(text: "Acclaimed.", source: "Wikipedia", url: "https://w/x"),
                                        reviewLink: ReviewLink(name: "IGN", url: "https://www.ign.com/x"),
                                        artworkURLs: [.backdrop: URL(string: "https://cdn/h.png")!])
            try record.save(gameID: "g1", db: db)
            let loaded = try Row.fetchOne(db, sql: "SELECT * FROM game_metadata WHERE provider = 'steamgriddb'").map(MetadataRecord.init(row:))
            XCTAssertEqual(loaded, record)
        }
    }
}
