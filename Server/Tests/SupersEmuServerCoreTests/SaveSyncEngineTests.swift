import Foundation
import GRDB
import Hummingbird
import HummingbirdTesting
import SupersEmuKit
@testable import SupersEmuServerCore
import XCTest

/// Mutable provider so tests can go offline/online and switch servers.
final class TestProvider: SaveSyncServerProvider, @unchecked Sendable {
    private let lock = NSLock()
    private var client: APIClient?
    init(_ client: APIClient?) { self.client = client }
    func set(_ client: APIClient?) { lock.withLock { self.client = client } }
    func currentClient() async -> APIClient? { lock.withLock { client } }
}

/// Client sync engine against a real HTTP server: an in-process live Hummingbird server by default, or an external
/// `swift run supersemu-server` when SUPERSEMU_TEST_SERVER_URL and SUPERSEMU_TEST_DATA_DIR are set.
final class SaveSyncEngineTests: XCTestCase {
    var store: ServerStore!
    var chad: UserInfo!
    var scratch: URL!
    // Unique per test so runs against a shared external server stay independent.
    let game = (UUID().uuidString + UUID().uuidString).replacingOccurrences(of: "-", with: "").lowercased()
    let core = SaveCore(id: "Snes9x", version: "1.62.3")

    override func setUp() async throws {
        scratch = FileManager.default.temporaryDirectory.appendingPathComponent("save-sync-\(UUID().uuidString)", isDirectory: true)
        if let dataDir = ProcessInfo.processInfo.environment["SUPERSEMU_TEST_DATA_DIR"] {
            store = try ServerStore.open(paths: ServerPaths(root: URL(fileURLWithPath: dataDir, isDirectory: true)))
        } else {
            store = try ServerStore.inMemory()
        }
        chad = try store.adminUser() ?? store.createUser(displayName: "Chad", role: .admin)
    }

    /// Runs `body` with the base URL of a real server.
    func withServer(_ body: @escaping @Sendable (URL) async throws -> Void) async throws {
        if let external = ProcessInfo.processInfo.environment["SUPERSEMU_TEST_SERVER_URL"], let url = URL(string: external) {
            try await body(url)
            return
        }
        let app = buildApplication(store: store, configuration: .init())
        try await app.test(.live) { client in
            try await body(URL(string: "http://localhost:\(client.port!)")!)
        }
    }

    struct Device {
        let name: String
        let provider: TestProvider
        let engine: SaveSyncEngine
        let saves: URL
        func file(_ line: SaveLine, requiresMatchingCore: Bool = true, core: SaveCore? = SaveCore(id: "Snes9x", version: "1.62.3")) -> LocalSaveFile {
            LocalSaveFile(line: line, url: saves.appendingPathComponent(line.key.replacingOccurrences(of: "/", with: "_")),
                          core: core, requiresMatchingCore: requiresMatchingCore)
        }
        func write(_ line: SaveLine, _ text: String) throws {
            try Data(text.utf8).write(to: file(line).url)
        }
        func read(_ line: SaveLine) -> String? { (try? Data(contentsOf: file(line).url)).map { String(decoding: $0, as: UTF8.self) } }
    }

    func device(_ name: String, server: URL, gameGame: String? = nil) throws -> Device {
        let token = try store.createDeviceToken(userID: chad.id, deviceName: name).token
        let root = scratch.appendingPathComponent(name.replacingOccurrences(of: " ", with: "-"), isDirectory: true)
        let saves = root.appendingPathComponent("saves", isDirectory: true)
        try FileManager.default.createDirectory(at: saves, withIntermediateDirectories: true)
        let provider = TestProvider(APIClient(baseURL: server, token: token))
        return Device(name: name, provider: provider,
                      engine: SaveSyncEngine(directory: root.appendingPathComponent("sync", isDirectory: true), provider: provider), saves: saves)
    }

    var auto: SaveLine { SaveLine(gameID: game, kind: .auto) }
    var native: SaveLine { SaveLine(gameID: game, kind: .native) }

    func testLocalOnlyModeDoesNothing() async throws {
        let root = scratch.appendingPathComponent("local", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let engine = SaveSyncEngine(directory: root, provider: TestProvider(nil))
        let file = LocalSaveFile(line: auto, url: root.appendingPathComponent("auto.state"), core: core, requiresMatchingCore: true)
        try Data("local".utf8).write(to: file.url)
        let queued = await engine.enqueueUpload(file)
        XCTAssertFalse(queued)
        let outcomes = await engine.prepare([file])
        XCTAssertEqual(outcomes[auto.key], .localOnly)
        let pending = await engine.pendingCount
        XCTAssertEqual(pending, 0)
        XCTAssertEqual(try String(contentsOf: file.url, encoding: .utf8), "local")
    }

    func testUploadThenContinueOnAnotherDevice() async throws {
        try await withServer { server in
            let phone = try self.device("Chad's iPhone", server: server)
            let mac = try self.device("Chad's Mac", server: server)
            try phone.write(self.auto, "level-3")
            try phone.write(self.native, "sram-3")
            let queuedAuto = await phone.engine.enqueueUpload(phone.file(self.auto))
            let queuedNative = await phone.engine.enqueueUpload(phone.file(self.native, requiresMatchingCore: false))
            XCTAssertTrue(queuedAuto && queuedNative)
            let report = await phone.engine.flush()
            XCTAssertEqual(report.uploaded, 2)
            XCTAssertEqual(report.remaining, 0)
            let phoneStatus = await phone.engine.status(of: self.auto)
            XCTAssertEqual(phoneStatus, .synced)
            // Unchanged bytes aren't uploaded again.
            let requeued = await phone.engine.enqueueUpload(phone.file(self.auto))
            XCTAssertFalse(requeued)

            let outcomes = await mac.engine.prepare([mac.file(self.auto), mac.file(self.native, requiresMatchingCore: false)])
            guard case .downloaded(let revision) = outcomes[self.auto.key] else { return XCTFail("\(String(describing: outcomes))") }
            XCTAssertEqual(revision.deviceName, "Chad's iPhone")
            XCTAssertEqual(mac.read(self.auto), "level-3")
            XCTAssertEqual(mac.read(self.native), "sram-3")

            // The Mac plays on; the phone fast-forwards on its next launch.
            try mac.write(self.auto, "level-4")
            await mac.engine.enqueueUpload(mac.file(self.auto))
            await mac.engine.flush()
            let back = await phone.engine.prepare([phone.file(self.auto)])
            guard case .downloaded = back[self.auto.key] else { return XCTFail("\(back)") }
            XCTAssertEqual(phone.read(self.auto), "level-4")
        }
    }

    func testOfflineQueueIsPersistedAndRetried() async throws {
        try await withServer { server in
            let phone = try self.device("Chad's iPhone", server: server)
            let online = await phone.provider.currentClient()
            // Signed in, but the server is unreachable while the device is away from home.
            phone.provider.set(APIClient(baseURL: URL(string: "http://127.0.0.1:9")!, token: online!.token))
            try phone.write(self.auto, "offline-1")
            await phone.engine.enqueueUpload(phone.file(self.auto))
            try phone.write(self.auto, "offline-2")
            await phone.engine.enqueueUpload(phone.file(self.auto))
            let report = await phone.engine.flush()
            XCTAssertNotNil(report.offlineError)
            XCTAssertEqual(report.remaining, 1, "queued copies of the same line coalesce")
            let status = await phone.engine.status(of: self.auto)
            XCTAssertEqual(status, .waitingToUpload, "offline isn't reported as a failed upload")

            // Relaunch: a new engine reads the queue from disk, then the server comes back.
            let relaunched = SaveSyncEngine(directory: phone.engine.directory, provider: TestProvider(online))
            let pending = await relaunched.pendingCount
            XCTAssertEqual(pending, 1)
            let retried = await relaunched.flush()
            XCTAssertEqual(retried.uploaded, 1)
            XCTAssertEqual(retried.remaining, 0)
            let revisions = try await online!.saves(gameID: self.game).revisions
            XCTAssertEqual(revisions.map(\.sha256), [SaveSyncEngine.sha256(Data("offline-2".utf8))])
        }
    }

    func testDivergedDevicesSurfaceConflictAndKeepBothCopies() async throws {
        try await withServer { server in
            let phone = try self.device("Chad's iPhone", server: server)
            let mac = try self.device("Chad's Mac", server: server)
            try phone.write(self.auto, "shared")
            await phone.engine.enqueueUpload(phone.file(self.auto))
            await phone.engine.flush()
            _ = await mac.engine.prepare([mac.file(self.auto)])

            // Both play from the shared save; the phone uploads first.
            try phone.write(self.auto, "phone-progress")
            await phone.engine.enqueueUpload(phone.file(self.auto))
            await phone.engine.flush()
            try mac.write(self.auto, "mac-progress")

            let outcomes = await mac.engine.prepare([mac.file(self.auto)])
            guard case .conflict(let conflict) = outcomes[self.auto.key] else { return XCTFail("\(outcomes)") }
            XCTAssertEqual(conflict.message, "A newer save from Chad's iPhone is available")
            XCTAssertEqual(mac.read(self.auto), "mac-progress", "never silently overwritten")
            let macStatus = await mac.engine.status(of: self.auto)
            XCTAssertEqual(macStatus, .conflict)

            let client = await mac.provider.currentClient()!
            var shas = Set(try await client.saves(gameID: self.game).revisions.map(\.sha256))
            XCTAssertTrue(shas.isSuperset(of: ["phone-progress", "mac-progress"].map { SaveSyncEngine.sha256(Data($0.utf8)) }),
                          "the Mac's copy was kept on the server as a branch")

            try await mac.engine.resolve(conflict, choice: .useRemote, file: mac.file(self.auto))
            XCTAssertEqual(mac.read(self.auto), "phone-progress")
            let resolved = await mac.engine.status(of: self.auto)
            XCTAssertEqual(resolved, .synced)
            shas = Set(try await client.saves(gameID: self.game).revisions.map(\.sha256))
            XCTAssertTrue(shas.contains(SaveSyncEngine.sha256(Data("mac-progress".utf8))))
        }
    }

    func testKeepLocalMakesThisDeviceNewest() async throws {
        try await withServer { server in
            let phone = try self.device("Chad's iPhone", server: server)
            let mac = try self.device("Chad's Mac", server: server)
            let slot = SaveLine(gameID: self.game, kind: .manual, slot: "slot1")
            try phone.write(slot, "phone-slot")
            await phone.engine.enqueueUpload(phone.file(slot))
            await phone.engine.flush()
            try mac.write(slot, "mac-slot")  // made before ever syncing

            let outcomes = await mac.engine.prepare([mac.file(slot)])
            guard case .conflict(let conflict) = outcomes[slot.key] else { return XCTFail("\(outcomes)") }
            try await mac.engine.resolve(conflict, choice: .keepLocal, file: mac.file(slot))
            XCTAssertEqual(mac.read(slot), "mac-slot")
            try mac.write(slot, "mac-slot-2")
            await mac.engine.enqueueUpload(mac.file(slot))
            await mac.engine.flush()

            let after = await phone.engine.prepare([phone.file(slot)])
            guard case .downloaded = after[slot.key] else { return XCTFail("\(after)") }
            XCTAssertEqual(phone.read(slot), "mac-slot-2")
        }
    }

    func testManualSlotsSyncIndependently() async throws {
        try await withServer { server in
            let phone = try self.device("Chad's iPhone", server: server)
            let mac = try self.device("Chad's Mac", server: server)
            let slot1 = SaveLine(gameID: self.game, kind: .manual, slot: "slot1")
            let slot2 = SaveLine(gameID: self.game, kind: .manual, slot: "slot2")
            let slot3 = SaveLine(gameID: self.game, kind: .manual, slot: "slot3")
            try phone.write(slot1, "phone-slot-1")
            try phone.write(slot3, "phone-slot-3")
            await phone.engine.enqueueUpload(phone.file(slot1))
            await phone.engine.enqueueUpload(phone.file(slot3))
            let report = await phone.engine.flush()
            XCTAssertEqual(report.uploaded, 2)

            let firstPull = await mac.engine.prepare([mac.file(slot1), mac.file(slot2), mac.file(slot3)])
            guard case .downloaded = firstPull[slot1.key] else { return XCTFail("\(firstPull)") }
            XCTAssertEqual(firstPull[slot2.key], .upToDate)
            guard case .downloaded = firstPull[slot3.key] else { return XCTFail("\(firstPull)") }
            XCTAssertEqual(mac.read(slot1), "phone-slot-1")
            XCTAssertNil(mac.read(slot2))
            XCTAssertEqual(mac.read(slot3), "phone-slot-3")

            try phone.write(slot3, "phone-slot-3-next")
            await phone.engine.enqueueUpload(phone.file(slot3))
            await phone.engine.flush()
            let laterPull = await mac.engine.prepare([mac.file(slot1), mac.file(slot2), mac.file(slot3)])
            XCTAssertEqual(laterPull[slot1.key], .upToDate)
            XCTAssertEqual(laterPull[slot2.key], .upToDate)
            guard case .downloaded = laterPull[slot3.key] else { return XCTFail("\(laterPull)") }
            XCTAssertEqual(mac.read(slot1), "phone-slot-1")
            XCTAssertNil(mac.read(slot2))
            XCTAssertEqual(mac.read(slot3), "phone-slot-3-next")
        }
    }

    func testDiscardLocalSuppressesRestoreUntilServerHeadMoves() async throws {
        try await withServer { server in
            let phone = try self.device("Chad's iPhone", server: server)
            let mac = try self.device("Chad's Mac", server: server)
            let slot2 = SaveLine(gameID: self.game, kind: .manual, slot: "slot2")
            try phone.write(slot2, "phone-slot-2")
            await phone.engine.enqueueUpload(phone.file(slot2))
            await phone.engine.flush()
            try FileManager.default.removeItem(at: phone.file(slot2).url)
            await phone.engine.discardLocal(slot2)

            let afterDelete = await phone.engine.prepare([phone.file(slot2)])
            XCTAssertEqual(afterDelete[slot2.key], .upToDate)
            XCTAssertNil(phone.read(slot2))

            let macPull = await mac.engine.prepare([mac.file(slot2)])
            guard case .downloaded = macPull[slot2.key] else { return XCTFail("\(macPull)") }
            try mac.write(slot2, "mac-slot-2-new")
            await mac.engine.enqueueUpload(mac.file(slot2))
            await mac.engine.flush()

            let afterNewRemote = await phone.engine.prepare([phone.file(slot2)])
            guard case .downloaded = afterNewRemote[slot2.key] else { return XCTFail("\(afterNewRemote)") }
            XCTAssertEqual(phone.read(slot2), "mac-slot-2-new")
        }
    }

    func testEnqueueAfterDiscardKeepsNewUploadPending() async throws {
        try await withServer { server in
            let phone = try self.device("Chad's iPhone", server: server)
            let slot2 = SaveLine(gameID: self.game, kind: .manual, slot: "slot2")
            let file = phone.file(slot2)
            try phone.write(slot2, "old-slot-2")
            await phone.engine.enqueueUpload(file)
            let initial = await phone.engine.flush()
            XCTAssertEqual(initial.uploaded, 1)

            try FileManager.default.removeItem(at: file.url)
            await phone.engine.discardLocal(slot2)
            try phone.write(slot2, "new-slot-2")

            let queued = await phone.engine.enqueueUpload(file)
            XCTAssertTrue(queued)
            let pending = await phone.engine.pendingCount
            XCTAssertEqual(pending, 1)
            let report = await phone.engine.flush()
            XCTAssertEqual(report.uploaded, 1)
            XCTAssertEqual(report.remaining, 0)

            let client = await phone.provider.currentClient()!
            let revisions = try await client.saves(gameID: self.game).revisions
            let newHash = SaveSyncEngine.sha256(Data("new-slot-2".utf8))
            XCTAssertTrue(revisions.contains { $0.sha256 == newHash && $0.isHead == true })
        }
    }

    func testOfflinePlayThenBranchedUploadIsReported() async throws {
        try await withServer { server in
            let phone = try self.device("Chad's iPhone", server: server)
            let mac = try self.device("Chad's Mac", server: server)
            try phone.write(self.native, "sram-1")
            await phone.engine.enqueueUpload(phone.file(self.native, requiresMatchingCore: false))
            await phone.engine.flush()
            _ = await mac.engine.prepare([mac.file(self.native, requiresMatchingCore: false)])
            try phone.write(self.native, "sram-phone")
            await phone.engine.enqueueUpload(phone.file(self.native, requiresMatchingCore: false))
            await phone.engine.flush()

            // The Mac launched offline (no pull), then uploads on top of its stale base.
            try mac.write(self.native, "sram-mac")
            await mac.engine.enqueueUpload(mac.file(self.native, requiresMatchingCore: false))
            await mac.engine.flush()
            let conflict = await mac.engine.conflict(for: self.native)
            XCTAssertEqual(conflict?.remote.deviceName, "Chad's iPhone")
            let outcomes = await mac.engine.prepare([mac.file(self.native, requiresMatchingCore: false)])
            guard case .conflict = outcomes[self.native.key] else { return XCTFail("\(outcomes)") }

            // The Mac's stale upload is only a branch copy: the phone isn't bothered, and choosing the newer save
            // on the Mac doesn't bother the phone either.
            let phoneOutcomes = await phone.engine.prepare([phone.file(self.native, requiresMatchingCore: false)])
            XCTAssertEqual(phoneOutcomes[self.native.key], .upToDate)
            let client = await mac.provider.currentClient()!
            let revisions = try await client.saves(gameID: self.game).revisions
            XCTAssertEqual(revisions.filter(\.isHead).map(\.sha256), [SaveSyncEngine.sha256(Data("sram-phone".utf8))])
            XCTAssertTrue(revisions.contains { $0.sha256 == SaveSyncEngine.sha256(Data("sram-mac".utf8)) && $0.isBranchCopy == true })
            guard case .conflict(let macConflict) = outcomes[self.native.key] else { return XCTFail() }
            try await mac.engine.resolve(macConflict, choice: .useRemote, file: mac.file(self.native, requiresMatchingCore: false))
            XCTAssertEqual(mac.read(self.native), "sram-phone")
            let phoneAfter = await phone.engine.prepare([phone.file(self.native, requiresMatchingCore: false)])
            XCTAssertEqual(phoneAfter[self.native.key], .upToDate)
            XCTAssertEqual(phone.read(self.native), "sram-phone")
        }
    }

    func testN64StatesMoveBetweenRendererBuilds() async throws {
        // The same Mupen64Plus-Next commit reports "-GLES3" on iPhone/iPad and "-OpenGL" on the Mac; the state is the same.
        try await withServer { server in
            let phone = try self.device("Chad's iPhone", server: server)
            let mac = try self.device("Chad's Mac", server: server)
            let iOSCore = SaveCore(id: "mupen64plus_next", version: "3.0-GLES3 git (12edd2c)")
            let macCore = SaveCore(id: "mupen64plus_next", version: "3.0-OpenGL git (12edd2c)")
            let slot = SaveLine(gameID: self.game, kind: .manual, slot: "slot1")
            try phone.write(self.auto, "dk64-auto")
            try phone.write(slot, "dk64-slot1")
            await phone.engine.enqueueUpload(phone.file(self.auto, core: iOSCore))
            await phone.engine.enqueueUpload(phone.file(slot, core: iOSCore))
            await phone.engine.flush()

            let outcomes = await mac.engine.prepare([mac.file(self.auto, core: macCore), mac.file(slot, core: macCore)])
            guard case .downloaded = outcomes[self.auto.key] else { return XCTFail("\(outcomes)") }
            guard case .downloaded = outcomes[slot.key] else { return XCTFail("\(outcomes)") }
            XCTAssertEqual(mac.read(self.auto), "dk64-auto")
            XCTAssertEqual(mac.read(slot), "dk64-slot1")

            // A different core commit is still a different state format.
            let otherCommit = SaveCore(id: "mupen64plus_next", version: "3.0-OpenGL git (abc1234)")
            try phone.write(self.auto, "dk64-auto-2")
            await phone.engine.enqueueUpload(phone.file(self.auto, core: iOSCore))
            await phone.engine.flush()
            let blocked = await mac.engine.prepare([mac.file(self.auto, core: otherCommit)])
            guard case .incompatible = blocked[self.auto.key] else { return XCTFail("\(blocked)") }
        }
    }

    func testIncompatibleCoreStateIsNeverLoaded() async throws {
        try await withServer { server in
            let phone = try self.device("Chad's iPhone", server: server)
            let mac = try self.device("Chad's Mac", server: server)
            let newer = SaveCore(id: "Snes9x", version: "1.63")
            try phone.write(self.auto, "state-from-1.63")
            await phone.engine.enqueueUpload(phone.file(self.auto, core: newer))
            await phone.engine.flush()

            let outcomes = await mac.engine.prepare([mac.file(self.auto)])
            guard case .incompatible(let revision) = outcomes[self.auto.key] else { return XCTFail("\(outcomes)") }
            XCTAssertEqual(revision.coreVersion, "1.63")
            XCTAssertNil(mac.read(self.auto))

            // Native SRAM is portable across core versions.
            try phone.write(self.native, "sram")
            await phone.engine.enqueueUpload(phone.file(self.native, requiresMatchingCore: false, core: newer))
            await phone.engine.flush()
            let native = await mac.engine.prepare([mac.file(self.native, requiresMatchingCore: false)])
            guard case .downloaded = native[self.native.key] else { return XCTFail("\(native)") }
        }
    }

    func testAbandonedConflictAsksAgainAndChoosingRemoteDoesNotBotherTheOtherDevice() async throws {
        try await withServer { server in
            let phone = try self.device("Chad's iPhone", server: server)
            let mac = try self.device("Chad's Mac", server: server)
            try phone.write(self.auto, "shared")
            await phone.engine.enqueueUpload(phone.file(self.auto))
            await phone.engine.flush()
            _ = await mac.engine.prepare([mac.file(self.auto)])
            try phone.write(self.auto, "phone-progress")
            await phone.engine.enqueueUpload(phone.file(self.auto))
            await phone.engine.flush()
            try mac.write(self.auto, "mac-progress")

            for _ in 0..<2 {
                let outcomes = await mac.engine.prepare([mac.file(self.auto)])
                guard case .conflict = outcomes[self.auto.key] else { return XCTFail("leaving without choosing must ask again: \(outcomes)") }
            }
            let phoneMeanwhile = await phone.engine.prepare([phone.file(self.auto)])
            XCTAssertEqual(phoneMeanwhile[self.auto.key], .upToDate, "the Mac's branch copy is not a newer save")

            guard let conflict = await mac.engine.conflict(for: self.auto) else { return XCTFail("no conflict") }
            try await mac.engine.resolve(conflict, choice: .useRemote, file: mac.file(self.auto))
            let phoneAfter = await phone.engine.prepare([phone.file(self.auto)])
            XCTAssertEqual(phoneAfter[self.auto.key], .upToDate)
            XCTAssertEqual(phone.read(self.auto), "phone-progress")
        }
    }

    func testKeepLocalWithUnchangedBytesMovesTheHead() async throws {
        try await withServer { server in
            let phone = try self.device("Chad's iPhone", server: server)
            let mac = try self.device("Chad's Mac", server: server)
            try phone.write(self.auto, "p")
            await phone.engine.enqueueUpload(phone.file(self.auto))
            await phone.engine.flush()
            _ = await mac.engine.prepare([mac.file(self.auto)])
            try phone.write(self.auto, "x")
            await phone.engine.enqueueUpload(phone.file(self.auto))
            await phone.engine.flush()
            // The Mac uploads on its stale base: kept as a branch copy, and the Mac is asked on next launch.
            try mac.write(self.auto, "y")
            await mac.engine.enqueueUpload(mac.file(self.auto))
            await mac.engine.flush()
            let macOutcomes = await mac.engine.prepare([mac.file(self.auto)])
            guard case .conflict(let conflict) = macOutcomes[self.auto.key] else { return XCTFail("\(macOutcomes)") }
            XCTAssertEqual(conflict.deviceName, "Chad's iPhone")

            // Keep This Device's uploads the same bytes the Mac already sent as a branch copy; it must still become the head.
            try await mac.engine.resolve(conflict, choice: .keepLocal, file: mac.file(self.auto))
            let again = await mac.engine.prepare([mac.file(self.auto)])
            XCTAssertEqual(again[self.auto.key], .upToDate)
            let phoneOutcomes = await phone.engine.prepare([phone.file(self.auto)])
            guard case .downloaded = phoneOutcomes[self.auto.key] else { return XCTFail("\(phoneOutcomes)") }
            XCTAssertEqual(phone.read(self.auto), "y")
        }
    }

    func testMissingLocalSaveIsRestoredFromServer() async throws {
        try await withServer { server in
            let phone = try self.device("Chad's iPhone", server: server)
            try phone.write(self.auto, "level-5")
            await phone.engine.enqueueUpload(phone.file(self.auto))
            await phone.engine.flush()
            let client = await phone.provider.currentClient()!
            let uploadedRevisions = try await client.saves(gameID: self.game).revisions
            let uploadedRevision = try XCTUnwrap(uploadedRevisions.first)
            let createdAt = Date(timeIntervalSince1970: 1_700_000_000)
            try await self.store.db.write { db in
                try db.execute(sql: "UPDATE save_revisions SET created_at = ? WHERE id = ?",
                               arguments: [createdAt, uploadedRevision.id])
            }
            let revisions = try await client.saves(gameID: self.game).revisions
            let revision = try XCTUnwrap(revisions.first { $0.id == uploadedRevision.id })
            XCTAssertEqual(revision.createdAt.timeIntervalSince(createdAt), 0, accuracy: 1)
            try FileManager.default.removeItem(at: phone.file(self.auto).url)
            let outcomes = await phone.engine.prepare([phone.file(self.auto)])
            guard case .downloaded = outcomes[self.auto.key] else { return XCTFail("\(outcomes)") }
            XCTAssertEqual(phone.read(self.auto), "level-5")
            let attributes = try FileManager.default.attributesOfItem(atPath: phone.file(self.auto).url.path)
            let modified = try XCTUnwrap(attributes[.modificationDate] as? Date)
            XCTAssertEqual(modified.timeIntervalSince(revision.createdAt), 0, accuracy: 1)
        }
    }

    func testResetDropsQueuedUploads() async throws {
        try await withServer { server in
            let phone = try self.device("Chad's iPhone", server: server)
            let online = await phone.provider.currentClient()
            phone.provider.set(APIClient(baseURL: URL(string: "http://127.0.0.1:9")!, token: online!.token))
            try phone.write(self.auto, "account-a")
            await phone.engine.enqueueUpload(phone.file(self.auto))
            await phone.engine.flush()
            await phone.engine.reset()
            let pending = await phone.engine.pendingCount
            XCTAssertEqual(pending, 0)
            let relaunched = SaveSyncEngine(directory: phone.engine.directory, provider: TestProvider(online))
            let report = await relaunched.flush()
            XCTAssertEqual(report.uploaded, 0)
            let revisions = try await online!.saves(gameID: self.game).revisions
            XCTAssertTrue(revisions.isEmpty)
        }
    }

}
