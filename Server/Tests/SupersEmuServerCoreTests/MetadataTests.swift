import CryptoKit
import Foundation
import GRDB
import Hummingbird
import HummingbirdTesting
import SupersEmuKit
import XCTest
@testable import SupersEmuServerCore

/// Serves canned responses by URL; anything else is a 404. `offline` makes every request a network error.
final class StubFetcher: MetadataFetching, @unchecked Sendable {
    private let lock = NSLock()
    private var responses: [URL: Data] = [:]
    private var log: [URL] = []
    var offline: Bool { get { lock.withLock { _offline } } set { lock.withLock { _offline = newValue } } }
    private var _offline = false

    func set(_ url: URL, _ data: Data) { lock.withLock { responses[url] = data } }
    func remove(_ url: URL) { lock.withLock { responses[url] = nil } }
    var requests: [URL] { lock.withLock { log } }

    func get(_ url: URL) async throws -> Data? {
        try lock.withLock {
            log.append(url)
            if _offline { throw URLError(.notConnectedToInternet) }
            return responses[url]
        }
    }
}

enum DatFixtures {
    static func entry(_ name: String, region: String? = "USA", rom data: Data, romName: String, serial: String? = nil) -> String {
        let h = ROMHasher.hash(data)
        return """
            game (
            \tname "\(name)"
            \(region.map { "\tregion \"\($0)\"" } ?? "")
            \(serial.map { "\tserial \"\($0)\"" } ?? "")
            \trom ( name "\(romName)" size \(data.count) crc \(h.crc) md5 \(h.md5.lowercased()) sha1 \(h.sha1) )
            )

            """
    }

    static func supplement(_ field: String, _ value: String, rom data: Data) -> String {
        "game (\n\tcomment \"x\"\n\t\(field) \"\(value)\"\n\trom ( crc \(ROMHasher.hash(data).crc) )\n)\n"
    }

    static let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 9, 9, 9])
}

private struct PartialArtworkProvider: MetadataProvider {
    let artworkURL: URL
    var id: String { "test-artwork" }
    var version: String { "stable" }

    func lookup(_ game: MetadataLookup) async throws -> MetadataLookupResult {
        .partial(MetadataRecord(provider: id, providerRef: "same-game", title: "Same Game"))
    }

    func artwork(for record: MetadataRecord, system: SystemID) -> [ArtworkCandidate] {
        [ArtworkCandidate(kind: .cover, position: 0, urls: [artworkURL])]
    }
}

final class MetadataTests: XCTestCase {
    var store: ServerStore!
    var adminToken: String!
    var sources: URL!
    var fetcher: StubFetcher!

    override func setUp() async throws {
        store = try ServerStore.inMemory()
        let admin = try store.createUser(displayName: "Chad", role: .admin)
        adminToken = try store.createDeviceToken(userID: admin.id, deviceName: "Chad's Mac").token
        sources = FileManager.default.temporaryDirectory.appendingPathComponent("se-meta-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: sources, withIntermediateDirectories: true)
        fetcher = StubFetcher()
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: sources)
        try? FileManager.default.removeItem(at: store.paths.root)
    }

    func write(_ data: Data, _ name: String) throws -> URL {
        let url = sources.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url)
        return url
    }

    func app() -> some ApplicationProtocol { buildApplication(store: store, configuration: .init()) }
    func auth(_ token: String? = nil) -> HTTPFields { [.authorization: "Bearer \(token ?? adminToken!)"] }
    func decode<T: Decodable>(_ type: T.Type, _ response: TestResponse) throws -> T {
        try SupersEmuJSON.decoder().decode(T.self, from: Data(buffer: response.body))
    }

    /// A catalog pinned to the given synthetic DATs (system -> kind -> text), served by the stub fetcher.
    func catalog(_ dats: [SystemID: (name: String, source: String, files: [String: String])], commit: String = "test-commit",
                 thumbnails: String = "thumbs1") -> MetadataCatalog {
        var systems: [SystemID: MetadataCatalog.SystemSet] = [:]
        for (system, dat) in dats {
            systems[system] = .init(name: dat.name, source: dat.source, files: dat.files.mapValues { SHA256.hash(data: Data($0.utf8)).hex },
                                    thumbnailsCommit: thumbnails)
        }
        let catalog = MetadataCatalog(databaseCommit: commit, systems: systems)
        for (system, dat) in dats {
            for (kind, text) in dat.files { fetcher.set(catalog.datURL(systems[system]!, kind: kind), Data(text.utf8)) }
        }
        return catalog
    }

    func service(_ catalog: MetadataCatalog) -> MetadataService {
        MetadataService(store: store, catalog: catalog, fetcher: fetcher, minimumInterval: .zero)
    }

    func importROM(_ data: Data, _ name: String) async throws -> String {
        try await LibraryImporter(store: store).importPaths([try write(data, name).path], auth: nil).imported[0].id
    }

    // MARK: Parsing

    func testDatParsingAndHashMatching() {
        let rom = ROMFixtures.snes(seed: 40), other = ROMFixtures.snes(seed: 41)
        let index = DatIndex(dat: """
            clrmamepro (
            \tname "Nintendo - Super Nintendo Entertainment System"
            )

            \(DatFixtures.entry("Legend of Zelda, The - A Link to the Past (USA)", rom: rom, romName: "Zelda.sfc"))
            """)
        let hashes = ROMHasher.hash(rom)
        XCTAssertEqual(index.match(hashes)?.name, "Legend of Zelda, The - A Link to the Past (USA)")
        XCTAssertEqual(index.match(ROMHashes(crc: "0", md5: hashes.md5, sha1: "0", size: 0))?.region, "USA", "MD5 alone matches")
        XCTAssertNotNil(index.match(ROMHashes(crc: hashes.crc, md5: "0", sha1: "0", size: hashes.size)), "CRC + size matches")
        XCTAssertNil(index.match(ROMHashes(crc: hashes.crc, md5: "0", sha1: "0", size: hashes.size + 1)), "CRC needs the size too")
        XCTAssertNil(index.match(ROMHasher.hash(other)))
    }

    func testSerialKeyedSupplement() {
        let track = DiscFixtures.psxTrack(seed: 30)
        var index = DatIndex(dat: DatFixtures.entry("Vagrant Story (USA)", rom: track, romName: "Vagrant Story (USA).bin", serial: "SLUS-01040"))
        index.addSupplement(field: "developer", dat: """
            game (
            \tserial "SLUS-01040"
            \tdeveloper "Square"
            \trom ( serial "SLUS-01040" name "Vagrant Story (USA).cue" )
            )
            """)
        let entry = try! XCTUnwrap(index.match(ROMHasher.hash(track)))
        XCTAssertEqual(index.supplement("developer", crc: entry.crc, serial: entry.serial), "Square")
    }

    func testCanonicalNames() {
        XCTAssertEqual(CanonicalName.title("Legend of Zelda, The - A Link to the Past (USA) (Rev 1)"), "The Legend of Zelda - A Link to the Past")
        XCTAssertEqual(CanonicalName.title("Final Fantasy VII (USA) (Disc 1)"), "Final Fantasy VII")
        XCTAssertEqual(CanonicalName.title("Pokemon - Red Version (USA, Europe) [b]"), "Pokemon - Red Version")
        XCTAssertEqual(CanonicalName.region("Pokemon - Red Version (USA, Europe)"), "USA, Europe")
        XCTAssertEqual(CanonicalName.thumbnailName("Ys I & II: Ancient/Ys?"), "Ys I _ II_ Ancient_Ys_")
        XCTAssertEqual(CanonicalName.withoutDiscNumber("Final Fantasy VII (USA) (Disc 2)"), "Final Fantasy VII (USA)")
        XCTAssertNil(CanonicalName.withoutDiscNumber("Chrono Trigger (USA)"))
    }

    func testHashVariantsForHeadersAndByteOrder() throws {
        let rom = ROMFixtures.snes(seed: 42)
        let headered = try write(Data(count: 512) + rom, "Headered.smc")
        XCTAssertTrue(try ROMHasher.variants(of: headered, system: .snes).contains(ROMHasher.hash(rom)))

        var z64 = Data([0x80, 0x37, 0x12, 0x40]) + Data((0..<1020).map { UInt8($0 & 0xFF) })
        let v64 = ROMHasher.swap(z64, groupSize: 2)
        XCTAssertTrue(try ROMHasher.variants(of: try write(v64, "Game.v64"), system: .n64).contains(ROMHasher.hash(z64)))
        let n64 = ROMHasher.swap(z64, groupSize: 4)
        XCTAssertTrue(try ROMHasher.variants(of: try write(n64, "Game.n64"), system: .n64).contains(ROMHasher.hash(z64)))
        z64[0] = 0x80

        let genesis = ROMFixtures.genesis(seed: 3)
        let smd = try write(ROMFixtures.smd(from: genesis), "Sonic.smd")
        XCTAssertTrue(try ROMHasher.variants(of: smd, system: .genesis).contains(ROMHasher.hash(genesis)))
        XCTAssertTrue(try ROMHasher.variants(of: smd, system: .sega32x).contains(ROMHasher.hash(genesis)), "32X .smd dumps too")
    }

    // MARK: Service

    func testMatchesImportedGameAndServesArtwork() async throws {
        let rom = ROMFixtures.snes(seed: 43)
        let name = "Super Metroid (Japan, USA) (En,Ja)"
        let catalog = catalog([.snes: ("Nintendo - Super Nintendo Entertainment System", "no-intro", [
            "source": DatFixtures.entry(name, region: "Japan, USA", rom: rom, romName: "\(name).sfc"),
            "genre": DatFixtures.supplement("genre", "Action", rom: rom),
            "releaseyear": DatFixtures.supplement("releaseyear", "1994", rom: rom),
            "publisher": DatFixtures.supplement("publisher", "Nintendo", rom: rom),
            "developer": DatFixtures.supplement("developer", "Nintendo R&D1", rom: rom),
            "maxusers": DatFixtures.supplement("users", "1", rom: rom),
        ])])
        let set = catalog.systems[.snes]!
        fetcher.set(catalog.thumbnailURL(set, kind: "Named_Boxarts", name: name), DatFixtures.png)
        fetcher.set(catalog.thumbnailURL(set, kind: "Named_Snaps", name: name), DatFixtures.png + Data([1]))
        let id = try await importROM(rom, "sm.sfc")

        let changed = await service(catalog).enrichPending()
        XCTAssertEqual(changed, 1)
        XCTAssertEqual(fetcher.requests.filter { $0.path.contains("Named_") }.count, 3, "box art, title (404) and snap")

        try await app().test(.router) { client in
            try await client.execute(uri: "/v1/library", method: .get, headers: self.auth()) {
                let game = try XCTUnwrap(try self.decode(LibraryResponse.self, $0).games.first)
                XCTAssertEqual(game.title, "Super Metroid")
                XCTAssertEqual(game.region, "Japan, USA")
                XCTAssertEqual(game.year, 1994)
                XCTAssertEqual(game.publisher, "Nintendo")
                XCTAssertEqual(game.genre, "Action")
                XCTAssertEqual(game.genres, ["Action"])
                XCTAssertEqual(game.players, 1)
                XCTAssertEqual(game.coverPath, "/v1/games/\(id)/artwork/cover")
                XCTAssertNil(game.backdropPath)
            }
            try await client.execute(uri: "/v1/games/\(id)", method: .get, headers: self.auth()) {
                let detail = try self.decode(GameDetail.self, $0)
                XCTAssertEqual(detail.developer, "Nintendo R&D1")
                XCTAssertEqual(detail.screenshotPaths, ["/v1/games/\(id)/artwork/screenshot/0"])
                XCTAssertNil(detail.titleScreenPath)
                XCTAssertEqual(detail.sources?.first?.provider, "libretro")
            }
            try await client.execute(uri: "/v1/games/\(id)/artwork/cover", method: .get, headers: self.auth()) {
                XCTAssertEqual($0.status, .ok)
                XCTAssertEqual(Data(buffer: $0.body), DatFixtures.png)
            }
            try await client.execute(uri: "/v1/games/\(id)/artwork/screenshot/0", method: .get, headers: self.auth()) {
                XCTAssertEqual($0.status, .ok)
            }
            for missing in ["title", "screenshot/1", "backdrop", "poster", "screenshot/-1"] {
                try await client.execute(uri: "/v1/games/\(id)/artwork/\(missing)", method: .get, headers: self.auth()) {
                    XCTAssertEqual($0.status, .notFound, missing)
                }
            }
        }

        // Done games aren't re-fetched; the DAT is cached on disk.
        let before = fetcher.requests.count
let pass1 = await service(catalog).enrichPending()
        XCTAssertEqual(pass1, 0)
        XCTAssertEqual(fetcher.requests.count, before)
    }

    func testRevisionArtworkFallbackRetriesPreviouslyCompletedJobs() async throws {
        let rom = ROMFixtures.snes(seed: 44)
        let name = "Mega Man X (USA) (Rev 1)"
        let catalog = catalog([.snes: ("Nintendo - Super Nintendo Entertainment System", "no-intro", [
            "source": DatFixtures.entry(name, rom: rom, romName: "Mega Man X.sfc"),
        ])])
        let id = try await importROM(rom, "Mega Man X.sfc")
        _ = await service(catalog).enrichPending()
        // A previous server marked missing artwork done using only the pinned thumbnail commit.
        try await store.db.write { db in
            try db.execute(sql: "UPDATE metadata_jobs SET artwork_version = ? WHERE game_id = ?",
                           arguments: ["thumbs1", id])
        }
        let url = catalog.thumbnailURL(catalog.systems[.snes]!, kind: "Named_Boxarts", name: "Mega Man X (USA)")
        fetcher.set(url, DatFixtures.png)
        _ = await service(catalog).enrichPending()
        let summary = try LibraryQueries.visibleGames(for: try XCTUnwrap(store.authenticate(token: adminToken)), store: store)[0]
        XCTAssertNotNil(summary.coverPath)
        let before = fetcher.requests.count
        _ = await service(catalog).enrichPending()
        XCTAssertEqual(fetcher.requests.count, before, "completed jobs must not repeatedly download artwork")
    }

    func testThumbnailCandidatesPreserveRegionAndPreferExactRevision() {
        XCTAssertEqual(CanonicalName.thumbnailCandidates("Game (USA) (En,Fr) (Rev 2) (Disc 1)"), [
            "Game (USA) (En,Fr) (Rev 2) (Disc 1)", "Game (USA) (En,Fr) (Rev 2)",
            "Game (USA) (En,Fr) (Disc 1)", "Game (USA) (En,Fr)",
        ])
        XCTAssertEqual(CanonicalName.thumbnailCandidates("Game (Japan)"), ["Game (Japan)"])
    }

    func testOfflineKeepsImportedTitleAndRetries() async throws {
        let rom = ROMFixtures.snes(seed: 44)
        let catalog = catalog([.snes: ("Nintendo - Super Nintendo Entertainment System", "no-intro", [
            "source": DatFixtures.entry("Chrono Trigger (USA)", rom: rom, romName: "Chrono Trigger (USA).sfc"),
        ])])
        let id = try await importROM(rom, "Chrono Trigger (USA).sfc")
        fetcher.offline = true
        let service = service(catalog)
let pass2 = await service.enrichPending()
        XCTAssertEqual(pass2, 0)
        var summary = try LibraryQueries.visibleGames(for: try XCTUnwrap(store.authenticate(token: adminToken)), store: store)[0]
        XCTAssertEqual(summary.title, "Chrono Trigger")
        XCTAssertNil(summary.coverPath, "client shows the generated tile")
        XCTAssertNil(summary.region)

        fetcher.offline = false
let pass3 = await service.enrichPending()
        XCTAssertEqual(pass3, 1)
        summary = try LibraryQueries.visibleGames(for: try XCTUnwrap(store.authenticate(token: adminToken)), store: store)[0]
        XCTAssertEqual(summary.id, id)
        XCTAssertEqual(summary.region, "USA")
        XCTAssertNil(summary.coverPath, "no box art upstream")
    }

    func testArtworkNetworkFailureIsRetried() async throws {
        let rom = ROMFixtures.gba(seed: 7)
        let name = "Advance Wars (USA)"
        let catalog = catalog([.gba: ("Nintendo - Game Boy Advance", "no-intro", [
            "source": DatFixtures.entry(name, rom: rom, romName: "\(name).gba"),
        ])])
        let id = try await importROM(rom, "aw.gba")
        let service = service(catalog)
        _ = try await LibretroMetadataProvider(catalog: catalog, cacheRoot: store.paths.metadata,
                                               http: RateLimitedFetcher(fetcher, minimumInterval: .zero))
            .dat(catalog.systems[.gba]!, kind: "source")
        fetcher.offline = true
let pass4 = await service.enrichPending()
        XCTAssertEqual(pass4, 1, "matched from the cached DAT while offline")
        let status = try await store.db.read { try String.fetchOne($0, sql: "SELECT artwork_status FROM metadata_jobs WHERE game_id = ?", arguments: [id]) }
        XCTAssertEqual(status, "failed")

        fetcher.offline = false
        fetcher.set(catalog.thumbnailURL(catalog.systems[.gba]!, kind: "Named_Boxarts", name: name), DatFixtures.png)
        await service.enrichPending()
        let cover = try await store.db.read { try String.fetchOne($0, sql: "SELECT path FROM game_artwork WHERE game_id = ? AND kind = 'cover'", arguments: [id]) }
        XCTAssertNotNil(cover)
    }

    func testArtworkURLChangeRefetchesForTheSameMatch() async throws {
        let id = try await importROM(ROMFixtures.gba(seed: 71), "same-game.gba")
        let oldURL = URL(string: "https://art.example/old.png")!
        let newURL = URL(string: "https://art.example/new.png")!
        fetcher.set(oldURL, DatFixtures.png)
        let oldProvider = PartialArtworkProvider(artworkURL: oldURL)
        let firstService = MetadataService(store: store, http: RateLimitedFetcher(fetcher, minimumInterval: .zero),
                                           providers: [oldProvider])
        await firstService.enrichPending()
        let original = try await store.db.read {
            (
                try String.fetchOne($0, sql: "SELECT path FROM game_artwork WHERE game_id = ? AND kind = 'cover'", arguments: [id]),
                try String.fetchOne($0, sql: "SELECT record_hash FROM metadata_jobs WHERE game_id = ?", arguments: [id])
            )
        }

        fetcher.set(newURL, DatFixtures.png + Data([2]))
        let newProvider = PartialArtworkProvider(artworkURL: newURL)
        let secondService = MetadataService(store: store, http: RateLimitedFetcher(fetcher, minimumInterval: .zero),
                                            providers: [newProvider])
        await secondService.enrichPending()
        let updated = try await store.db.read {
            (
                try String.fetchOne($0, sql: "SELECT path FROM game_artwork WHERE game_id = ? AND kind = 'cover'", arguments: [id]),
                try String.fetchOne($0, sql: "SELECT record_hash FROM metadata_jobs WHERE game_id = ?", arguments: [id]),
                try String.fetchOne($0, sql: "SELECT source_url FROM game_artwork WHERE game_id = ? AND kind = 'cover'", arguments: [id])
            )
        }
        XCTAssertNotEqual(updated.0, original.0)
        XCTAssertNotEqual(updated.1, original.1)
        XCTAssertEqual(updated.2, newURL.absoluteString)
    }

    func testUnmatchedHomebrewAndBadChecksums() async throws {
        let rom = ROMFixtures.snes(seed: 45)
        var catalog = catalog([.snes: ("Nintendo - Super Nintendo Entertainment System", "no-intro", [
            "source": DatFixtures.entry("Other Game (USA)", rom: ROMFixtures.snes(seed: 46), romName: "Other.sfc"),
        ])])
        let id = try await importROM(rom, "My Homebrew.sfc")
let pass5 = await service(catalog).enrichPending()
        XCTAssertEqual(pass5, 1)
        let status = try await store.db.read { try String.fetchOne($0, sql: "SELECT match_status FROM metadata_jobs WHERE game_id = ?", arguments: [id]) }
        XCTAssertEqual(status, "unmatched")
        XCTAssertFalse(fetcher.requests.contains { $0.path.contains("Named_") }, "no thumbnail lookups without a match")

        // A tampered download (hash differs from the pin) is never used.
        let gb = ROMFixtures.gameBoy(seed: 4)
        catalog = self.catalog([.gb: ("Nintendo - Game Boy", "no-intro", ["source": DatFixtures.entry("Tetris (World)", rom: gb, romName: "Tetris.gb")])])
        catalog.systems[.gb]!.files["source"] = String(repeating: "0", count: 64)
        let gbID = try await importROM(gb, "tetris.gb")
        await service(catalog).enrichPending()
        let gbStatus = try await store.db.read { try String.fetchOne($0, sql: "SELECT match_status FROM metadata_jobs WHERE game_id = ?", arguments: [gbID]) }
        XCTAssertNil(gbStatus)
        XCTAssertFalse(FileManager.default.fileExists(atPath: self.store.paths.metadata.path + "/libretro-database/test-commit/no-intro/Nintendo - Game Boy.dat"))
    }

    func testRelocatedLibraryMatchesSNESAndStoresCover() async throws {
        let rom = ROMFixtures.snes(seed: 89)
        let name = "Super Metroid (USA)"
        let catalog = catalog([.snes: ("Nintendo - Super Nintendo Entertainment System", "no-intro", [
            "source": DatFixtures.entry(name, rom: rom, romName: "\(name).sfc"),
        ])])
        let external = sources.appendingPathComponent("external-library", isDirectory: true)
        try FileManager.default.createDirectory(at: external, withIntermediateDirectories: true)
        try store.paths.storage.switchTo(external, config: store.paths.storageConfig, dataRoot: store.paths.root)
        let id = try await importROM(rom, "super-metroid.sfc")
        let cover = DatFixtures.png + Data([5])
        fetcher.set(catalog.thumbnailURL(catalog.systems[.snes]!, kind: "Named_Boxarts", name: name), cover)

        XCTAssertNotEqual(store.paths.libraryRoot, store.paths.root)
        let pass = await service(catalog).enrichPending()
        XCTAssertEqual(pass, 1)
        let summary = try XCTUnwrap(LibraryQueries.visibleGames(
            for: try XCTUnwrap(store.authenticate(token: adminToken)), store: store
        ).first)
        XCTAssertEqual(summary.id, id)
        XCTAssertEqual(summary.title, "Super Metroid")
        XCTAssertEqual(summary.coverPath, "/v1/games/\(id)/artwork/cover")
        let coverPath = try await store.db.read {
            try String.fetchOne($0, sql: "SELECT path FROM game_artwork WHERE game_id = ? AND kind = 'cover'", arguments: [id])
        }
        XCTAssertNotNil(coverPath)
        let coverURL = store.paths.libraryFile(try XCTUnwrap(coverPath))
        XCTAssertEqual(try Data(contentsOf: coverURL), cover)
        try ArtworkStore(store: store).removeProviderArtwork(provider: "libretro", gameID: id, kind: .cover)
        XCTAssertFalse(FileManager.default.fileExists(atPath: coverURL.path))
    }

    func testRelocatedMultiDiscUsesFirstDiscTrack() async throws {
        let firstTrack = DiscFixtures.psxTrack(seed: 91)
        let secondTrack = DiscFixtures.psxTrack(seed: 92)
        let name = "Final Fantasy VII (USA) (Disc 1)"
        let catalog = catalog([.psx: ("Sony - PlayStation", "redump", [
            "source": DatFixtures.entry(name, rom: firstTrack, romName: "\(name) (Track 1).bin", serial: "SCUS-94163"),
        ])])
        let external = sources.appendingPathComponent("external-disc-library", isDirectory: true)
        try FileManager.default.createDirectory(at: external, withIntermediateDirectories: true)
        try store.paths.storage.switchTo(external, config: store.paths.storageConfig, dataRoot: store.paths.root)
        let input = sources.appendingPathComponent("multi-disc", isDirectory: true)
        try FileManager.default.createDirectory(at: input, withIntermediateDirectories: true)
        for (number, track) in [(1, firstTrack), (2, secondTrack)] {
            let folder = "FF7/Disc \(number)"
            let directory = input.appendingPathComponent(folder, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try track.write(to: directory.appendingPathComponent("Track 01.bin"))
            try DiscFixtures.cue(["Track 01.bin"]).write(
                to: directory.appendingPathComponent("Final Fantasy VII (USA) (Disc \(number)).cue")
            )
        }
        let report = try await LibraryImporter(store: store).importPaths([input.path], auth: nil)
        let id = try XCTUnwrap(report.imported.first, "\(report)").id
        let pass = await service(catalog).enrichPending()
        XCTAssertEqual(pass, 1)
        let ref = try await store.db.read {
            try String.fetchOne($0, sql: "SELECT provider_ref FROM game_metadata WHERE game_id = ? AND provider = 'libretro'", arguments: [id])
        }
        XCTAssertEqual(ref, "Final Fantasy VII (USA) (Disc 1)")
        let status = try await store.db.read {
            try String.fetchOne($0, sql: "SELECT match_status FROM metadata_jobs WHERE game_id = ? AND provider = 'libretro'", arguments: [id])
        }
        XCTAssertEqual(status, "matched")
    }

    func testEscapingAndSymlinkROMPathsAreNotMatched() async throws {
        let first = ROMFixtures.snes(seed: 93)
        let second = ROMFixtures.snes(seed: 94)
        let catalog = catalog([.snes: ("Nintendo - Super Nintendo Entertainment System", "no-intro", [
            "source": DatFixtures.entry("First Game (USA)", rom: first, romName: "First.sfc")
                + DatFixtures.entry("Second Game (USA)", rom: second, romName: "Second.sfc"),
        ])])
        let firstID = try await importROM(first, "first.sfc")
        let secondID = try await importROM(second, "second.sfc")
        let outsideFirst = sources.appendingPathComponent("outside-first-\(UUID().uuidString).sfc")
        let outsideSecond = sources.appendingPathComponent("outside-second-\(UUID().uuidString).sfc")
        try first.write(to: outsideFirst)
        try second.write(to: outsideSecond)
        let symlink = store.paths.games.appendingPathComponent(secondID).appendingPathComponent("escape.sfc")
        try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: outsideSecond)
        try await store.db.write { db in
            try db.execute(sql: "UPDATE game_files SET stored_path = ? WHERE game_id = ?",
                           arguments: ["../" + outsideFirst.lastPathComponent, firstID])
            try db.execute(sql: "UPDATE game_files SET stored_path = ? WHERE game_id = ?",
                           arguments: ["games/\(secondID)/escape.sfc", secondID])
        }

        let pass = await service(catalog).enrichPending()
        XCTAssertEqual(pass, 0)
        let jobs = try await store.db.read {
            try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM metadata_jobs WHERE provider = 'libretro'") ?? 0
        }
        XCTAssertEqual(jobs, 0)
    }

    func testUnreadableROMIsRetriedAfterItReturns() async throws {
        let rom = ROMFixtures.snes(seed: 95)
        let catalog = catalog([.snes: ("Nintendo - Super Nintendo Entertainment System", "no-intro", [
            "source": DatFixtures.entry("Restored Game (USA)", rom: rom, romName: "Restored.sfc"),
        ])])
        let id = try await importROM(rom, "restored.sfc")
        let storedPath = try await store.db.read {
            try String.fetchOne($0, sql: "SELECT stored_path FROM game_files WHERE game_id = ?", arguments: [id])
        }
        let storedURL = store.paths.libraryFile(try XCTUnwrap(storedPath))
        try FileManager.default.removeItem(at: storedURL)

        let missingPass = await service(catalog).enrichPending()
        XCTAssertEqual(missingPass, 0)
        let absentJob = try await store.db.read {
            try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM metadata_jobs WHERE game_id = ? AND provider = 'libretro'", arguments: [id]) ?? 0
        }
        XCTAssertEqual(absentJob, 0)

        try FileManager.default.createDirectory(at: storedURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try rom.write(to: storedURL)
        let restoredPass = await service(catalog).enrichPending()
        XCTAssertEqual(restoredPass, 1)
        let status = try await store.db.read {
            try String.fetchOne($0, sql: "SELECT match_status FROM metadata_jobs WHERE game_id = ? AND provider = 'libretro'", arguments: [id])
        }
        XCTAssertEqual(status, "matched")
    }

    func testMetadataRematchRoutesResetJobsWithoutChangingManualCover() async throws {
        let firstROM = ROMFixtures.snes(seed: 96)
        let secondROM = ROMFixtures.snes(seed: 97)
        let firstName = "First Game (USA)"
        let secondName = "Second Game (USA)"
        let catalog = catalog([.snes: ("Nintendo - Super Nintendo Entertainment System", "no-intro", [
            "source": DatFixtures.entry(firstName, rom: firstROM, romName: "First.sfc")
                + DatFixtures.entry(secondName, rom: secondROM, romName: "Second.sfc"),
        ])])
        let firstID = try await importROM(firstROM, "first-rematch.sfc")
        let secondID = try await importROM(secondROM, "second-rematch.sfc")
        let artwork = ArtworkStore(store: store)
        let manualCover = DatFixtures.png + Data([31])
        let manualCoverPath = try artwork.setCover(gameID: firstID, data: manualCover, fileExtension: "png")
        try await store.db.write { db in
            try MetadataRecord(provider: "wikipedia", title: "Preserved record").save(gameID: firstID, db: db)
            for id in [firstID, secondID] {
                for provider in ["libretro", "wikipedia"] {
                    try db.execute(sql: """
                        INSERT INTO metadata_jobs (game_id, provider, match_status, updated_at)
                        VALUES (?, ?, 'matched', ?)
                        """, arguments: [id, provider, Date()])
                }
            }
        }
        let player = try store.createUser(displayName: "Player", role: .player)
        let playerToken = try store.createDeviceToken(userID: player.id, deviceName: "Player device").token
        let route = "/v1/admin/metadata/rematch"

        try await app().test(.router) { client in
            let unknown = ByteBuffer(data: try SupersEmuJSON.encoder().encode(MetadataRematchRequest(gameIDs: ["missing"])))
            try await client.execute(uri: route, method: .post, headers: self.auth(), body: unknown) {
                XCTAssertEqual($0.status, .notFound)
            }
            let unchanged = try await self.store.db.read {
                try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM metadata_jobs") ?? 0
            }
            XCTAssertEqual(unchanged, 4)

            let selected = ByteBuffer(data: try SupersEmuJSON.encoder().encode(MetadataRematchRequest(gameIDs: [firstID])))
            try await client.execute(uri: route, method: .post, headers: self.auth(playerToken), body: selected) {
                XCTAssertEqual($0.status, .forbidden)
            }
            try await client.execute(uri: route, method: .post, headers: self.auth(), body: selected) {
                XCTAssertEqual($0.status, .ok)
                XCTAssertEqual(try self.decode(MetadataRematchResponse.self, $0).queued, 1)
            }
        }
        let afterSelected = try await store.db.read { db in
            (
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM metadata_jobs WHERE game_id = ?", arguments: [firstID]) ?? 0,
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM metadata_jobs WHERE game_id = ?", arguments: [secondID]) ?? 0
            )
        }
        XCTAssertEqual(afterSelected.0, 0)
        XCTAssertEqual(afterSelected.1, 2)
        let storedManualCover = try await store.db.read {
            try String.fetchOne($0, sql: "SELECT cover_artwork FROM games WHERE id = ?", arguments: [firstID])
        }
        XCTAssertEqual(storedManualCover, "artwork/\(firstID)/\(manualCoverPath.lastPathComponent)")
        let preservedRecord = try await store.db.read {
            try String.fetchOne($0, sql: "SELECT title FROM game_metadata WHERE game_id = ? AND provider = 'wikipedia'", arguments: [firstID])
        }
        XCTAssertEqual(preservedRecord, "Preserved record")

        try await app().test(.router) { client in
            let all = ByteBuffer(data: try SupersEmuJSON.encoder().encode(MetadataRematchRequest(gameIDs: nil)))
            try await client.execute(uri: route, method: .post, headers: self.auth(), body: all) {
                XCTAssertEqual($0.status, .ok)
                XCTAssertEqual(try self.decode(MetadataRematchResponse.self, $0).queued, 2)
            }
        }
        let afterAll = try await store.db.read {
            try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM metadata_jobs") ?? 0
        }
        XCTAssertEqual(afterAll, 0)

        let firstCoverURL = catalog.thumbnailURL(catalog.systems[.snes]!, kind: "Named_Boxarts", name: firstName)
        let secondCoverURL = catalog.thumbnailURL(catalog.systems[.snes]!, kind: "Named_Boxarts", name: secondName)
        fetcher.set(firstCoverURL, DatFixtures.png)
        fetcher.set(secondCoverURL, DatFixtures.png)
        let pass = await service(catalog).enrichPending()
        XCTAssertEqual(pass, 2)
        let jobsPerProvider = try await store.db.read { db in
            try Int.fetchOne(db, sql: """
                SELECT COUNT(*) FROM (
                    SELECT game_id, provider FROM metadata_jobs GROUP BY game_id, provider HAVING COUNT(*) != 1
                )
                """) ?? 0
        }
        XCTAssertEqual(jobsPerProvider, 0)
        let count = try await store.db.read {
            try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM metadata_jobs") ?? 0
        }
        XCTAssertEqual(count, 2)
        try await app().test(.router) { client in
            try await client.execute(uri: "/v1/games/\(firstID)/artwork/cover", method: .get, headers: self.auth()) {
                XCTAssertEqual($0.status, .ok)
                XCTAssertEqual(Data(buffer: $0.body), manualCover)
            }
        }

        let publicApp = Application(router: buildRouter(store: store, exposure: .publicInternet), configuration: .init())
        try await publicApp.test(.router) { client in
            let body = ByteBuffer(data: try SupersEmuJSON.encoder().encode(MetadataRematchRequest(gameIDs: [firstID])))
            try await client.execute(uri: route, method: .post, body: body) {
                XCTAssertEqual($0.status, .notFound)
            }
        }
    }

    func testRedumpDiscMatchesFirstDiscTrack() async throws {
        let track = DiscFixtures.psxTrack(seed: 21), audio = DiscFixtures.audioTrack(seed: 22)
        let name = "Final Fantasy VII (USA) (Disc 1)"
        let catalog = catalog([.psx: ("Sony - PlayStation", "redump", [
            "source": DatFixtures.entry(name, rom: track, romName: "\(name) (Track 1).bin", serial: "SCUS-94163"),
        ])])
        let names = ["FF7 (Track 1).bin", "FF7 (Track 2).bin"]
        _ = try write(track, "FF7/\(names[0])")
        _ = try write(audio, "FF7/\(names[1])")
        let cue = try write(DiscFixtures.cue(names), "FF7/FF7.cue")
        let report = try await LibraryImporter(store: store).importPaths([cue.deletingLastPathComponent().path], auth: nil)
        let id = try XCTUnwrap(report.imported.first, "\(report)").id
        fetcher.set(catalog.thumbnailURL(catalog.systems[.psx]!, kind: "Named_Boxarts", name: "Final Fantasy VII (USA)"), DatFixtures.png)

let pass6 = await service(catalog).enrichPending()
        XCTAssertEqual(pass6, 1)
        let summary = try LibraryQueries.visibleGames(for: try XCTUnwrap(store.authenticate(token: adminToken)), store: store)[0]
        XCTAssertEqual(summary.id, id)
        XCTAssertEqual(summary.title, "Final Fantasy VII")
        XCTAssertEqual(summary.coverPath, "/v1/games/\(id)/artwork/cover", "falls back to the per-set name without (Disc 1)")
    }

    func testMergePrecedenceAndManualCoverOverride() async throws {
        let id = try await importROM(ROMFixtures.snes(seed: 47), "Game.sfc")
        try await store.db.write { db in
            try MetadataRecord(provider: "libretro", title: "Libretro Title", year: 1993, genres: ["Action"]).save(gameID: id, db: db)
            try MetadataRecord(provider: "igdb", title: "IGDB Title", description: "An intro.",
                               criticScore: CriticScore(score: 91, source: "IGDB", url: "https://example.com/r")).save(gameID: id, db: db)
        }
        let artwork = ArtworkStore(store: store)
        try artwork.setProviderArtwork(.cover, provider: "libretro", gameID: id, data: DatFixtures.png, fileExtension: "png")
        try artwork.setProviderArtwork(.backdrop, provider: "igdb", gameID: id, data: DatFixtures.png, fileExtension: "png")
        let manual = DatFixtures.png + Data([7])
        try artwork.setCover(gameID: id, data: manual, fileExtension: "png")

        try await app().test(.router) { client in
            try await client.execute(uri: "/v1/games/\(id)", method: .get, headers: self.auth()) {
                let detail = try self.decode(GameDetail.self, $0)
                XCTAssertEqual(detail.game.title, "IGDB Title")
                XCTAssertEqual(detail.game.year, 1993)
                XCTAssertEqual(detail.game.genres, ["Action"])
                XCTAssertEqual(detail.game.criticScore, CriticScore(score: 91, source: "IGDB", url: "https://example.com/r"))
                XCTAssertEqual(detail.game.backdropPath, "/v1/games/\(id)/artwork/backdrop")
                XCTAssertEqual(detail.summary, "An intro.")
            }
            try await client.execute(uri: "/v1/games/\(id)/artwork/cover", method: .get, headers: self.auth()) {
                XCTAssertEqual(Data(buffer: $0.body), manual, "manual cover beats provider covers")
            }
        }
    }

    func testMissingSupplementDefersMatchUntilAvailable() async throws {
        let rom = ROMFixtures.snes(seed: 50)
        let catalog = catalog([.snes: ("Nintendo - Super Nintendo Entertainment System", "no-intro", [
            "source": DatFixtures.entry("EarthBound (USA)", rom: rom, romName: "EarthBound (USA).sfc"),
            "publisher": DatFixtures.supplement("publisher", "Nintendo", rom: rom),
        ])])
        let publisherURL = catalog.datURL(catalog.systems[.snes]!, kind: "publisher")
        let fetched = try await fetcher.get(publisherURL)
        let publisher = try XCTUnwrap(fetched)
        fetcher.remove(publisherURL)
        let id = try await importROM(rom, "eb.sfc")
        let service = service(catalog)
        let first = await service.enrichPending()
        XCTAssertEqual(first, 0, "no partial match while a pinned supplement is missing")

        fetcher.set(publisherURL, publisher)
        let second = await service.enrichPending()
        XCTAssertEqual(second, 1)
        let stored = try await store.db.read { try String.fetchOne($0, sql: "SELECT publisher FROM game_metadata WHERE game_id = ?", arguments: [id]) }
        XCTAssertEqual(stored, "Nintendo")
    }

    func testDatasetBumpsRefreshArtworkAndDropStaleMatches() async throws {
        let rom = ROMFixtures.gameBoy(seed: 9)
        let name = "Kirby's Dream Land (USA, Europe)"
        let dats: [SystemID: (name: String, source: String, files: [String: String])] = [.gb: ("Nintendo - Game Boy", "no-intro", [
            "source": DatFixtures.entry(name, rom: rom, romName: "\(name).gb"),
        ])]
        let first = catalog(dats)
        fetcher.set(first.thumbnailURL(first.systems[.gb]!, kind: "Named_Boxarts", name: name), DatFixtures.png)
        let id = try await importROM(rom, "kirby.gb")
        await service(first).enrichPending()
        func coverPath() async throws -> String? {
            try await store.db.read { try String.fetchOne($0, sql: "SELECT path FROM game_artwork WHERE game_id = ? AND kind = 'cover'", arguments: [id]) }
        }
        let original = try await coverPath()
        XCTAssertNotNil(original)

        // New thumbnail pin: artwork is refetched without rematching.
        let rethumbed = catalog(dats, thumbnails: "thumbs2")
        let newArt = DatFixtures.png + Data([2])
        fetcher.set(rethumbed.thumbnailURL(rethumbed.systems[.gb]!, kind: "Named_Boxarts", name: name), newArt)
        let refreshed = await service(rethumbed).enrichPending()
        XCTAssertEqual(refreshed, 0, "no rematch")
        let updated = try await coverPath()
        XCTAssertNotEqual(updated, original)
        XCTAssertEqual(try Data(contentsOf: store.paths.root.appendingPathComponent(try XCTUnwrap(updated))), newArt)

        // New database pin without the game: its metadata and provider art go away.
        let bumped = catalog([.gb: ("Nintendo - Game Boy", "no-intro", [
            "source": DatFixtures.entry("Other (USA)", rom: ROMFixtures.gameBoy(seed: 10), romName: "Other.gb"),
        ])], commit: "test-commit-2", thumbnails: "thumbs2")
        await service(bumped).enrichPending()
        let afterBump = try await coverPath()
        XCTAssertNil(afterBump)
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.paths.root.appendingPathComponent(try XCTUnwrap(updated)).path))
        let summary = try LibraryQueries.visibleGames(for: try XCTUnwrap(store.authenticate(token: adminToken)), store: store)[0]
        XCTAssertEqual(summary.title, "kirby")
        XCTAssertNil(summary.coverPath)
    }

    func testWithdrawnThumbnailIsRemovedWithoutTouchingOtherProviders() async throws {
        let rom = ROMFixtures.gba(seed: 12)
        let name = "Golden Sun (USA, Europe)"
        let dats: [SystemID: (name: String, source: String, files: [String: String])] = [.gba: ("Nintendo - Game Boy Advance", "no-intro", [
            "source": DatFixtures.entry(name, rom: rom, romName: "\(name).gba"),
        ])]
        let first = catalog(dats)
        fetcher.set(first.thumbnailURL(first.systems[.gba]!, kind: "Named_Boxarts", name: name), DatFixtures.png)
        let id = try await importROM(rom, "gs.gba")
        await service(first).enrichPending()
        let other = try ArtworkStore(store: store).setProviderArtwork(.cover, provider: "libretro-extra", gameID: id,
                                                                     data: DatFixtures.png + Data([5]), fileExtension: "png")

        // The new pin has no box art: libretro's cover goes, the other provider's file stays and takes over.
        let withdrawn = catalog(dats, thumbnails: "thumbs2")
        await service(withdrawn).enrichPending()
        let providers = try await store.db.read {
            try String.fetchAll($0, sql: "SELECT provider FROM game_artwork WHERE game_id = ? AND kind = 'cover'", arguments: [id])
        }
        XCTAssertEqual(providers, ["libretro-extra"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: other.path))
        try await app().test(.router) { client in
            try await client.execute(uri: "/v1/games/\(id)/artwork/cover", method: .get, headers: self.auth()) {
                XCTAssertEqual($0.status, .ok)
                XCTAssertEqual(Data(buffer: $0.body), DatFixtures.png + Data([5]))
            }
        }
    }

    func testNonImageThumbnailKeepsCachedArtAndRetries() async throws {
        let rom = ROMFixtures.gba(seed: 13)
        let name = "Mother 3 (Japan)"
        let dats: [SystemID: (name: String, source: String, files: [String: String])] = [.gba: ("Nintendo - Game Boy Advance", "no-intro", [
            "source": DatFixtures.entry(name, rom: rom, romName: "\(name).gba"),
        ])]
        let first = catalog(dats)
        fetcher.set(first.thumbnailURL(first.systems[.gba]!, kind: "Named_Boxarts", name: name), DatFixtures.png)
        let id = try await importROM(rom, "m3.gba")
        await service(first).enrichPending()
        let cover: () async throws -> (Data?, String?) = {
            try await self.store.db.read { db in
                let path = try String.fetchOne(db, sql: "SELECT path FROM game_artwork WHERE game_id = ? AND kind = 'cover'", arguments: [id])
                let version = try String.fetchOne(db, sql: "SELECT artwork_version FROM metadata_jobs WHERE game_id = ?", arguments: [id])
                return (path.flatMap { FileManager.default.contents(atPath: self.store.paths.root.appendingPathComponent($0).path) }, version)
            }
        }
        let original = try await cover()
        XCTAssertEqual(original.0, DatFixtures.png)

        let second = catalog(dats, thumbnails: "thumbs2")
        let url = second.thumbnailURL(second.systems[.gba]!, kind: "Named_Boxarts", name: name)
        fetcher.set(url, Data("<html>error</html>".utf8))
        await service(second).enrichPending()
        let afterError = try await cover()
        XCTAssertEqual(afterError.0, DatFixtures.png)
        XCTAssertEqual(afterError.1, original.1)

        fetcher.set(url, DatFixtures.png + Data([9]))
        await service(second).enrichPending()
        let afterRetry = try await cover()
        XCTAssertEqual(afterRetry.0, DatFixtures.png + Data([9]))
        XCTAssertNotEqual(afterRetry.1, original.1)
    }
}
