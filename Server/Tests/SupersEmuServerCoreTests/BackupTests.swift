import Foundation
import GRDB
import Hummingbird
import HummingbirdTesting
import SupersEmuKit
@testable import SupersEmuServerCore
import XCTest

final class BackupTests: XCTestCase {
    var scratch: URL!
    var store: ServerStore!
    var admin: UserInfo!

    override func setUp() async throws {
        scratch = FileManager.default.temporaryDirectory.appendingPathComponent("backups-\(UUID().uuidString)", isDirectory: true)
        store = try ServerStore.open(paths: ServerPaths(root: scratch.appendingPathComponent("data", isDirectory: true)))
        admin = try store.createUser(displayName: "Chad", role: .admin)
        try await store.backups.updateConfig(.init(destination: scratch.appendingPathComponent("drive").path))
    }

    override func tearDown() async throws {
        try? store?.close()
        try? FileManager.default.removeItem(at: scratch)
    }

    func gameCount(_ store: ServerStore) throws -> Int {
        try store.db.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM games") ?? 0 }
    }

    func addGame(_ id: String) throws {
        try store.db.write { try $0.execute(sql: "INSERT INTO games (id, title, system, created_at) VALUES (?, ?, 'snes', ?)", arguments: [id, id, Date()]) }
    }

    func write(_ text: String, _ relative: String) throws {
        let url = store.paths.root.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    func read(_ relative: String) -> String? {
        (try? Data(contentsOf: store.paths.root.appendingPathComponent(relative))).map { String(decoding: $0, as: UTF8.self) }
    }

    func testBackupRestoreRoundTrip() async throws {
        try addGame("g1")
        try write("save-v1", "users/u1/saves/rev1")
        try write("rom", "games/snes/game.sfc")
        try write("{\"theme\":\"dark\"}", "settings.json")
        let backup = try await store.backups.create(now: Date(timeIntervalSince1970: 1_800_000_000))
        XCTAssertFalse(backup.includesROMs)
        let files = try BackupManager.verify(folder: URL(fileURLWithPath: backup.path)).files.map(\.path)
        XCTAssertTrue(files.contains("library.sqlite"))
        XCTAssertTrue(files.contains("users/u1/saves/rev1"))
        XCTAssertTrue(files.contains("settings.json"))
        XCTAssertFalse(files.contains { $0.hasPrefix("games/") }, "ROMs are left out by default")

        // Changes after the backup...
        try addGame("g2")
        try write("save-v2", "users/u1/saves/rev1")
        try write("save-new", "users/u1/saves/rev2")
        try write("rom-v2", "games/snes/game.sfc")
        XCTAssertEqual(try gameCount(store), 2)

        // ...are undone by a restore, except ROMs, which the backup doesn't have.
        let paths = store.paths
        try store.close()
        let record = try BackupManager.applyRestore(folder: URL(fileURLWithPath: backup.path), to: paths)
        store = try ServerStore.open(paths: paths)
        XCTAssertEqual(try gameCount(store), 1)
        XCTAssertEqual(read("users/u1/saves/rev1"), "save-v1")
        XCTAssertNil(read("users/u1/saves/rev2"))
        XCTAssertEqual(read("games/snes/game.sfc"), "rom-v2")
        XCTAssertEqual(read("settings.json"), "{\"theme\":\"dark\"}")
        XCTAssertEqual(try store.adminUser()?.id, admin.id)
        XCTAssertEqual(String(decoding: try Data(contentsOf: record.safety.appendingPathComponent("users/u1/saves/rev2")), as: UTF8.self), "save-new")
        // The backup config isn't part of the backup.
        let destination = await store.backups.config().destination
        XCTAssertEqual(destination, scratch.appendingPathComponent("drive").path)
    }

    func testRestoreChangesLibraryRevisionEpoch() async throws {
        try addGame("before-restore")
        let backup = try await store.backups.create()
        let backupRevision = try store.libraryRevision()
        try addGame("after-backup")
        let changedRevision = try store.libraryRevision()
        let paths = store.paths
        try store.close()

        _ = try BackupManager.applyRestore(folder: URL(fileURLWithPath: backup.path), to: paths)
        store = try ServerStore.open(paths: paths)

        let restoredRevision = try store.libraryRevision()
        XCTAssertNotEqual(restoredRevision, backupRevision)
        XCTAssertNotEqual(restoredRevision, changedRevision)
    }

    func testRestoreReplacesSettingsAddedAfterTheBackup() async throws {
        let backup = try await store.backups.create()
        try write("{}", "options.json")
        let paths = store.paths
        try store.close()
        let record = try BackupManager.applyRestore(folder: URL(fileURLWithPath: backup.path), to: paths)
        store = try ServerStore.open(paths: paths)
        XCTAssertNil(read("options.json"))
        XCTAssertEqual(String(decoding: try Data(contentsOf: record.safety.appendingPathComponent("options.json")), as: UTF8.self), "{}")
    }

    func testSecondRestoreKeepsTheFirstRestoresCopy() async throws {
        let backup = try await store.backups.create()
        try write("wednesday", "users/u1/saves/rev1")
        let paths = store.paths
        try store.close()
        let first = try BackupManager.applyRestore(folder: URL(fileURLWithPath: backup.path), to: paths)
        store = try ServerStore.open(paths: paths)
        try write("thursday", "users/u1/saves/rev1")
        try store.close()
        let second = try BackupManager.applyRestore(folder: URL(fileURLWithPath: backup.path), to: paths)
        store = try ServerStore.open(paths: paths)
        XCTAssertNotEqual(first.safety, second.safety)
        XCTAssertEqual(String(decoding: try Data(contentsOf: first.safety.appendingPathComponent("users/u1/saves/rev1")), as: UTF8.self), "wednesday")
        XCTAssertEqual(String(decoding: try Data(contentsOf: second.safety.appendingPathComponent("users/u1/saves/rev1")), as: UTF8.self), "thursday")
    }

    func testBackupAndRestoreFollowMovedLibrary() async throws {
        let paths = store.paths
        let library = scratch.appendingPathComponent("external/SupersEmu Library", isDirectory: true)
        try FileManager.default.createDirectory(at: library, withIntermediateDirectories: true)
        try paths.storage.switchTo(library, config: paths.storageConfig, dataRoot: paths.root)
        func put(_ text: String, _ relative: String) throws {
            let url = library.appendingPathComponent(relative)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(text.utf8).write(to: url)
        }
        try put("art-v1", "artwork/g1/cover.png")
        try put("rom-v1", "games/snes/game.sfc")
        let backup = try await store.backups.create(includeROMs: true)
        let files = try BackupManager.verify(folder: URL(fileURLWithPath: backup.path)).files.map(\.path)
        XCTAssertTrue(files.contains("artwork/g1/cover.png"))
        XCTAssertTrue(files.contains("games/snes/game.sfc"))

        try put("art-v2", "artwork/g1/cover.png")
        try put("rom-v2", "games/snes/game.sfc")
        try store.close()
        try BackupManager.applyRestore(folder: URL(fileURLWithPath: backup.path), to: paths)
        store = try ServerStore.open(paths: paths)
        XCTAssertEqual(paths.libraryRoot.standardizedFileURL.path, library.standardizedFileURL.path)
        XCTAssertEqual(String(decoding: try Data(contentsOf: library.appendingPathComponent("artwork/g1/cover.png")), as: UTF8.self), "art-v1")
        XCTAssertEqual(String(decoding: try Data(contentsOf: library.appendingPathComponent("games/snes/game.sfc")), as: UTF8.self), "rom-v1")
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.root.appendingPathComponent("artwork/g1/cover.png").path))
    }

    func testBackupFolderIsPrivate() async throws {
        let backup = try await store.backups.create()
        let mode = try FileManager.default.attributesOfItem(atPath: backup.path)[.posixPermissions] as? Int
        XCTAssertEqual(mode, 0o700, "it holds the admin token and TLS key")
    }

    func testDestinationInsideDataIsRefused() async throws {
        let root = store.paths.root
        for inside in [root.path, root.appendingPathComponent("users/backups").path, root.appendingPathComponent("tls").path] {
            do {
                try await store.backups.updateConfig(.init(destination: inside))
                XCTFail("\(inside) accepted")
            } catch BackupError.invalidConfig {}
        }
        try await store.backups.updateConfig(.init(destination: root.appendingPathComponent("Backups/nightly").path))
        let backup = try await store.backups.create()
        XCTAssertTrue(backup.path.hasPrefix(root.appendingPathComponent("Backups").path))
    }

    func testIncludeROMsCopiesGames() async throws {
        try write("rom", "games/snes/game.sfc")
        try write("bios", "bios/ps1/scph5501.bin")
        let backup = try await store.backups.create(includeROMs: true)
        let files = try BackupManager.verify(folder: URL(fileURLWithPath: backup.path)).files.map(\.path)
        XCTAssertTrue(backup.includesROMs)
        XCTAssertTrue(files.contains("games/snes/game.sfc"))
        XCTAssertTrue(files.contains("bios/ps1/scph5501.bin"))
    }

    func testRetentionKeepsNewestN() async throws {
        try await store.backups.updateConfig(.init(keep: 2))
        var ids: [String] = []
        for day in 0..<4 {
            ids.append(try await store.backups.create(now: Date(timeIntervalSince1970: 1_800_000_000 + Double(day) * 86_400)).id)
        }
        let kept = await store.backups.list().map(\.id)
        XCTAssertEqual(kept, [ids[3], ids[2]])
        let folders = try FileManager.default.contentsOfDirectory(atPath: scratch.appendingPathComponent("drive").path)
        XCTAssertEqual(folders.sorted(), kept.map { "SupersEmu-\($0)" }.sorted())
    }

    func testCorruptedBackupsAreRejected() async throws {
        try write("save", "users/u1/saves/rev1")
        let tampered = try await store.backups.create(now: Date(timeIntervalSince1970: 1_800_000_000))
        try Data("tampered".utf8).write(to: URL(fileURLWithPath: tampered.path).appendingPathComponent("users/u1/saves/rev1"))
        XCTAssertThrowsError(try BackupManager.verify(folder: URL(fileURLWithPath: tampered.path))) {
            XCTAssertEqual($0 as? BackupError, .corrupted("users/u1/saves/rev1 checksum mismatch"))
        }

        let missing = try await store.backups.create(now: Date(timeIntervalSince1970: 1_800_000_100))
        try FileManager.default.removeItem(at: URL(fileURLWithPath: missing.path).appendingPathComponent("users/u1/saves/rev1"))
        XCTAssertThrowsError(try BackupManager.verify(folder: URL(fileURLWithPath: missing.path)))

        // A database that's damaged consistently with its manifest still fails integrity_check.
        let damaged = try await store.backups.create(now: Date(timeIntervalSince1970: 1_800_000_200))
        let folder = URL(fileURLWithPath: damaged.path)
        let dbURL = folder.appendingPathComponent("library.sqlite")
        var bytes = try Data(contentsOf: dbURL)
        for offset in stride(from: 4096 + 100, to: min(bytes.count, 4096 * 3), by: 7) { bytes[offset] = 0xFF }
        try bytes.write(to: dbURL)
        var manifest = try BackupManager.readManifest(folder)
        manifest.files = try BackupManager.hashFiles(in: folder)
        try BackupManager.encoder.encode(manifest).write(to: folder.appendingPathComponent("manifest.json"))
        XCTAssertThrowsError(try BackupManager.verify(folder: folder)) {
            guard case .corrupted = $0 as? BackupError else { return XCTFail("\($0)") }
        }

        // Restoring a corrupted backup leaves the live data untouched.
        try addGame("live")
        let paths = store.paths
        try store.close()
        XCTAssertThrowsError(try BackupManager.applyRestore(folder: URL(fileURLWithPath: tampered.path), to: paths))
        store = try ServerStore.open(paths: paths)
        XCTAssertEqual(try gameCount(store), 1)
        XCTAssertEqual(read("users/u1/saves/rev1"), "save")
    }

    func testUnmountedDriveFailsAndIsReported() async throws {
        try await store.backups.updateConfig(.init(destination: "/Volumes/SupersEmu-Test-Drive-\(UUID().uuidString)/Backups"))
        do {
            _ = try await store.backups.create()
            XCTFail("expected failure")
        } catch let error as BackupError {
            guard case .destinationUnavailable = error else { return XCTFail("\(error)") }
        }
        let overview = await store.backups.overview()
        XCTAssertFalse(overview.destinationAvailable)
        XCTAssertEqual(overview.last?.ok, false)
        XCTAssertNil(overview.lastSuccessAt)
    }

    func testScheduleRunsDailyAndCatchesUp() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let config = BackupConfig(hour: 3)
        let morning = Date(timeIntervalSince1970: 1_800_000_000) // 2027-01-15 08:00 UTC
        let slot = calendar.date(bySettingHour: 3, minute: 0, second: 0, of: morning)!
        // Never ran (or the Mac was off at 3:00): run now.
        XCTAssertEqual(BackupManager.nextRun(config: config, lastAttempt: nil, now: morning, calendar: calendar), morning)
        // Ran at today's slot: tomorrow at 3:00.
        XCTAssertEqual(BackupManager.nextRun(config: config, lastAttempt: slot.addingTimeInterval(5), now: morning, calendar: calendar),
                       slot.addingTimeInterval(86_400))
        // Before today's slot, after yesterday's run: today at 3:00.
        let night = slot.addingTimeInterval(-3600)
        XCTAssertEqual(BackupManager.nextRun(config: config, lastAttempt: slot.addingTimeInterval(-86_000), now: night, calendar: calendar), slot)
        XCTAssertNil(BackupManager.nextRun(config: BackupConfig(scheduleEnabled: false), lastAttempt: nil, now: morning, calendar: calendar))
    }

    func testAdminRoutes() async throws {
        let adminToken = try store.createDeviceToken(userID: admin.id, deviceName: "Mac").token
        let player = try store.createUser(displayName: "Kid", role: .player)
        let playerToken = try store.createDeviceToken(userID: player.id, deviceName: "iPad").token
        func headers(_ token: String) -> HTTPFields { [.authorization: "Bearer \(token)", .contentType: "application/json"] }
        let app = buildApplication(store: store, configuration: .init())
        try await app.test(.router) { client in
            try await client.execute(uri: "/v1/admin/backups", method: .post, headers: headers(playerToken)) { XCTAssertEqual($0.status, .forbidden) }
            try await client.execute(uri: "/v1/admin/backups/config", method: .put, headers: headers(adminToken),
                                     body: ByteBuffer(string: #"{"keep":3,"hour":4}"#)) { response in
                XCTAssertEqual(response.status, .ok)
                let config = try SupersEmuJSON.decoder().decode(BackupConfig.self, from: Data(buffer: response.body))
                XCTAssertEqual(config.keep, 3)
                XCTAssertEqual(config.hour, 4)
            }
            try await client.execute(uri: "/v1/admin/backups/config", method: .put, headers: headers(adminToken),
                                     body: ByteBuffer(string: #"{"keep":0}"#)) { XCTAssertEqual($0.status, .badRequest) }
            try await client.execute(uri: "/v1/admin/backups", method: .post, headers: headers(adminToken),
                                     body: ByteBuffer(string: #"{"includeROMs":"yes"}"#)) { XCTAssertEqual($0.status, .badRequest) }
            var id = ""
            try await client.execute(uri: "/v1/admin/backups", method: .post, headers: headers(adminToken), body: ByteBuffer(string: "{}")) { response in
                XCTAssertEqual(response.status, .created)
                id = try SupersEmuJSON.decoder().decode(BackupInfo.self, from: Data(buffer: response.body)).id
            }
            try await client.execute(uri: "/v1/admin/backups", method: .get, headers: headers(adminToken)) { response in
                let overview = try SupersEmuJSON.decoder().decode(BackupOverview.self, from: Data(buffer: response.body))
                XCTAssertEqual(overview.backups.map(\.id), [id])
                XCTAssertEqual(overview.last?.ok, true)
                XCTAssertEqual(overview.last?.trigger, .manual)
            }
            try await client.execute(uri: "/v1/admin/backups/\(id)/verify", method: .post, headers: headers(adminToken)) { XCTAssertEqual($0.status, .ok) }
            try await client.execute(uri: "/v1/admin/backups/nope/verify", method: .post, headers: headers(adminToken)) { XCTAssertEqual($0.status, .notFound) }
            // Without the daemon's run loop there's nothing to stop and restart.
            try await client.execute(uri: "/v1/admin/backups/\(id)/restore", method: .post, headers: headers(adminToken)) { XCTAssertEqual($0.status, .conflict) }
        }
    }

    /// The daemon path: a restore request stops serving, restores and serves again from the restored data.
    func testDaemonRestoresAndServesAgain() async throws {
        try addGame("g1")
        let token = try store.createDeviceToken(userID: admin.id, deviceName: "Mac").token
        let backup = try await store.backups.create()
        try addGame("g2")

        var options = ServerRunOptions()
        options.hostname = "127.0.0.1"
        options.port = Int.random(in: 20_000..<40_000)
        options.insecureHTTP = true
        options.bonjour = false
        let launched = store!
        let server = Task { try await ServerLauncher.run(store: launched, options: options) }
        defer { server.cancel() }
        let client = APIClient(baseURL: URL(string: "http://127.0.0.1:\(options.port)")!, token: token)

        func waitForHealth() async throws {
            for _ in 0..<100 {
                if (try? await client.health()) != nil { return }
                try await Task.sleep(for: .milliseconds(100))
            }
            XCTFail("server didn't come up")
        }
        try await waitForHealth()
        let response = try await client.restoreBackup(backup.id)
        XCTAssertEqual(response.backup.id, backup.id)
        try await Task.sleep(for: .seconds(1))
        try await waitForHealth()
        let reopened = try ServerStore.open(paths: store.paths)
        XCTAssertEqual(try gameCount(reopened), 1)
        try reopened.close()
        store = nil
    }
}
