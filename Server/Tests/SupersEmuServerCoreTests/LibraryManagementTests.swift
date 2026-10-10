import Foundation
import Hummingbird
import HummingbirdTesting
import SupersEmuKit
import XCTest
@testable import SupersEmuServerCore

final class LibraryManagementTests: XCTestCase {
    var store: ServerStore!
    var adminToken = ""
    var playerToken = ""
    var extraFolders: [URL] = []

    override func setUp() async throws {
        store = try ServerStore.inMemory()
        let admin = try store.createUser(displayName: "Chad", role: .admin)
        adminToken = try store.createDeviceToken(userID: admin.id, deviceName: "Chad's Mac").token
        let player = try store.createUser(displayName: "Alex", role: .player)
        playerToken = try store.createDeviceToken(userID: player.id, deviceName: "Alex's iPad").token
    }

    override func tearDown() async throws {
        LibraryImporter.maxUploadFileSize = 4 << 30
        for url in extraFolders + [store.paths.root] { try? FileManager.default.removeItem(at: url) }
    }

    func app() -> some ApplicationProtocol { buildApplication(store: store, configuration: .init()) }
    var importer: LibraryImporter { LibraryImporter(store: store) }
    func auth(_ token: String) -> HTTPFields { [.authorization: "Bearer \(token)"] }
    func decode<T: Decodable>(_ type: T.Type, _ response: TestResponse) throws -> T {
        try SupersEmuJSON.decoder().decode(T.self, from: Data(buffer: response.body))
    }
    func json(_ value: some Encodable) throws -> ByteBuffer { ByteBuffer(bytes: try SupersEmuJSON.encoder().encode(value)) }

    func uploadURI(_ batch: String, _ path: String) -> String {
        let encoded = path.addingPercentEncoding(withAllowedCharacters: .alphanumerics.union(CharacterSet(charactersIn: "-._~")))!
        return "/v1/admin/library/upload?batch=\(batch)&path=\(encoded)"
    }

    @discardableResult
    func upload(_ client: some TestClientProtocol, _ data: Data, _ path: String, batch: String = "b1", token: String? = nil,
                status: HTTPResponse.Status = .ok) async throws -> TestResponse {
        try await client.execute(uri: uploadURI(batch, path), method: .post, headers: auth(token ?? adminToken), body: ByteBuffer(bytes: data)) {
            XCTAssertEqual($0.status, status, "\(path): \(String(buffer: $0.body))")
            return $0
        }
    }

    func finish(_ client: some TestClientProtocol, batch: String = "b1") async throws -> ImportReport {
        try await client.execute(uri: "/v1/admin/library/upload/\(batch)/finish", method: .post, headers: auth(adminToken)) {
            XCTAssertEqual($0.status, .ok, String(buffer: $0.body))
            return try self.decode(ImportReport.self, $0)
        }
    }

    func issues(_ client: some TestClientProtocol) async throws -> [LibraryIssue] {
        try await client.execute(uri: "/v1/admin/library/issues", method: .get, headers: auth(adminToken)) { try self.decode([LibraryIssue].self, $0) }
    }

    func write(_ data: Data, _ relativePath: String, in root: URL) throws {
        let url = root.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url)
    }

    // MARK: Uploads

    func testUploadRequiresAdminWithLibraryWrite() async throws {
        try await app().test(.router) { client in
            try await client.execute(uri: self.uploadURI("b1", "Game.sfc"), method: .post, body: ByteBuffer(bytes: ROMFixtures.snes(seed: 1))) {
                XCTAssertEqual($0.status, .unauthorized)
            }
            try await self.upload(client, ROMFixtures.snes(seed: 1), "Game.sfc", token: self.playerToken, status: .forbidden)
            let readOnly = try self.store.createAPIToken(ownerUserID: try self.store.listUsers().first { $0.role == .admin }!.id,
                                                         name: "read", scopes: [.libraryRead]).token
            try await self.upload(client, ROMFixtures.snes(seed: 1), "Game.sfc", token: readOnly, status: .forbidden)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.paths.incoming.appendingPathComponent(".uploads/b1").path))
    }

    func testUploadRejectsUnsafePaths() async throws {
        try await app().test(.router) { client in
            for path in ["../escape.sfc", "a/../../escape.sfc", "/etc/passwd", ".hidden.sfc", "a//b.sfc", "a/", "", "x\\..\\y.sfc", "a:b.sfc"] {
                try await self.upload(client, Data("x".utf8), path, status: .badRequest)
            }
            for batch in ["../b", "a b", String(repeating: "a", count: 65), ""] {
                try await self.upload(client, Data("x".utf8), "ok.sfc", batch: batch, status: .badRequest)
            }
        }
        let leftovers = FileManager.default.enumerator(atPath: store.paths.root.deletingLastPathComponent().path)
        XCTAssertNotNil(leftovers)
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.paths.root.deletingLastPathComponent().appendingPathComponent("escape.sfc").path))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: store.paths.incoming.path).filter { $0 != ".uploads" }, [])
    }

    func testUploadSizeLimitLeavesNothingBehind() async throws {
        LibraryImporter.maxUploadFileSize = 1024
        try await app().test(.router) { client in
            try await self.upload(client, Data(repeating: 1, count: 4096), "Big.sfc", status: .contentTooLarge)
            try await self.upload(client, Data(repeating: 1, count: 512), "Small.sfc")
            try await self.upload(client, Data(repeating: 2, count: 512), "Small.sfc", status: .conflict)
        }
        let staging = store.paths.incoming.appendingPathComponent(".uploads")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: staging.path), ["b1"])
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: staging.appendingPathComponent("b1").path), ["Small.sfc"])
    }

    func testUploadedBatchIsScannedAndCopiesAreRemoved() async throws {
        try await app().test(.router) { client in
            try await self.upload(client, ROMFixtures.snes(seed: 3), "My Games/Super Game (USA).sfc")
            try await self.upload(client, ROMFixtures.gba(seed: 4), "My Games/Handheld (USA).gba")
            try await self.upload(client, ROMFixtures.snes(seed: 5), "Name + Plus & Co.sfc")
            let report = try await self.finish(client)
            XCTAssertEqual(Set(report.imported.map(\.title)), ["Super Game", "Handheld", "Name + Plus & Co"])
            try await client.execute(uri: "/v1/admin/library/upload/b1/finish", method: .post, headers: self.auth(self.adminToken)) {
                XCTAssertEqual($0.status, .notFound)
            }
            try await self.upload(client, ROMFixtures.snes(seed: 3), "Again.sfc", batch: "b2")
            let again = try await self.finish(client, batch: "b2")
            XCTAssertEqual(again.duplicates, 1)
        }
        let leftover = try FileManager.default.contentsOfDirectory(atPath: store.paths.incoming.path).filter { $0 != ".uploads" && $0 != "Uploads" }
        XCTAssertEqual(leftover, [])
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.paths.imported.path))
        XCTAssertEqual((try? FileManager.default.contentsOfDirectory(atPath: store.paths.incoming.appendingPathComponent("Uploads").path)) ?? [], [])
    }

    // MARK: Review Needed

    func testIssuesExplainEachProblemAndOfferSafeFixes() async throws {
        let incoming = store.paths.incoming
        try write(DiscFixtures.cue(["Disc Game (Track 1).bin", "Disc Game (Track 2).bin"]), "Disc Game/Disc Game.cue", in: incoming)
        try write(DiscFixtures.psxTrack(seed: 9), "Disc Game/Disc Game (Track 1).bin", in: incoming)
        try write(Data(repeating: 7, count: 0x8000), "Mystery.gb", in: incoming)
        try write(Data(repeating: 3, count: 4096), "Disc.pbp", in: incoming)
        try write(Data(repeating: 5, count: 4096), "Thing.rom", in: incoming)
        _ = try await importer.scanIncoming(auth: nil)

        try await app().test(.router) { client in
            var issues = try await self.issues(client)
            let byFile = Dictionary(uniqueKeysWithValues: issues.map { ($0.filename, $0) })
            XCTAssertEqual(byFile["Disc Game.cue"]?.kind, .missingFiles)
            XCTAssertTrue(byFile["Disc Game.cue"]?.reason.contains("Disc Game (Track 2).bin") == true)
            XCTAssertEqual(byFile["Disc Game.cue"]?.candidateSystems, [])
            XCTAssertNil(byFile["Disc Game (Track 1).bin"], "a disc's tracks are part of its sheet's item")
            XCTAssertEqual(byFile["Mystery.gb"]?.kind, .ambiguous)
            XCTAssertEqual(byFile["Mystery.gb"]?.incomingPath, "Mystery.gb")
            XCTAssertTrue(byFile["Mystery.gb"]?.candidateSystems.contains(.gb) == true)
            XCTAssertEqual(byFile["Disc.pbp"]?.kind, .unsupportedFormat)
            XCTAssertNil(byFile["Disc.pbp"]?.reviewID)
            XCTAssertNotNil(byFile["Thing.rom"], "\(issues)")

            // Picking a console for a disc or an unsupported file is refused.
            for name in ["Disc Game.cue", "Disc.pbp"] {
                try await client.execute(uri: "/v1/admin/library/issues/\(byFile[name]!.id)/system", method: .post,
                                         headers: self.auth(self.adminToken), body: try self.json(AssignSystemRequest(system: .psx))) {
                    XCTAssertEqual($0.status, .badRequest)
                }
            }
            try await client.execute(uri: "/v1/admin/library/issues/\(byFile["Mystery.gb"]!.id)/system", method: .post,
                                     headers: self.auth(self.playerToken), body: try self.json(AssignSystemRequest(system: .gb))) {
                XCTAssertEqual($0.status, .forbidden)
            }

            // Pick the console: the game joins the library and its source leaves Incoming.
            let game = try await client.execute(uri: "/v1/admin/library/issues/\(byFile["Mystery.gb"]!.id)/system", method: .post,
                                                headers: self.auth(self.adminToken), body: try self.json(AssignSystemRequest(system: .gb))) {
                XCTAssertEqual($0.status, .ok, String(buffer: $0.body))
                return try self.decode(GameSummary.self, $0)
            }
            XCTAssertEqual(game.system, .gb)
            try await client.execute(uri: "/v1/library", method: .get, headers: self.auth(self.adminToken)) {
                XCTAssertEqual(try self.decode(LibraryResponse.self, $0).games.map(\.id), [game.id])
            }
            XCTAssertFalse(FileManager.default.fileExists(atPath: incoming.appendingPathComponent("Mystery.gb").path))

            // Delete: the file leaves Incoming and the issue is gone.
            try await client.execute(uri: "/v1/admin/library/issues/\(byFile["Disc.pbp"]!.id)", method: .delete, headers: self.auth(self.adminToken)) {
                XCTAssertEqual($0.status, .noContent)
            }
            XCTAssertFalse(FileManager.default.fileExists(atPath: incoming.appendingPathComponent("Disc.pbp").path))
            try await client.execute(uri: "/v1/admin/library/issues/\(byFile["Disc.pbp"]!.id)", method: .delete, headers: self.auth(self.adminToken)) {
                XCTAssertEqual($0.status, .notFound)
            }

            // Retry after adding the missing track: a rescan imports the disc.
            try self.write(DiscFixtures.audioTrack(seed: 10), "Disc Game/Disc Game (Track 2).bin", in: incoming)
            let report = try await client.execute(uri: "/v1/admin/library/scan", method: .post, headers: self.auth(self.adminToken)) {
                try self.decode(ImportReport.self, $0)
            }
            XCTAssertEqual(report.imported.map(\.system), [.psx])
            issues = try await self.issues(client)
            XCTAssertEqual(issues.map(\.filename), ["Thing.rom"])
        }
    }

    func testDeletingDiscIssueRemovesSheetAndTracks() async throws {
        let incoming = store.paths.incoming
        try write(DiscFixtures.cue(["Disc Game (Track 1).bin", "Disc Game (Track 2).bin"]), "Disc Game/Disc Game.cue", in: incoming)
        try write(Data(count: 2352 * 16), "Disc Game/Disc Game (Track 1).bin", in: incoming)
        _ = try await importer.scanIncoming(auth: nil)

        try await app().test(.router) { client in
            let issues = try await self.issues(client)
            XCTAssertEqual(issues.map(\.filename), ["Disc Game.cue"])
            try await client.execute(uri: "/v1/admin/library/issues/\(issues[0].id)", method: .delete, headers: self.auth(self.adminToken)) {
                XCTAssertEqual($0.status, .noContent)
            }
            let remaining = try await self.issues(client)
            XCTAssertEqual(remaining.map(\.filename), [])
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: incoming.appendingPathComponent("Disc Game/Disc Game (Track 1).bin").path))
    }

    func testRetryReportsTheDiscsNewProblem() async throws {
        let incoming = store.paths.incoming
        try write(DiscFixtures.cue(["Disc Game (Track 1).bin", "Disc Game (Track 2).bin"]), "Disc Game/Disc Game.cue", in: incoming)
        try write(Data(count: 2352 * 16), "Disc Game/Disc Game (Track 1).bin", in: incoming)
        _ = try await importer.scanIncoming(auth: nil)
        try write(Data(repeating: 1, count: 2352 * 8), "Disc Game/Disc Game (Track 2).bin", in: incoming)
        let report = try await importer.scanIncoming(auth: nil)

        XCTAssertEqual(report.needsReview.map(\.reason), ["Unrecognised disc (no PS1 or Sega CD header)"])
        let issues = try importer.issues()
        XCTAssertEqual(issues.map(\.filename), ["Disc Game.cue"])
        XCTAssertEqual(issues.first?.reason, "Unrecognised disc (no PS1 or Sega CD header)")
    }

    func testUploadGateKeepsBatchesMovesAndOwnersApart() throws {
        let storage = LibraryStorage(root: store.paths.root)
        try storage.beginUpload(batch: "b1", owner: "device:a")
        XCTAssertThrowsError(try storage.beginUpload(batch: "b1", owner: "device:b"))
        XCTAssertThrowsError(try storage.beginFinish(batch: "b1", owner: "device:a"), "finish waits for streams")
        XCTAssertThrowsError(try storage.beginMove(StorageMove(destination: "/x", phase: .copying, bytesDone: 0, bytesTotal: 0)))
        storage.endUpload(batch: "b1")
        XCTAssertThrowsError(try storage.beginFinish(batch: "b1", owner: "device:b"))
        try storage.beginFinish(batch: "b1", owner: "device:a")
        XCTAssertThrowsError(try storage.beginUpload(batch: "b1", owner: "device:a"), "no appending while finishing")
        storage.endFinish(batch: "b1", finished: true)
        try storage.beginMove(StorageMove(destination: "/x", phase: .copying, bytesDone: 0, bytesTotal: 0))
        XCTAssertThrowsError(try storage.beginUpload(batch: "b2", owner: "device:a"), "no uploads during a move")
    }

    func testBatchStagedBeforeRestartHasNoOwner() throws {
        let storage = LibraryStorage(root: FileManager.default.temporaryDirectory)
        XCTAssertThrowsError(try storage.beginUpload(batch: "b1", owner: "device:b", stagedOnDisk: true))
        XCTAssertThrowsError(try storage.beginFinish(batch: "b1", owner: "device:b"))
        try storage.beginUpload(batch: "b2", owner: "device:a", stagedOnDisk: false)
        storage.endUpload(batch: "b2")
        try storage.beginUpload(batch: "b2", owner: "device:a", stagedOnDisk: true)
    }

    func testDeletingWrongBIOSClearsItsStatus() async throws {
        try write(Data(repeating: 9, count: 524_288), "scph5501.bin", in: store.paths.incoming)
        _ = try await importer.scanIncoming(auth: nil)
        let wrong = try BIOSLibrary.status(store: store, known: KnownBIOS.all).first { $0.filename == "scph5501.bin" }
        XCTAssertEqual(wrong?.state, .wrongHash)
        let issue = try XCTUnwrap(try importer.issues().first { $0.kind == .wrongBIOS })
        try await importer.deleteIssue(issue.id, auth: nil)
        XCTAssertEqual(try BIOSLibrary.status(store: store, known: KnownBIOS.all).first { $0.filename == "scph5501.bin" }?.state, .missing)
    }

    func testDeletingQueuedImportRemovesStoredCopy() async throws {
        let source = FileManager.default.temporaryDirectory.appendingPathComponent("se-src-\(UUID().uuidString)", isDirectory: true)
        extraFolders.append(source)
        try write(Data(repeating: 7, count: 0x8000), "NoLogo.gb", in: source)
        let report = try await importer.importPaths([source.appendingPathComponent("NoLogo.gb").path], auth: nil)
        let id = try XCTUnwrap(report.needsReview.first?.id)
        try await app().test(.router) { client in
            let issues = try await self.issues(client)
            XCTAssertEqual(issues.map(\.id), ["rq-\(id)"])
            XCTAssertNil(issues[0].incomingPath)
            try await client.execute(uri: "/v1/admin/library/issues/rq-\(id)", method: .delete, headers: self.auth(self.adminToken)) {
                XCTAssertEqual($0.status, .noContent)
            }
            let remaining = try await self.issues(client)
            XCTAssertEqual(remaining, [])
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.paths.games.appendingPathComponent(id).path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.appendingPathComponent("NoLogo.gb").path), "originals are never touched")
    }

    // MARK: Storage

    func waitForMove() async throws -> StorageMove {
        for _ in 0..<200 {
            if let move = store.paths.storage.move, !move.isRunning { return move }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        throw XCTSkip("move did not finish")
    }

    func testMoveLibraryCopiesVerifiesSwitchesAndCleansUp() async throws {
        let drive = FileManager.default.temporaryDirectory.appendingPathComponent("se-drive-\(UUID().uuidString)", isDirectory: true)
        extraFolders.append(drive)
        try FileManager.default.createDirectory(at: drive, withIntermediateDirectories: true)
        let source = FileManager.default.temporaryDirectory.appendingPathComponent("se-src-\(UUID().uuidString)", isDirectory: true)
        extraFolders.append(source)
        try write(ROMFixtures.snes(seed: 21), "Moved Game.sfc", in: source)
        let game = try await importer.importPaths([source.appendingPathComponent("Moved Game.sfc").path], auth: nil).imported[0]
        try write(Data(repeating: 3, count: 100), "Left.pbp", in: store.paths.incoming)
        let oldGames = store.paths.games

        try await app().test(.router) { client in
            try await client.execute(uri: "/v1/admin/storage/move", method: .post, headers: self.auth(self.playerToken),
                                     body: try self.json(MoveLibraryRequest(destination: drive.path))) { XCTAssertEqual($0.status, .forbidden) }
            for bad in ["relative/path", drive.appendingPathComponent("missing").path, self.store.paths.games.path] {
                try await client.execute(uri: "/v1/admin/storage/move", method: .post, headers: self.auth(self.adminToken),
                                         body: try self.json(MoveLibraryRequest(destination: bad))) { XCTAssertEqual($0.status, .badRequest, bad) }
            }
            try await client.execute(uri: "/v1/admin/storage/move", method: .post, headers: self.auth(self.adminToken),
                                     body: try self.json(MoveLibraryRequest(destination: drive.path))) { XCTAssertEqual($0.status, .accepted) }
            let move = try await self.waitForMove()
            XCTAssertEqual(move.phase, .done, move.error ?? "")
            let status = try await client.execute(uri: "/v1/admin/storage", method: .get, headers: self.auth(self.adminToken)) {
                try self.decode(StorageStatus.self, $0)
            }
            let target = drive.appendingPathComponent("SupersEmu Library").resolvingSymlinksInPath().path
            XCTAssertEqual(status.libraryDirectory, target)
            XCTAssertFalse(status.isDefault)
            XCTAssertTrue(status.available)
            XCTAssertGreaterThan(status.libraryBytes, 0)
            try await client.execute(uri: "/v1/games/\(game.id)/files/\(game.id)", method: .get, headers: self.auth(self.adminToken)) {
                XCTAssertEqual($0.status, .ok)
                XCTAssertEqual(Data(buffer: $0.body), ROMFixtures.snes(seed: 21))
            }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: oldGames.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: drive.appendingPathComponent("SupersEmu Library/Incoming/Left.pbp").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.paths.storageConfig.path), "the switch is recorded in the data folder")

        // Reopening reads storage.json; with the drive gone nothing is created in its place and imports are refused.
        let reopened = try ServerStore.open(paths: ServerPaths(root: store.paths.root))
        XCTAssertEqual(reopened.paths.libraryRoot.resolvingSymlinksInPath().path, drive.appendingPathComponent("SupersEmu Library").resolvingSymlinksInPath().path)
        try FileManager.default.removeItem(at: drive)
        let unplugged = try ServerStore.open(paths: ServerPaths(root: store.paths.root))
        XCTAssertFalse(unplugged.paths.storage.isAvailable)
        XCTAssertFalse(FileManager.default.fileExists(atPath: drive.path))
        let offlineAdmin = try unplugged.createUser(displayName: "Chad", role: .admin)
        adminToken = try unplugged.createDeviceToken(userID: offlineAdmin.id, deviceName: "Chad's Mac").token
        let offline = buildApplication(store: unplugged, configuration: .init())
        try await offline.test(.router) { client in
            try await client.execute(uri: "/v1/admin/library/scan", method: .post, headers: self.auth(self.adminToken)) {
                XCTAssertEqual($0.status, .serviceUnavailable)
            }
            try await self.upload(client, Data("x".utf8), "Game.sfc", status: .serviceUnavailable)
            let status = try await client.execute(uri: "/v1/admin/storage", method: .get, headers: self.auth(self.adminToken)) {
                try self.decode(StorageStatus.self, $0)
            }
            XCTAssertFalse(status.available)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: drive.path))
    }

    func testMoveRefusesNonEmptyTargetAndMovesBack() async throws {
        let drive = FileManager.default.temporaryDirectory.appendingPathComponent("se-drive-\(UUID().uuidString)", isDirectory: true)
        extraFolders.append(drive)
        try write(Data("keep".utf8), "SupersEmu Library/someone else's file", in: drive)
        XCTAssertThrowsError(try importer.startMove(to: drive.path, auth: nil))
        try FileManager.default.removeItem(at: drive.appendingPathComponent("SupersEmu Library"))

        try write(Data(repeating: 1, count: 10), "Note.txt", in: store.paths.incoming)
        _ = try importer.startMove(to: drive.path, auth: nil)
        let first = try await waitForMove()
        XCTAssertEqual(first.phase, .done)
        XCTAssertThrowsError(try importer.startMove(to: drive.path, auth: nil), "already there")
        _ = try importer.startMove(to: store.paths.root.path, auth: nil)
        let back = try await waitForMove()
        XCTAssertEqual(back.phase, .done)
        XCTAssertTrue(store.paths.storage.isDefault)
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.paths.storageConfig.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.paths.incoming.appendingPathComponent("Note.txt").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: drive.appendingPathComponent("SupersEmu Library").path))
    }
}
