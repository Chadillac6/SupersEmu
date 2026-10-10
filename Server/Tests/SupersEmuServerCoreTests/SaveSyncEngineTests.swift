import Foundation
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
            // Signed in, but the server is unreachable (e.g. on cellular without Tailscale).
            phone.provider.set(APIClient(baseURL: URL(string: "http://127.0.0.1:9")!, token: online!.token))
            try phone.write(self.auto, "offline-1")
            await phone.engine.enqueueUpload(phone.file(self.auto))
            try phone.write(self.auto, "offline-2")
            await phone.engine.enqueueUpload(phone.file(self.auto))
            let report = await phone.engine.flush()
            XCTAssertNotNil(report.offlineError)
            XCTAssertEqual(report.remaining, 1, "queued copies of the same line coalesce")
            let status = await phone.engine.status(of: self.auto)
            guard case .failed = status else { return XCTFail("\(status)") }

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

            // The phone sees the Mac's branch as a newer save too.
            let phoneOutcomes = await phone.engine.prepare([phone.file(self.native, requiresMatchingCore: false)])
            guard case .conflict(let phoneConflict) = phoneOutcomes[self.native.key] else { return XCTFail("\(phoneOutcomes)") }
            XCTAssertEqual(phoneConflict.deviceName, "Chad's Mac")
            XCTAssertEqual(phone.read(self.native), "sram-phone")
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
            // The Mac uploads on its stale base, so its branch becomes the head.
            try mac.write(self.auto, "y")
            await mac.engine.enqueueUpload(mac.file(self.auto))
            await mac.engine.flush()

            let outcomes = await phone.engine.prepare([phone.file(self.auto)])
            guard case .conflict(let conflict) = outcomes[self.auto.key] else { return XCTFail("\(outcomes)") }
            XCTAssertEqual(conflict.deviceName, "Chad's Mac")
            try await phone.engine.resolve(conflict, choice: .keepLocal, file: phone.file(self.auto))
            let again = await phone.engine.prepare([phone.file(self.auto)])
            XCTAssertEqual(again[self.auto.key], .upToDate)

            let macOutcomes = await mac.engine.prepare([mac.file(self.auto)])
            guard case .downloaded = macOutcomes[self.auto.key] else { return XCTFail("\(macOutcomes)") }
            XCTAssertEqual(mac.read(self.auto), "x")
        }
    }
}
