import Foundation
import GRDB
import Hummingbird
import HummingbirdTesting
import SupersEmuKit
@testable import SupersEmuServerCore
import XCTest

enum ROMFixtures {
    static func snes(seed: UInt8) -> Data {
        var bytes = [UInt8](repeating: 0, count: 0x8000)
        for i in 0..<64 { bytes[i] = seed &+ UInt8(i) }
        return Data(bytes)
    }

    static func gameBoy(cgbFlag: UInt8 = 0x00, seed: UInt8 = 1) -> Data {
        var bytes = [UInt8](repeating: 0, count: 0x8000)
        bytes.replaceSubrange(0x104..<0x134, with: SystemDetector.nintendoLogo)
        bytes[0x143] = cgbFlag
        bytes[0x200] = seed
        return Data(bytes)
    }

    static func gba(seed: UInt8 = 1) -> Data {
        var bytes = [UInt8](repeating: 0, count: 0x400)
        bytes[0xB2] = 0x96
        bytes[0x300] = seed
        return Data(bytes)
    }

    static func genesis(name: String = "SEGA GENESIS    ", seed: UInt8 = 1) -> Data {
        var bytes = [UInt8](repeating: 0, count: 0x4000)
        bytes.replaceSubrange(0x100..<0x110, with: Array(name.utf8.prefix(16)))
        bytes[0x300] = seed
        return Data(bytes)
    }

    /// Interleaves a plain Genesis ROM into Super Magic Drive (.smd) layout.
    static func smd(from rom: Data) -> Data {
        var out = [UInt8](repeating: 0, count: 512)
        let bytes = [UInt8](rom)
        for start in stride(from: 0, to: bytes.count, by: 0x4000) {
            var block = [UInt8](repeating: 0, count: 0x4000)
            for i in 0..<0x2000 {
                block[i] = bytes[start + i * 2 + 1]
                block[0x2000 + i] = bytes[start + i * 2]
            }
            out += block
        }
        return Data(out)
    }
}

final class SystemDetectorTests: XCTestCase {
    func detect(_ name: String, _ data: Data) -> SystemDetector.Result {
        SystemDetector.detect(filename: name, header: data.prefix(SystemDetector.headerLength), size: Int64(data.count))
    }

    func testDetectsSystemsByExtensionAndHeader() {
        XCTAssertEqual(detect("Hello.sfc", ROMFixtures.snes(seed: 1)), .system(.snes))
        XCTAssertEqual(detect("Hello.smc", ROMFixtures.snes(seed: 1) + Data(count: 512)), .system(.snes))
        XCTAssertEqual(detect("Tetris.gb", ROMFixtures.gameBoy()), .system(.gb))
        XCTAssertEqual(detect("Color.gb", ROMFixtures.gameBoy(cgbFlag: 0xC0)), .system(.gbc))
        XCTAssertEqual(detect("Dual.gbc", ROMFixtures.gameBoy(cgbFlag: 0x80)), .system(.gbc))
        XCTAssertEqual(detect("Dual.gb", ROMFixtures.gameBoy(cgbFlag: 0x80)), .system(.gb))
        XCTAssertEqual(detect("Adv.gba", ROMFixtures.gba()), .system(.gba))
        XCTAssertEqual(detect("Sonic.md", ROMFixtures.genesis()), .system(.genesis))
        XCTAssertEqual(detect("Sonic.gen", ROMFixtures.genesis(name: " SEGA MEGA DRIVE")), .system(.genesis))
        XCTAssertEqual(detect("Sonic.bin", ROMFixtures.genesis()), .system(.genesis))
        XCTAssertEqual(detect("Sonic.smd", ROMFixtures.smd(from: ROMFixtures.genesis())), .system(.genesis))
    }

    func testAmbiguousFilesNeedReview() {
        guard case .needsReview = detect("Mystery.bin", Data(count: 0x4000)) else { return XCTFail(".bin without SEGA header") }
        guard case .needsReview = detect("Bad.gb", Data(count: 0x8000)) else { return XCTFail("gb without logo") }
        guard case .needsReview = detect("Bad.gba", Data(count: 0x400)) else { return XCTFail("gba without fixed byte") }
        guard case .needsReview = detect("Tiny.sfc", Data(count: 100)) else { return XCTFail("tiny snes") }
        guard case .needsReview = detect("Knux.md", ROMFixtures.genesis(name: "SEGA 32X        ")) else { return XCTFail("32X") }
        guard case .needsReview = detect("game.xyz", Data(count: 10)) else { return XCTFail("unknown ext") }
        XCTAssertEqual(detect("readme.txt", Data(count: 10)), .ignored)
        XCTAssertEqual(detect("Box Art.PNG", Data(count: 10)), .ignored)
        guard case .unsupported = detect("fix.ips", Data(count: 10)) else { return XCTFail("ips") }
        guard case .unsupported = detect("set.7z", Data(count: 10)) else { return XCTFail("7z") }
        XCTAssertEqual(detect(".DS_Store", Data(count: 10)), .ignored)
    }

    func testTitleNormalizerMatchesApp() {
        XCTAssertEqual(TitleNormalizer.title(fromFilename: "Super_Game (USA) [!].sfc"), "Super Game")
        XCTAssertEqual(TitleNormalizer.title(fromFilename: "HelloWorld.sfc"), "Hello World")
    }

    func testByteRangeParsing() {
        XCTAssertEqual(ByteRange.parse(nil, size: 100), .full)
        XCTAssertEqual(ByteRange.parse("bytes=0-9", size: 100), .partial(0...9))
        XCTAssertEqual(ByteRange.parse("bytes=90-", size: 100), .partial(90...99))
        XCTAssertEqual(ByteRange.parse("bytes=90-500", size: 100), .partial(90...99))
        XCTAssertEqual(ByteRange.parse("bytes=-10", size: 100), .partial(90...99))
        XCTAssertEqual(ByteRange.parse("bytes=-500", size: 100), .partial(0...99))
        XCTAssertEqual(ByteRange.parse("bytes=100-", size: 100), .unsatisfiable)
        XCTAssertEqual(ByteRange.parse("bytes=-0", size: 100), .unsatisfiable)
        XCTAssertEqual(ByteRange.parse("bytes=9-0", size: 100), .full)
        XCTAssertEqual(ByteRange.parse("bytes=0-1,5-6", size: 100), .full)
        XCTAssertEqual(ByteRange.parse("items=0-1", size: 100), .full)
    }
}

final class LibraryTests: XCTestCase {
    var store: ServerStore!
    var admin: UserInfo!
    var adminToken: String!
    var sources: URL!

    override func setUp() async throws {
        store = try ServerStore.inMemory()
        admin = try store.createUser(displayName: "Chad", role: .admin)
        adminToken = try store.createDeviceToken(userID: admin.id, deviceName: "Chad's Mac").token
        sources = FileManager.default.temporaryDirectory.appendingPathComponent("se-src-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: sources, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: sources)
        try? FileManager.default.removeItem(at: store.paths.root)
    }

    func app() -> some ApplicationProtocol { buildApplication(store: store, configuration: .init()) }
    var importer: LibraryImporter { LibraryImporter(store: store) }

    @discardableResult
    func write(_ data: Data, _ relativePath: String, in root: URL? = nil) throws -> URL {
        let url = (root ?? sources).appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url)
        return url
    }

    func zip(_ name: String, in directory: URL, files: [String], store storedOnly: Bool = false) throws -> URL {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        process.currentDirectoryURL = directory
        process.arguments = ["-q", storedOnly ? "-0" : "-9", "-r", name] + files
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        return directory.appendingPathComponent(name)
    }

    func auth(_ token: String) -> HTTPFields { [.authorization: "Bearer \(token)"] }

    func json(_ value: some Encodable) throws -> ByteBuffer { ByteBuffer(bytes: try SupersEmuJSON.encoder().encode(value)) }

    func decode<T: Decodable>(_ type: T.Type, _ response: TestResponse) throws -> T {
        try SupersEmuJSON.decoder().decode(T.self, from: Data(buffer: response.body))
    }

    // MARK: Import pipeline

    func testImportStoresContentAddressedAndDedupes() async throws {
        let rom = ROMFixtures.snes(seed: 7)
        let source = try write(rom, "Super_Game (USA) [!].sfc")
        let before = try FileManager.default.attributesOfItem(atPath: source.path)[.modificationDate] as? Date
        let copy = try write(rom, "renamed.sfc")

        let first = try await importer.importPaths([source.path], auth: nil)
        XCTAssertEqual(first.imported.map(\.title), ["Super Game"])
        XCTAssertEqual(first.imported.first?.system, .snes)
        let id = try XCTUnwrap(first.imported.first?.id)
        XCTAssertEqual(id.count, 64)
        let stored = store.paths.games.appendingPathComponent(id).appendingPathComponent("Super_Game (USA) [!].sfc")
        XCTAssertEqual(try Data(contentsOf: stored), rom)

        let second = try await importer.importPaths([source.path, copy.path], auth: nil)
        XCTAssertEqual(second.imported, [])
        XCTAssertEqual(second.duplicates, 2)

        // Sources are read, never moved or modified.
        XCTAssertEqual(try Data(contentsOf: source), rom)
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: source.path)[.modificationDate] as? Date, before)
        XCTAssertTrue(FileManager.default.fileExists(atPath: copy.path))
        let count = try await store.db.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM games") }
        XCTAssertEqual(count, 1)
    }

    func testImportsFoldersOfMixedSystems() async throws {
        try write(ROMFixtures.gameBoy(), "Handheld/Tetris.gb")
        try write(ROMFixtures.gba(), "Handheld/Adv/Advance_Game.gba")
        try write(ROMFixtures.genesis(), "Sega/SonicTheHedgehog.md")
        try write(Data("hello".utf8), "Sega/readme.txt")
        try write(Data("junk".utf8), "Sega/.DS_Store")
        let report = try await importer.importPaths([sources.path, "relative/path.sfc", "/does/not/exist.sfc"], auth: nil)
        XCTAssertEqual(Set(report.imported.map(\.system)), [.gb, .gba, .genesis])
        XCTAssertEqual(Set(report.imported.map(\.title)), ["Tetris", "Advance Game", "Sonic The Hedgehog"])
        XCTAssertEqual(report.unsupported.count, 2, "\(report.unsupported)")
        XCTAssertFalse(report.unsupported.contains { $0.contains("readme.txt") }, "notes are skipped silently")
        XCTAssertTrue(report.unsupported.contains { $0.contains("must be absolute") })
        XCTAssertTrue(report.unsupported.contains { $0.contains("not found") })
    }

    func testUnknownAndAmbiguousFilesGoToReviewQueue() async throws {
        let mystery = try write(Data(count: 0x4000), "Mystery.bin")
        try write(Data(repeating: 3, count: 0x8000), "NoLogo.gb")
        let report = try await importer.importPaths([sources.path], auth: nil)
        XCTAssertEqual(report.imported, [])
        XCTAssertEqual(Set(report.needsReview.map(\.filename)), ["Mystery.bin", "NoLogo.gb"])
        let flags = try await store.db.read { try Int.fetchAll($0, sql: "SELECT needs_review FROM games") }
        XCTAssertEqual(flags, [1, 1])

        // Re-importing a queued file reports it as still needing review, not as a duplicate.
        let again = try await importer.importPaths([mystery.path], auth: nil)
        XCTAssertEqual(again.duplicates, 0)
        XCTAssertEqual(again.needsReview.map(\.filename), ["Mystery.bin"])

        try await app().test(.router) { client in
            let queue = try await client.execute(uri: "/v1/admin/library/review", method: .get, headers: self.auth(self.adminToken)) {
                try self.decode([ReviewItem].self, $0)
            }
            XCTAssertEqual(Set(queue.map(\.filename)), ["Mystery.bin", "NoLogo.gb"])
            XCTAssertTrue(queue.contains { $0.reason.contains("SEGA") })
            try await client.execute(uri: "/v1/library", method: .get, headers: self.auth(self.adminToken)) {
                XCTAssertEqual(try self.decode(LibraryResponse.self, $0).games, [])
            }
            try await client.execute(uri: "/v1/games/\(queue[0].id)", method: .get, headers: self.auth(self.adminToken)) {
                XCTAssertEqual($0.status, .notFound)
            }
        }
    }

    func testZipImport() async throws {
        let zipSource = sources.appendingPathComponent("zipsrc", isDirectory: true)
        try write(ROMFixtures.snes(seed: 1), "Roms/Alpha_Game (USA).sfc", in: zipSource)
        try write(ROMFixtures.gameBoy(seed: 9), "Roms/Beta.gb", in: zipSource)
        try write(Data("notes".utf8), "Roms/info.nfo", in: zipSource)
        try write(Data(count: 10), "Roms/odd.xyz", in: zipSource)
        let deflated = try zip("set.zip", in: zipSource, files: ["Roms"])
        try write(ROMFixtures.gba(seed: 4), "Gamma.gba", in: zipSource)
        let stored = try zip("stored.zip", in: zipSource, files: ["Gamma.gba"], store: true)
        let zipBytes = try Data(contentsOf: deflated)

        let report = try await importer.importPaths([deflated.path, stored.path], auth: nil)
        XCTAssertEqual(Set(report.imported.map(\.title)), ["Alpha Game", "Beta", "Gamma"])
        XCTAssertEqual(report.needsReview.map(\.filename), ["odd.xyz"])
        XCTAssertEqual(report.unsupported, [], "info.nfo is skipped silently")
        XCTAssertEqual(try Data(contentsOf: deflated), zipBytes, "zip must not be modified")

        let alpha = try XCTUnwrap(report.imported.first { $0.title == "Alpha Game" })
        let storedAlpha = store.paths.games.appendingPathComponent(alpha.id).appendingPathComponent("Alpha_Game (USA).sfc")
        XCTAssertEqual(try Data(contentsOf: storedAlpha), ROMFixtures.snes(seed: 1))

        let again = try await importer.importPaths([deflated.path], auth: nil)
        XCTAssertEqual(again.duplicates, 2)
    }

    func testCorruptZipIsReportedNotStored() async throws {
        let zipSource = sources.appendingPathComponent("zipsrc", isDirectory: true)
        try write(ROMFixtures.snes(seed: 2), "Game.sfc", in: zipSource)
        let archive = try zip("bad.zip", in: zipSource, files: ["Game.sfc"], store: true)
        var bytes = try Data(contentsOf: archive)
        bytes[100] ^= 0xFF  // inside the stored entry's data -> CRC mismatch
        try bytes.write(to: archive)
        let notZip = try write(Data("not a zip".utf8), "fake.zip")

        let report = try await importer.importPaths([archive.path, notZip.path], auth: nil)
        XCTAssertEqual(report.imported, [])
        XCTAssertEqual(report.unsupported.count, 2, "\(report.unsupported)")
        XCTAssertTrue(report.unsupported.contains { $0.contains("corrupt") })
        XCTAssertTrue(report.unsupported.contains { $0.contains("Not a valid zip") })
    }

    func testScanMovesOnlySettledFilesOutOfIncoming() async throws {
        let incoming = store.paths.incoming
        try write(ROMFixtures.snes(seed: 5), "Batch/Good.sfc", in: incoming)
        try write(Data(count: 0x4000), "Batch/Mystery.bin", in: incoming)
        try write(Data("x".utf8), "notes.txt", in: incoming)
        try write(ROMFixtures.genesis(seed: 2), "Sonic.md", in: incoming)

        try await app().test(.router) { client in
            let report = try await client.execute(uri: "/v1/admin/library/scan", method: .post, headers: self.auth(self.adminToken),
                                                  body: try self.json(ImportRequest(paths: []))) {
                XCTAssertEqual($0.status, .ok)
                return try self.decode(ImportReport.self, $0)
            }
            XCTAssertEqual(Set(report.imported.map(\.title)), ["Good", "Sonic"])
            XCTAssertEqual(report.needsReview.map(\.filename), ["Mystery.bin"])
            XCTAssertEqual(report.unsupported, [])
        }

        let fm = FileManager.default
        let day = LibraryImporter.dayFormatter.string(from: Date())
        let done = importer.importedDirectory.appendingPathComponent(day)
        XCTAssertTrue(fm.fileExists(atPath: done.appendingPathComponent("Batch/Good.sfc").path))
        XCTAssertTrue(fm.fileExists(atPath: done.appendingPathComponent("Sonic.md").path))
        XCTAssertFalse(fm.fileExists(atPath: incoming.appendingPathComponent("Batch/Good.sfc").path))
        XCTAssertTrue(fm.fileExists(atPath: incoming.appendingPathComponent("Batch/Mystery.bin").path))
        XCTAssertTrue(fm.fileExists(atPath: incoming.appendingPathComponent("notes.txt").path))

        // A second scan finds nothing new and leaves the leftovers alone.
        let again = try await importer.scanIncoming(auth: nil)
        XCTAssertEqual(again.imported, [])
        XCTAssertTrue(fm.fileExists(atPath: incoming.appendingPathComponent("Batch/Mystery.bin").path))
    }

    // MARK: Routes

    func testImportRouteRequiresAdminAndLibraryWrite() async throws {
        let rom = try write(ROMFixtures.snes(seed: 3), "Game.sfc")
        let (_, reader) = try store.createAPIToken(ownerUserID: admin.id, name: "openclaw", scopes: [.libraryRead])
        let (_, writer) = try store.createAPIToken(ownerUserID: admin.id, name: "openclaw-rw", scopes: [.libraryRead, .libraryWrite])
        let player = try store.createUser(displayName: "Alex", role: .player)
        let playerToken = try store.createDeviceToken(userID: player.id, deviceName: "Alex's iPhone").token
        let body = try json(ImportRequest(paths: [rom.path]))

        try await app().test(.router) { client in
            for token in [reader, playerToken] {
                try await client.execute(uri: "/v1/admin/library/import", method: .post, headers: self.auth(token), body: body) {
                    XCTAssertEqual($0.status, .forbidden)
                }
                try await client.execute(uri: "/v1/admin/library/review", method: .get, headers: self.auth(token)) {
                    XCTAssertEqual($0.status, .forbidden)
                }
            }
            try await client.execute(uri: "/v1/admin/library/import", method: .post, body: body) { XCTAssertEqual($0.status, .unauthorized) }
            try await client.execute(uri: "/v1/admin/library/import", method: .post, headers: self.auth(writer), body: body) {
                XCTAssertEqual($0.status, .ok)
                XCTAssertEqual(try self.decode(ImportReport.self, $0).imported.map(\.title), ["Game"])
            }
            try await client.execute(uri: "/v1/admin/library/import", method: .post, headers: self.auth(writer),
                                     body: try self.json(ImportRequest(paths: []))) {
                XCTAssertEqual($0.status, .badRequest)
            }
        }
        let actions = try await store.db.read { try String.fetchAll($0, sql: "SELECT action FROM audit_log") }
        XCTAssertEqual(actions, ["library.import"])
    }

    func testDetailAndFilesArePermissionChecked() async throws {
        let rom = ROMFixtures.gba(seed: 8)
        let id = try await importer.importPaths([try write(rom, "Advance.gba").path], auth: nil).imported[0].id
        let player = try store.createUser(displayName: "Alex", role: .player)
        let playerToken = try store.createDeviceToken(userID: player.id, deviceName: "Alex's iPhone").token

        try await app().test(.router) { client in
            let detail = try await client.execute(uri: "/v1/games/\(id)", method: .get, headers: self.auth(self.adminToken)) {
                XCTAssertEqual($0.status, .ok)
                return try self.decode(GameDetail.self, $0)
            }
            XCTAssertEqual(detail.game.title, "Advance")
            XCTAssertEqual(detail.game.totalSize, Int64(rom.count))
            XCTAssertEqual(detail.files, [GameFileInfo(id: id, filename: "Advance.gba", role: .rom, size: Int64(rom.count), discNumber: nil)])

            // Phase 2: a player sees nothing until the game is granted.
            try await client.execute(uri: "/v1/games/\(id)", method: .get, headers: self.auth(playerToken)) { XCTAssertEqual($0.status, .notFound) }
            try await client.execute(uri: "/v1/games/\(id)/files/\(id)", method: .get, headers: self.auth(playerToken)) {
                XCTAssertEqual($0.status, .notFound)
            }
            let grant = PermissionGrant(gameID: id, principalType: .user, principalID: player.id)
            try await client.execute(uri: "/v1/admin/permissions", method: .put, headers: self.auth(playerToken), body: try self.json(grant)) {
                XCTAssertEqual($0.status, .forbidden)
            }
            try await client.execute(uri: "/v1/admin/permissions", method: .put, headers: self.auth(self.adminToken),
                                     body: try self.json(PermissionGrant(gameID: id, principalType: .user, principalID: "nobody"))) {
                XCTAssertEqual($0.status, .notFound)
            }
            try await client.execute(uri: "/v1/admin/permissions", method: .put, headers: self.auth(self.adminToken),
                                     body: try self.json(PermissionGrant(gameID: "missing", principalType: .everyone, principalID: nil))) {
                XCTAssertEqual($0.status, .notFound)
            }
            for _ in 0..<2 {  // idempotent
                try await client.execute(uri: "/v1/admin/permissions", method: .put, headers: self.auth(self.adminToken), body: try self.json(grant)) {
                    XCTAssertEqual($0.status, .ok)
                    XCTAssertEqual(try self.decode(PermissionGrant.self, $0), grant)
                }
            }
            try await client.execute(uri: "/v1/games/\(id)", method: .get, headers: self.auth(playerToken)) { XCTAssertEqual($0.status, .ok) }
            try await client.execute(uri: "/v1/games/\(id)/files/\(id)", method: .get, headers: self.auth(playerToken)) {
                XCTAssertEqual($0.status, .ok)
                XCTAssertEqual(Data(buffer: $0.body), rom)
            }
            try await client.execute(uri: "/v1/games/\(id)/files/deadbeef", method: .get, headers: self.auth(self.adminToken)) {
                XCTAssertEqual($0.status, .notFound)
            }
        }
    }

    func testFileRangeAndETag() async throws {
        let rom = ROMFixtures.snes(seed: 11)
        let id = try await importer.importPaths([try write(rom, "Range.sfc").path], auth: nil).imported[0].id
        let uri = "/v1/games/\(id)/files/\(id)"
        let size = rom.count

        try await app().test(.router) { client in
            try await client.execute(uri: uri, method: .get, headers: self.auth(self.adminToken)) {
                XCTAssertEqual($0.status, .ok)
                XCTAssertEqual($0.headers[.acceptRanges], "bytes")
                XCTAssertEqual($0.headers[.eTag], "\"\(id)\"")
                XCTAssertEqual($0.headers[.contentLength], String(size))
                XCTAssertEqual(Data(buffer: $0.body), rom)
            }
            var headers = self.auth(self.adminToken)
            headers[.range] = "bytes=10-19"
            try await client.execute(uri: uri, method: .get, headers: headers) {
                XCTAssertEqual($0.status, .partialContent)
                XCTAssertEqual($0.headers[.contentRange], "bytes 10-19/\(size)")
                XCTAssertEqual($0.headers[.contentLength], "10")
                XCTAssertEqual(Data(buffer: $0.body), rom[10...19])
            }
            headers[.range] = "bytes=\(size - 100)-"
            try await client.execute(uri: uri, method: .get, headers: headers) {
                XCTAssertEqual($0.status, .partialContent)
                XCTAssertEqual(Data(buffer: $0.body), rom.suffix(100))
            }
            headers[.range] = "bytes=-4"
            try await client.execute(uri: uri, method: .get, headers: headers) {
                XCTAssertEqual($0.status, .partialContent)
                XCTAssertEqual($0.headers[.contentRange], "bytes \(size - 4)-\(size - 1)/\(size)")
            }
            headers[.range] = "bytes=\(size)-"
            try await client.execute(uri: uri, method: .get, headers: headers) {
                XCTAssertEqual($0.status, .rangeNotSatisfiable)
                XCTAssertEqual($0.headers[.contentRange], "bytes */\(size)")
            }
            headers[.range] = "bytes=0-9"
            headers[.ifRange] = "\"stale\""
            try await client.execute(uri: uri, method: .get, headers: headers) {
                XCTAssertEqual($0.status, .ok, "If-Range mismatch serves the whole file")
                XCTAssertEqual($0.body.readableBytes, size)
            }
            headers[.ifRange] = "\"\(id)\""
            try await client.execute(uri: uri, method: .get, headers: headers) { XCTAssertEqual($0.status, .partialContent) }

            var conditional = self.auth(self.adminToken)
            conditional[.ifNoneMatch] = "\"\(id)\""
            try await client.execute(uri: uri, method: .get, headers: conditional) { XCTAssertEqual($0.status, .notModified) }
        }
    }

    func testCoverArtworkHook() async throws {
        let id = try await importer.importPaths([try write(ROMFixtures.snes(seed: 12), "Art.sfc").path], auth: nil).imported[0].id
        try await app().test(.router) { client in
            try await client.execute(uri: "/v1/games/\(id)/artwork/cover", method: .get, headers: self.auth(self.adminToken)) {
                XCTAssertEqual($0.status, .notFound)
            }
            let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 1, 2, 3])
            try ArtworkStore(store: self.store).setCover(gameID: id, data: png, fileExtension: "png")
            try await client.execute(uri: "/v1/games/\(id)/artwork/cover", method: .get, headers: self.auth(self.adminToken)) {
                XCTAssertEqual($0.status, .ok)
                XCTAssertEqual($0.headers[.contentType], "image/png")
                XCTAssertEqual(Data(buffer: $0.body), png)
            }
            try await client.execute(uri: "/v1/library", method: .get, headers: self.auth(self.adminToken)) {
                XCTAssertEqual(try self.decode(LibraryResponse.self, $0).games.first?.coverPath, "/v1/games/\(id)/artwork/cover")
            }
        }
    }
}

extension LibraryTests {
    func testRecognizedReimportLeavesReviewQueue() async throws {
        let bytes = ROMFixtures.snes(seed: 21)
        let queued = try await importer.importPaths([try write(bytes, "Puzzle.xyz").path], auth: nil)
        let id = try XCTUnwrap(queued.needsReview.first?.id)

        let report = try await importer.importPaths([try write(bytes, "Puzzle_Game.sfc").path], auth: nil)
        XCTAssertEqual(report.imported.map(\.title), ["Puzzle Game"])
        XCTAssertEqual(report.needsReview, [])
        XCTAssertEqual(try importer.reviewQueue(), [])
        let gameDir = store.paths.games.appendingPathComponent(id)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: gameDir.path), ["Puzzle_Game.sfc"])
        let storedPath = try await store.db.read { try String.fetchOne($0, sql: "SELECT stored_path FROM game_files WHERE game_id = ?", arguments: [id]) }
        XCTAssertEqual(storedPath, "games/\(id)/Puzzle_Game.sfc")

        try await app().test(.router) { client in
            try await client.execute(uri: "/v1/games/\(id)", method: .get, headers: self.auth(self.adminToken)) {
                XCTAssertEqual($0.status, .ok)
                XCTAssertEqual(try self.decode(GameDetail.self, $0).game.system, .snes)
            }
        }
    }

    func testDeflateEntryWithNoCompressedBytesIsCorrupt() throws {
        func le16(_ v: Int) -> [UInt8] { [UInt8(v & 0xFF), UInt8(v >> 8 & 0xFF)] }
        func le32(_ v: Int) -> [UInt8] { le16(v & 0xFFFF) + le16(v >> 16 & 0xFFFF) }
        let name = Array("Game.sfc".utf8)
        let local = le32(0x0403_4B50) + le16(20) + le16(0) + le16(8) + le32(0) + le32(0) + le32(0) + le32(0x8000)
            + le16(name.count) + le16(0) + name
        let central = le32(0x0201_4B50) + le16(20) + le16(20) + le16(0) + le16(8) + le32(0) + le32(0) + le32(0) + le32(0x8000)
            + le16(name.count) + le16(0) + le16(0) + le16(0) + le16(0) + le32(0) + le32(0) + name
        let eocd = le32(0x0605_4B50) + le16(0) + le16(0) + le16(1) + le16(1) + le32(central.count) + le32(local.count) + le16(0)
        let url = try write(Data(local + central + eocd), "empty-deflate.zip")

        let archive = try ZipArchive(url: url)
        XCTAssertThrowsError(try archive.data(for: archive.entries[0])) {
            XCTAssertEqual($0 as? ZipArchive.ZipError, .corrupt("Game.sfc"))
        }
    }

    func testArtworkPathsCannotEscapeArtworkDirectory() async throws {
        let artwork = ArtworkStore(store: store)
        let png = Data([0x89, 0x50, 0x4E, 0x47])
        XCTAssertThrowsError(try artwork.setCover(gameID: "../escape", data: png, fileExtension: "png"))
        XCTAssertThrowsError(try artwork.setCover(gameID: "nope", data: png, fileExtension: "png"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.paths.root.appendingPathComponent("escape").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.paths.artwork.appendingPathComponent("nope").path))

        let id = try await importer.importPaths([try write(ROMFixtures.snes(seed: 22), "Escape.sfc").path], auth: nil).imported[0].id
        let outside = try write(Data("secret".utf8), "secret.png")
        let linkDir = store.paths.artwork.appendingPathComponent(id, isDirectory: true)
        try FileManager.default.createDirectory(at: linkDir, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: linkDir.appendingPathComponent("cover.png"), withDestinationURL: outside)

        for cover in [outside.path, "artwork/\(id)/cover.png", "library.sqlite"] {
            try await store.db.write { try $0.execute(sql: "UPDATE games SET cover_artwork = ? WHERE id = ?", arguments: [cover, id]) }
            try await app().test(.router) { client in
                try await client.execute(uri: "/v1/games/\(id)/artwork/cover", method: .get, headers: self.auth(self.adminToken)) {
                    XCTAssertEqual($0.status, .notFound, cover)
                }
            }
        }
    }

    func testReplacedCoverChangesETag() async throws {
        let id = try await importer.importPaths([try write(ROMFixtures.snes(seed: 23), "Cover.sfc").path], auth: nil).imported[0].id
        let artwork = ArtworkStore(store: store)
        try artwork.setCover(gameID: id, data: Data([1, 2, 3]), fileExtension: "png")
        try await app().test(.router) { client in
            let first = try await client.execute(uri: "/v1/games/\(id)/artwork/cover", method: .get, headers: self.auth(self.adminToken)) { response in
                XCTAssertEqual(response.headers[.cacheControl], "private, no-cache")
                return try XCTUnwrap(response.headers[.eTag])
            }
            var conditional = self.auth(self.adminToken)
            conditional[.ifNoneMatch] = first
            try await client.execute(uri: "/v1/games/\(id)/artwork/cover", method: .get, headers: conditional) {
                XCTAssertEqual($0.status, .notModified)
            }
            var weak = self.auth(self.adminToken)
            weak[.ifNoneMatch] = "W/" + first
            try await client.execute(uri: "/v1/games/\(id)/artwork/cover", method: .get, headers: weak) {
                XCTAssertEqual($0.status, .notModified)
            }
            try artwork.setCover(gameID: id, data: Data([4, 5, 6, 7]), fileExtension: "png")
            try await client.execute(uri: "/v1/games/\(id)/artwork/cover", method: .get, headers: conditional) {
                XCTAssertEqual($0.status, .ok)
                XCTAssertNotEqual($0.headers[.eTag], first)
                XCTAssertEqual(Data(buffer: $0.body), Data([4, 5, 6, 7]))
            }
            let files = try FileManager.default.contentsOfDirectory(atPath: self.store.paths.artwork.appendingPathComponent(id).path)
            XCTAssertEqual(files.count, 1, "old cover removed")
            XCTAssertTrue(files[0].hasPrefix("cover-") && files[0].hasSuffix(".png"))
        }
    }
}

extension LibraryTests {
    func testWeakValidatorAndOversizedCover() async throws {
        let id = try await importer.importPaths([try write(ROMFixtures.snes(seed: 24), "Weak.sfc").path], auth: nil).imported[0].id
        XCTAssertThrowsError(try ArtworkStore(store: store).setCover(gameID: id, data: Data(count: ArtworkStore.maxCoverSize + 1), fileExtension: "png")) {
            XCTAssertEqual($0 as? ArtworkStore.ArtworkError, .tooLarge)
        }
        var headers = auth(adminToken)
        headers[.ifNoneMatch] = "W/\"\(id)\""
        try await app().test(.router) { client in
            try await client.execute(uri: "/v1/games/\(id)/files/\(id)", method: .get, headers: headers) {
                XCTAssertEqual($0.status, .notModified)
            }
        }
    }
}

extension LibraryTests {
    func testConcurrentCoverUpdatesKeepRecordedFile() async throws {
        let id = try await importer.importPaths([try write(ROMFixtures.snes(seed: 25), "Race.sfc").path], auth: nil).imported[0].id
        let artwork = ArtworkStore(store: store)
        DispatchQueue.concurrentPerform(iterations: 16) { i in
            do { try artwork.setCover(gameID: id, data: Data([UInt8(i), 1, 2, 3]), fileExtension: "png") } catch { XCTFail("\(error)") }
        }
        let recorded = try await store.db.read { try String.fetchOne($0, sql: "SELECT cover_artwork FROM games WHERE id = ?", arguments: [id]) }
        let path = try XCTUnwrap(recorded)
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.paths.root.appendingPathComponent(path).path))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: store.paths.artwork.appendingPathComponent(id).path).count, 1)
    }
}
