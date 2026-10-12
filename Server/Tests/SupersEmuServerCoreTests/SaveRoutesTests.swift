import Foundation
import GRDB
import Hummingbird
import HummingbirdTesting
import SupersEmuKit
@testable import SupersEmuServerCore
import XCTest

final class SaveRoutesTests: XCTestCase {
    var store: ServerStore!
    var chad: UserInfo!
    var iPhone: (deviceID: String, token: String)!
    var mac: (deviceID: String, token: String)!
    let game = String(repeating: "ab", count: 32)

    override func setUp() async throws {
        store = try ServerStore.inMemory()
        chad = try store.createUser(displayName: "Chad", role: .admin)
        iPhone = try store.createDeviceToken(userID: chad.id, deviceName: "Chad's iPhone")
        mac = try store.createDeviceToken(userID: chad.id, deviceName: "Chad's Mac")
    }

    func app(_ configuration: SaveConfiguration = .standard) -> some ApplicationProtocol {
        let router = Router(context: SERequestContext.self)
        registerSaveRoutes(router.group("v1").add(middleware: TokenAuthMiddleware(store: store)), store: store, configuration: configuration)
        return Application(router: router)
    }

    func bearer(_ token: String) -> HTTPFields { [.authorization: "Bearer \(token)"] }

    func decode<T: Decodable>(_ type: T.Type, _ response: TestResponse) throws -> T {
        try SupersEmuJSON.decoder().decode(T.self, from: Data(buffer: response.body))
    }

    func upload(_ client: some TestClientProtocol, token: String, kind: SaveKind = .auto, slot: String = "", parent: String? = nil,
                game: String? = nil, core: String = "Snes9x", coreVersion: String = "1.62", ifHead: Bool = false, body: String,
                sha256: String? = nil, expect status: HTTPResponse.Status = .ok) async throws -> SaveUploadResponse? {
        var query = "slot=\(slot)&core=\(core)&coreVersion=\(coreVersion)"
        if let parent { query += "&parent=\(parent)" }
        if let sha256 { query += "&sha256=\(sha256)" }
        if ifHead { query += "&ifHead=1" }
        return try await client.execute(uri: "/v1/saves/\(game ?? self.game)/\(kind.rawValue)?\(query)", method: .put,
                                        headers: bearer(token), body: ByteBuffer(string: body)) { response in
            XCTAssertEqual(response.status, status, String(buffer: response.body))
            return response.status == .ok ? try self.decode(SaveUploadResponse.self, response) : nil
        }
    }

    func list(_ client: some TestClientProtocol, token: String, game: String? = nil) async throws -> [SaveRevision] {
        try await client.execute(uri: "/v1/saves/\(game ?? self.game)", method: .get, headers: bearer(token)) { response in
            XCTAssertEqual(response.status, .ok)
            return try self.decode(SaveListResponse.self, response).revisions
        }
    }

    func testUploadListAndDownloadRoundTrip() async throws {
        try await app().test(.router) { client in
            let first = try await self.upload(client, token: self.iPhone.token, body: "state-1")!
            XCTAssertFalse(first.branched)
            XCTAssertNil(first.revision.parentID)
            XCTAssertEqual(first.revision.sha256, SaveStore.sha256(Data("state-1".utf8)))
            XCTAssertEqual(first.revision.deviceName, "Chad's iPhone")
            XCTAssertTrue(first.revision.isHead)

            let second = try await self.upload(client, token: self.iPhone.token, parent: first.revision.id, body: "state-2")!
            XCTAssertFalse(second.branched)

            let revisions = try await self.list(client, token: self.iPhone.token)
            XCTAssertEqual(revisions.map(\.id), [first.revision.id, second.revision.id])
            XCTAssertEqual(revisions.map(\.isHead), [false, true])

            try await client.execute(uri: "/v1/saves/\(self.game)/revisions/\(first.revision.id)", method: .get,
                                     headers: self.bearer(self.mac.token)) { response in
                XCTAssertEqual(response.status, .ok)
                XCTAssertEqual(String(buffer: response.body), "state-1")
            }
            let stored = self.store.paths.userDirectory(self.chad.id).appendingPathComponent("saves/\(self.game)/\(first.revision.id)")
            XCTAssertEqual(try String(contentsOf: stored, encoding: .utf8), "state-1")
        }
    }

    func testStaleParentBranchesAndNeverOverwrites() async throws {
        try await app().test(.router) { client in
            let base = try await self.upload(client, token: self.iPhone.token, kind: .native, body: "sram-0")!
            let fromMac = try await self.upload(client, token: self.mac.token, kind: .native, parent: base.revision.id, body: "sram-mac")!
            XCTAssertFalse(fromMac.branched)
            // The iPhone never saw the Mac's revision and uploads on top of `base`.
            let fromPhone = try await self.upload(client, token: self.iPhone.token, kind: .native, parent: base.revision.id, body: "sram-phone")!
            XCTAssertTrue(fromPhone.branched)
            XCTAssertEqual(fromPhone.revision.parentID, base.revision.id)

            let revisions = try await self.list(client, token: self.iPhone.token)
            XCTAssertEqual(Set(revisions.map(\.sha256)), Set(["sram-0", "sram-mac", "sram-phone"].map { SaveStore.sha256(Data($0.utf8)) }))
            try await client.execute(uri: "/v1/saves/\(self.game)/revisions/\(fromMac.revision.id)", method: .get,
                                     headers: self.bearer(self.iPhone.token)) { XCTAssertEqual(String(buffer: $0.body), "sram-mac") }

            // An upload with no parent onto an existing line is also a branch.
            let orphan = try await self.upload(client, token: self.mac.token, kind: .native, body: "sram-orphan")!
            XCTAssertTrue(orphan.branched)
        }
    }

    func testRetriedUploadIsIdempotent() async throws {
        try await app().test(.router) { client in
            let first = try await self.upload(client, token: self.iPhone.token, kind: .manual, slot: "slot1", body: "manual")!
            let retry = try await self.upload(client, token: self.iPhone.token, kind: .manual, slot: "slot1", body: "manual")!
            XCTAssertEqual(retry.revision.id, first.revision.id)
            let unchanged = try await self.upload(client, token: self.iPhone.token, kind: .manual, slot: "slot1",
                                                  parent: first.revision.id, body: "manual")!
            XCTAssertEqual(unchanged.revision.id, first.revision.id)
            XCTAssertFalse(unchanged.branched)
            let count = try await self.list(client, token: self.iPhone.token).count
            XCTAssertEqual(count, 1)
            let files = try FileManager.default.contentsOfDirectory(
                atPath: self.store.paths.userDirectory(self.chad.id).appendingPathComponent("saves/\(self.game)").path)
            XCTAssertEqual(files, [first.revision.id])
        }
    }

    func testAutoRetentionKeepsLastNAndNeverPrunesManualOrNative() async throws {
        try await app(.init(autoRevisionsKept: 3)).test(.router) { client in
            var parent: String?
            var autoIDs: [String] = []
            for index in 0..<6 {
                let response = try await self.upload(client, token: self.iPhone.token, parent: parent, body: "auto-\(index)")!
                parent = response.revision.id
                autoIDs.append(response.revision.id)
            }
            var nativeParent: String?
            for index in 0..<5 {
                nativeParent = try await self.upload(client, token: self.iPhone.token, kind: .native, parent: nativeParent, body: "sram-\(index)")!.revision.id
            }
            _ = try await self.upload(client, token: self.iPhone.token, kind: .manual, slot: "slot1", body: "manual-a")
            _ = try await self.upload(client, token: self.iPhone.token, kind: .manual, slot: "slot2", body: "manual-b")

            let revisions = try await self.list(client, token: self.iPhone.token)
            XCTAssertEqual(revisions.filter { $0.kind == .auto }.map(\.id), Array(autoIDs.suffix(3)))
            XCTAssertEqual(revisions.filter { $0.kind == .native }.count, 5)
            XCTAssertEqual(revisions.filter { $0.kind == .manual }.count, 2)
            XCTAssertEqual(revisions.filter(\.isHead).count, 4)
            let files = try FileManager.default.contentsOfDirectory(
                atPath: self.store.paths.userDirectory(self.chad.id).appendingPathComponent("saves/\(self.game)").path)
            XCTAssertEqual(Set(files), Set(revisions.map(\.id)))
        }
    }

    func testSizeLimitAndHashVerification() async throws {
        try await app(.init(maxBytes: 8)).test(.router) { client in
            _ = try await self.upload(client, token: self.iPhone.token, body: "123456789", expect: .contentTooLarge)
            _ = try await self.upload(client, token: self.iPhone.token, body: "1234", sha256: SaveStore.sha256(Data("4321".utf8)), expect: .badRequest)
            let ok = try await self.upload(client, token: self.iPhone.token, body: "1234", sha256: SaveStore.sha256(Data("1234".utf8)))
            XCTAssertNotNil(ok)
            let count = try await self.list(client, token: self.iPhone.token).count
            XCTAssertEqual(count, 1)
        }
    }

    func testValidation() async throws {
        try await app().test(.router) { client in
            _ = try await self.upload(client, token: self.iPhone.token, kind: .manual, slot: "", body: "x", expect: .badRequest)
            _ = try await self.upload(client, token: self.iPhone.token, kind: .auto, slot: "slot1", body: "x", expect: .badRequest)
            _ = try await self.upload(client, token: self.iPhone.token, core: "", body: "x", expect: .badRequest)
            _ = try await self.upload(client, token: self.iPhone.token, game: "..", body: "x", expect: .badRequest)
            _ = try await self.upload(client, token: self.iPhone.token, game: "a%2F..%2Fb", body: "x", expect: .badRequest)
            try await client.execute(uri: "/v1/saves/\(self.game)/bogus?core=a&coreVersion=b", method: .put,
                                     headers: self.bearer(self.iPhone.token), body: ByteBuffer(string: "x")) {
                XCTAssertEqual($0.status, .badRequest)
            }
        }
    }

    func testAuthAndScopes() async throws {
        let (_, reader) = try store.createAPIToken(ownerUserID: chad.id, name: "openclaw", scopes: [.savesRead])
        let (_, libraryOnly) = try store.createAPIToken(ownerUserID: chad.id, name: "bot", scopes: [.libraryRead])
        try await app().test(.router) { client in
            try await client.execute(uri: "/v1/saves/\(self.game)", method: .get) { XCTAssertEqual($0.status, .unauthorized) }
            _ = try await self.upload(client, token: self.iPhone.token, body: "state")
            // saves:read tokens can list, but no API token can upload.
            let revisions = try await self.list(client, token: reader)
            XCTAssertEqual(revisions.count, 1)
            _ = try await self.upload(client, token: reader, body: "bot-state", expect: .forbidden)
            try await client.execute(uri: "/v1/saves/\(self.game)", method: .get, headers: self.bearer(libraryOnly)) {
                XCTAssertEqual($0.status, .forbidden)
            }
        }
    }

    func testUsersCanNeverSeeEachOthersSaves() async throws {
        let alex = try store.createUser(displayName: "Alex", role: .player)
        let alexPhone = try store.createDeviceToken(userID: alex.id, deviceName: "Alex's iPhone")
        try await store.db.write { db in
            try db.execute(sql: "INSERT INTO games (id, title, system, created_at) VALUES (?, 'Shared', 'snes', ?)", arguments: [self.game, Date()])
        }
        try await app().test(.router) { client in
            let chadSave = try await self.upload(client, token: self.iPhone.token, kind: .manual, slot: "slot1", body: "chad")!
            // Alex uploads to the same game and slot: a separate line, not a branch of Chad's.
            let alexSave = try await self.upload(client, token: alexPhone.token, kind: .manual, slot: "slot1", body: "alex")!
            XCTAssertFalse(alexSave.branched)

            let alexList = try await self.list(client, token: alexPhone.token)
            XCTAssertEqual(alexList.map(\.id), [alexSave.revision.id])
            let chadList = try await self.list(client, token: self.iPhone.token)
            XCTAssertEqual(chadList.map(\.id), [chadSave.revision.id])

            try await client.execute(uri: "/v1/saves/\(self.game)/revisions/\(chadSave.revision.id)", method: .get,
                                     headers: self.bearer(alexPhone.token)) { XCTAssertEqual($0.status, .notFound) }
            // A parent from another user's line can't be used to reach their data either.
            let sneaky = try await self.upload(client, token: alexPhone.token, kind: .manual, slot: "slot1",
                                               parent: chadSave.revision.id, body: "alex-2")!
            XCTAssertTrue(sneaky.branched)
            let chadAfter = try await self.list(client, token: self.iPhone.token)
            XCTAssertEqual(chadAfter.map(\.id), [chadSave.revision.id])

            // Unknown games remain inaccessible even though real games are shared by default.
            let hidden = String(repeating: "cd", count: 32)
            try await client.execute(uri: "/v1/saves/\(hidden)", method: .get, headers: self.bearer(alexPhone.token)) {
                XCTAssertEqual($0.status, .notFound)
            }
            _ = try await self.upload(client, token: alexPhone.token, game: hidden, body: "x", expect: .notFound)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.paths.userDirectory(alex.id).appendingPathComponent("saves/\(game)").path))
    }

    func testCorruptStoredSaveIsNotServed() async throws {
        try await app().test(.router) { client in
            let save = try await self.upload(client, token: self.iPhone.token, body: "good")!
            let url = self.store.paths.userDirectory(self.chad.id).appendingPathComponent("saves/\(self.game)/\(save.revision.id)")
            try Data("bad!".utf8).write(to: url)
            try await client.execute(uri: "/v1/saves/\(self.game)/revisions/\(save.revision.id)", method: .get,
                                     headers: self.bearer(self.iPhone.token)) { XCTAssertEqual($0.status, .internalServerError) }
        }
    }

    func testBranchCopiesNeverBecomeHeadAndDeviceBasesSurvivePruning() async throws {
        try await app(SaveConfiguration(autoRevisionsKept: 2)).test(.router) { client in
            let a = try await self.upload(client, token: self.iPhone.token, body: "a")!.revision
            let copy = try await client.execute(
                uri: "/v1/saves/\(self.game)/auto?slot=&core=Snes9x&coreVersion=1.62&branch=1&parent=\(a.id)", method: .put,
                headers: self.bearer(self.mac.token), body: ByteBuffer(string: "mac-copy")) { try self.decode(SaveUploadResponse.self, $0) }
            XCTAssertTrue(copy.branched)
            XCTAssertFalse(copy.revision.isHead)
            var listed = try await self.list(client, token: self.iPhone.token)
            XCTAssertEqual(listed.filter(\.isHead).map(\.id), [a.id], "a branch copy never becomes the head")

            // The Mac moves on while the iPhone is away; the iPhone's base must survive auto retention.
            var head = a.id
            for body in ["b", "c", "d"] { head = try await self.upload(client, token: self.mac.token, parent: head, body: body)!.revision.id }
            listed = try await self.list(client, token: self.iPhone.token)
            XCTAssertTrue(listed.contains { $0.id == a.id }, "the iPhone's last synced revision is kept")
            XCTAssertFalse(listed.contains { $0.sha256 == SaveStore.sha256(Data("b".utf8)) }, "other old auto states are pruned")
            XCTAssertEqual(listed.filter(\.isHead).map(\.id), [head])

            // Downloading moves the iPhone's base, so its old base can be pruned on the next upload.
            _ = try await client.execute(uri: "/v1/saves/\(self.game)/revisions/\(head)", method: .get, headers: self.bearer(self.iPhone.token)) { _ in }
            _ = try await self.upload(client, token: self.mac.token, parent: head, body: "e")
            listed = try await self.list(client, token: self.iPhone.token)
            XCTAssertFalse(listed.contains { $0.id == a.id })
        }
    }

    func testIfHeadKeepsStaleUploadsAsProtectedBranchCopiesAndRetriesStayIdempotent() async throws {
        try await app(SaveConfiguration(autoRevisionsKept: 2)).test(.router) { client in
            let a = try await self.upload(client, token: self.iPhone.token, ifHead: true, body: "a")!.revision
            let b = try await self.upload(client, token: self.iPhone.token, parent: a.id, ifHead: true, body: "b")!.revision
            XCTAssertTrue(b.isHead)
            // A retry after a lost response finds the head it created instead of making a branch copy.
            let retry = try await self.upload(client, token: self.iPhone.token, parent: a.id, ifHead: true, body: "b")!
            XCTAssertEqual(retry.revision.id, b.id)
            XCTAssertFalse(retry.revision.isBranchCopy ?? false)

            // The Mac was offline on `a`: its upload is a branch copy, and the iPhone's head is untouched.
            let stale = try await self.upload(client, token: self.mac.token, parent: a.id, ifHead: true, body: "mac-offline")!
            XCTAssertTrue(stale.branched)
            XCTAssertEqual(stale.revision.isBranchCopy, true)
            var listed = try await self.list(client, token: self.iPhone.token)
            XCTAssertEqual(listed.filter(\.isHead).map(\.id), [b.id])

            // Unresolved offline progress survives later autosaves from the other device.
            var head = b.id
            for body in ["c", "d", "e", "f"] {
                head = try await self.upload(client, token: self.iPhone.token, parent: head, ifHead: true, body: body)!.revision.id
            }
            listed = try await self.list(client, token: self.iPhone.token)
            XCTAssertTrue(listed.contains { $0.id == stale.revision.id })
            XCTAssertFalse(listed.contains { $0.id == b.id }, "ordinary old auto states are still pruned")

            // An offline Mac uploading bytes equal to an older iPhone revision still gets a branch copy, not that old revision.
            let m1 = try await self.upload(client, token: self.iPhone.token, kind: .manual, slot: "1", ifHead: true, body: "m1")!.revision
            let m2 = try await self.upload(client, token: self.iPhone.token, kind: .manual, slot: "1", parent: m1.id, ifHead: true, body: "m2")!.revision
            _ = try await self.upload(client, token: self.iPhone.token, kind: .manual, slot: "1", parent: m2.id, ifHead: true, body: "m3")
            let old = try await self.upload(client, token: self.mac.token, kind: .manual, slot: "1", parent: m1.id, ifHead: true, body: "m2")!
            XCTAssertEqual(old.revision.isBranchCopy, true)
            XCTAssertNotEqual(old.revision.id, m2.id)
        }
    }

    func testCoreMetadataIsBounded() async throws {
        try await app().test(.router) { client in
            _ = try await self.upload(client, token: self.iPhone.token, core: String(repeating: "x", count: 129), body: "s", expect: .badRequest)
            _ = try await self.upload(client, token: self.iPhone.token, coreVersion: String(repeating: "1", count: 129), body: "s", expect: .badRequest)
        }
    }

    func testRetentionKeepsAncestryFromAnAwayDevicesBase() async throws {
        try await app(SaveConfiguration(autoRevisionsKept: 2)).test(.router) { client in
            let a = try await self.upload(client, token: self.iPhone.token, body: "a")!.revision
            var head = a.id
            for body in ["b", "c", "d", "e"] { head = try await self.upload(client, token: self.mac.token, parent: head, body: body)!.revision.id }
            let listed = try await self.list(client, token: self.iPhone.token)
            var byID: [String: SaveRevision] = [:]
            for revision in listed { byID[revision.id] = revision }
            var cursor = byID[head]
            var reachedA = false
            while let current = cursor {
                if current.id == a.id { reachedA = true; break }
                cursor = current.parentID.flatMap { byID[$0] }
            }
            XCTAssertTrue(reachedA, "the head still traces back to the iPhone's base after pruning")
            XCTAssertLessThan(listed.count, 5)
            // A corrupt download doesn't move the device's base.
            let headRow = try await self.store.db.read { try String.fetchOne($0, sql: "SELECT stored_path FROM save_revisions WHERE id = ?", arguments: [head])! }
            try Data("corrupt".utf8).write(to: self.store.paths.root.appendingPathComponent(headRow))
            _ = try await client.execute(uri: "/v1/saves/\(self.game)/revisions/\(head)", method: .get, headers: self.bearer(self.iPhone.token)) { response in
                XCTAssertEqual(response.status, .internalServerError)
            }
            let base = try await self.store.db.read {
                try String.fetchOne($0, sql: "SELECT revision_id FROM save_device_bases WHERE device_id = ? AND game_id = ?", arguments: [self.iPhone.deviceID, self.game])
            }
            XCTAssertEqual(base, a.id)
        }
    }
}
