import Foundation
import CryptoKit
import GRDB
import Hummingbird
import HummingbirdTesting
import SupersEmuKit
@testable import SupersEmuServerCore
import XCTest

final class AdminUserGamesTests: XCTestCase {
    var store: ServerStore!
    var admin: UserInfo!
    var adminDevice: (deviceID: String, token: String)!
    var sources: URL!

    override func setUp() async throws {
        store = try ServerStore.inMemory()
        admin = try store.createUser(displayName: "Chad", role: .admin)
        adminDevice = try store.createDeviceToken(userID: admin.id, deviceName: "Chad's Mac")
        sources = FileManager.default.temporaryDirectory.appendingPathComponent("user-games-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: sources, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: sources)
        try? FileManager.default.removeItem(at: store.paths.root)
    }

    func app() -> some ApplicationProtocol { buildApplication(store: store, configuration: .init()) }

    func bearer(_ token: String) -> HTTPFields {
        [.authorization: "Bearer \(token)", .contentType: "application/json"]
    }

    func json<T: Encodable>(_ value: T) throws -> ByteBuffer {
        ByteBuffer(data: try SupersEmuJSON.encoder().encode(value))
    }

    func decode<T: Decodable>(_ type: T.Type, _ response: TestResponse) throws -> T {
        try SupersEmuJSON.decoder().decode(T.self, from: Data(buffer: response.body))
    }

    func createGame(_ name: String, seed: UInt8) async throws -> String {
        let source = sources.appendingPathComponent("\(name).sfc")
        try ROMFixtures.snes(seed: seed).write(to: source)
        let report = try await LibraryImporter(store: store).importPaths([source.path], auth: nil)
        return try XCTUnwrap(report.imported.first?.id)
    }

    func testPutReplacesDirectGrantsAndPlayerSeesCombinedPermissions() async throws {
        let directA = try await createGame("DirectA", seed: 1)
        let directB = try await createGame("DirectB", seed: 2)
        let directC = try await createGame("DirectC", seed: 3)
        let everyone = try await createGame("Everyone", seed: 4)
        let group = try await createGame("Group", seed: 5)
        let player = try store.createUser(displayName: "Alex", role: .player)
        let playerToken = try store.createDeviceToken(userID: player.id, deviceName: "Alex's iPhone").token

        try await store.db.write { db in
            try db.execute(sql: "INSERT INTO groups (id, name) VALUES ('friends', 'Friends')")
            try db.execute(sql: "INSERT INTO group_members (group_id, user_id) VALUES ('friends', ?)", arguments: [player.id])
            try db.execute(sql: """
                INSERT INTO game_permissions (game_id, principal_type, principal_id) VALUES
                (?, 'everyone', ''), (?, 'group', 'friends')
                """, arguments: [everyone, group])
        }

        try await app().test(.router) { client in
            let first = try await client.execute(
                uri: "/v1/admin/users/\(player.id)/games", method: .put, headers: self.bearer(self.adminDevice.token),
                body: try self.json(SetUserGamesRequest(gameIDs: [directA, directB, directA]))) { response in
                    XCTAssertEqual(response.status, .ok)
                    return try self.decode(UserGameAccess.self, response)
                }
            XCTAssertEqual(first.userID, player.id)
            XCTAssertEqual(first.gameIDs, [directA, directB].sorted())
            XCTAssertEqual(first.everyoneGameIDs, [everyone])
            XCTAssertEqual(first.groupGameIDs, [group])
            try await client.execute(uri: "/v1/games/\(directA)/files/\(directA)", method: .get,
                                     headers: self.bearer(playerToken)) {
                XCTAssertEqual($0.status, .ok)
            }

            let replaced = try await client.execute(
                uri: "/v1/admin/users/\(player.id)/games", method: .put, headers: self.bearer(self.adminDevice.token),
                body: try self.json(SetUserGamesRequest(gameIDs: [directC, directB]))) { response in
                    XCTAssertEqual(response.status, .ok)
                    return try self.decode(UserGameAccess.self, response)
                }
            XCTAssertEqual(replaced.gameIDs, [directB, directC].sorted())

            try await client.execute(uri: "/v1/admin/users/\(player.id)/games", method: .get,
                                     headers: self.bearer(self.adminDevice.token)) { response in
                XCTAssertEqual(response.status, .ok)
                XCTAssertEqual(try self.decode(UserGameAccess.self, response), replaced)
            }
            try await client.execute(uri: "/v1/library", method: .get, headers: self.bearer(playerToken)) { response in
                XCTAssertEqual(response.status, .ok)
                let ids = try self.decode(LibraryResponse.self, response).games.map(\.id)
                XCTAssertEqual(ids.sorted(), [directB, directC, everyone, group].sorted())
            }
            try await client.execute(uri: "/v1/games/\(directA)/files/\(directA)", method: .get,
                                     headers: self.bearer(playerToken)) {
                XCTAssertEqual($0.status, .notFound)
            }
        }

        let details = try await store.db.read { db in
            try String.fetchAll(db, sql: "SELECT detail FROM audit_log WHERE action = 'library.user_games' ORDER BY id")
        }
        XCTAssertEqual(details, ["user=\(player.id) count=2", "user=\(player.id) count=2"])
    }

    func testSetUserGamesValidatesTargetsAndScopes() async throws {
        let game = try await createGame("Valid", seed: 6)
        let player = try store.createUser(displayName: "Alex", role: .player)
        let playerToken = try store.createDeviceToken(userID: player.id, deviceName: "Alex's iPhone").token
        let usersAdminToken = try store.createAPIToken(
            ownerUserID: admin.id, name: "users-admin", scopes: [.usersAdmin]).token
        let libraryWriteToken = try store.createAPIToken(
            ownerUserID: admin.id, name: "library-write", scopes: [.libraryWrite]).token

        try await app().test(.router) { client in
            let uri = "/v1/admin/users/\(player.id)/games"
            try await client.execute(uri: uri, method: .put, headers: self.bearer(self.adminDevice.token),
                                     body: try self.json(SetUserGamesRequest(gameIDs: [game]))) {
                XCTAssertEqual($0.status, .ok)
            }
            try await client.execute(uri: "/v1/admin/users/\(admin.id)/games", method: .put,
                                     headers: self.bearer(self.adminDevice.token),
                                     body: try self.json(SetUserGamesRequest(gameIDs: []))) { response in
                XCTAssertEqual(response.status, .badRequest)
                XCTAssertTrue(String(buffer: response.body).contains("Admins see every game"))
            }
            try await client.execute(uri: "/v1/admin/users/\(admin.id)", method: .delete,
                                     headers: self.bearer(self.adminDevice.token)) {
                XCTAssertEqual($0.status, .badRequest)
            }
            try await client.execute(uri: "/v1/me", method: .get, headers: self.bearer(self.adminDevice.token)) {
                XCTAssertEqual($0.status, .ok)
            }

            try await client.execute(uri: uri, method: .put, headers: self.bearer(self.adminDevice.token),
                                     body: try self.json(SetUserGamesRequest(gameIDs: [game, "missing-game"]))) {
                XCTAssertEqual($0.status, .badRequest)
            }
            try await client.execute(uri: uri, method: .put, headers: self.bearer(self.adminDevice.token),
                                     body: try self.json(SetUserGamesRequest(gameIDs: Array(repeating: game, count: 10_001)))) {
                XCTAssertEqual($0.status, .badRequest)
            }
            try await client.execute(uri: uri, method: .put, headers: self.bearer(playerToken),
                                     body: try self.json(SetUserGamesRequest(gameIDs: []))) {
                XCTAssertEqual($0.status, .forbidden)
            }
            try await client.execute(uri: uri, method: .put, headers: self.bearer(usersAdminToken),
                                     body: try self.json(SetUserGamesRequest(gameIDs: []))) {
                XCTAssertEqual($0.status, .forbidden)
            }
            try await client.execute(uri: "/v1/admin/users/\(player.id)/games", method: .get,
                                     headers: self.bearer(libraryWriteToken)) {
                XCTAssertEqual($0.status, .forbidden)
            }
            try await client.execute(uri: uri, method: .get, headers: self.bearer(playerToken)) {
                XCTAssertEqual($0.status, .forbidden)
            }
            try await client.execute(uri: uri, method: .get, headers: self.bearer(self.adminDevice.token)) { response in
                XCTAssertEqual(response.status, .ok)
                XCTAssertEqual(try self.decode(UserGameAccess.self, response).gameIDs, [game])
            }
            try await client.execute(uri: "/v1/admin/users/missing-user/games", method: .get,
                                     headers: self.bearer(self.adminDevice.token)) {
                XCTAssertEqual($0.status, .notFound)
            }
        }

        let details = try await store.db.read { db in
            try String.fetchAll(db, sql: "SELECT detail FROM audit_log WHERE action = 'library.user_games' ORDER BY id")
        }
        XCTAssertEqual(details, ["user=\(player.id) count=1"])
    }

    func testUpdateUserTrimsAndValidatesDisplayName() async throws {
        let player = try store.createUser(displayName: "Alex", role: .player)

        try await app().test(.router) { client in
            try await client.execute(uri: "/v1/admin/users/\(player.id)", method: .patch,
                                     headers: self.bearer(self.adminDevice.token),
                                     body: try self.json(UpdateUserRequest(displayName: "  Jordan \n"))) { response in
                XCTAssertEqual(response.status, .ok)
                XCTAssertEqual(try self.decode(UserInfo.self, response).displayName, "Jordan")
            }
            try await client.execute(uri: "/v1/admin/users/\(player.id)", method: .patch,
                                     headers: self.bearer(self.adminDevice.token),
                                     body: try self.json(UpdateUserRequest(displayName: " \n "))) {
                XCTAssertEqual($0.status, .badRequest)
            }
            try await client.execute(uri: "/v1/admin/users/\(player.id)", method: .patch,
                                     headers: self.bearer(self.adminDevice.token),
                                     body: try self.json(UpdateUserRequest(displayName: String(repeating: "x", count: 101)))) {
                XCTAssertEqual($0.status, .badRequest)
            }
            try await client.execute(uri: "/v1/admin/users/missing-user", method: .patch,
                                     headers: self.bearer(self.adminDevice.token),
                                     body: try self.json(UpdateUserRequest(displayName: "Jordan"))) {
                XCTAssertEqual($0.status, .notFound)
            }
            try await client.execute(uri: "/v1/admin/users", method: .get,
                                     headers: self.bearer(self.adminDevice.token)) { response in
                XCTAssertEqual(try self.decode([UserInfo].self, response).first(where: { $0.id == player.id })?.displayName, "Jordan")
            }
        }

        let actions = try await store.db.read { db in
            try String.fetchAll(db, sql: "SELECT action FROM audit_log WHERE action = 'users.rename'")
        }
        XCTAssertEqual(actions, ["users.rename"])
    }

    func testRemoveUserRevokesAccessAndPreservesSaveFiles() async throws {
        let player = try store.createUser(displayName: "Alex", role: .player)
        let phone = try store.createDeviceToken(userID: player.id, deviceName: "Alex's iPhone")
        let tablet = try store.createDeviceToken(userID: player.id, deviceName: "Alex's iPad")
        let game = try await createGame("SavedGame", seed: 7)
        try await store.db.write { db in
            try db.execute(sql: "INSERT INTO groups (id, name) VALUES ('players', 'Players')")
            try db.execute(sql: "INSERT INTO group_members (group_id, user_id) VALUES ('players', ?)", arguments: [player.id])
            try db.execute(sql: "INSERT INTO game_permissions (game_id, principal_type, principal_id) VALUES (?, 'user', ?)",
                           arguments: [game, player.id])
            try db.execute(sql: "INSERT INTO game_permissions (game_id, principal_type, principal_id) VALUES (?, 'group', 'players')",
                           arguments: [game])
        }

        let claimSecret = String(repeating: "ab", count: 32)
        let claimHash = SHA256.hash(data: Data(repeating: 0xab, count: 32))
            .map { String(format: "%02x", $0) }.joined()
        let (revisionID, pairingCode, requestID) = try await app().test(.router) { client in
            let uploaded = try await client.execute(
                uri: "/v1/saves/\(game)/manual?slot=slot1&core=Snes9x&coreVersion=1.62", method: .put,
                headers: self.bearer(phone.token), body: ByteBuffer(string: "preserve this save")) { response in
                    XCTAssertEqual(response.status, .ok)
                    return try self.decode(SaveUploadResponse.self, response)
                }

            let pairingCode = try await client.execute(uri: "/v1/admin/pairing-codes", method: .post,
                                                       headers: self.bearer(self.adminDevice.token),
                                                       body: try self.json(CreatePairingCodeRequest(userID: player.id))) { response in
                XCTAssertEqual(response.status, .created)
                return try self.decode(PairingCode.self, response).code
            }
            let request = try await client.execute(
                uri: "/v1/pair/requests", method: .post, headers: [.contentType: "application/json"],
                body: try self.json(PairRequestCreate(deviceName: "Friend's iPhone", platform: "ios", claimHash: claimHash))) { response in
                    XCTAssertEqual(response.status, .created)
                    return try self.decode(PairRequestCreated.self, response)
                }
            try await client.execute(
                uri: "/v1/pair/requests/\(request.requestID)/claim", method: .post,
                headers: [.contentType: "application/json"],
                body: try self.json(PairRequestClaim(claimSecret: claimSecret))) {
                    XCTAssertEqual($0.status, .accepted)
                }
            return (uploaded.revision.id, pairingCode, request.requestID)
        }

        let savedFile = store.paths.userDirectory(player.id).appendingPathComponent("saves/\(game)/\(revisionID)")
        XCTAssertTrue(FileManager.default.fileExists(atPath: savedFile.path))

        try await app().test(.router) { client in
            try await client.execute(uri: "/v1/admin/users/\(player.id)", method: .delete,
                                     headers: self.bearer(self.adminDevice.token)) { response in
                XCTAssertEqual(response.status, .ok)
                XCTAssertEqual(try self.decode(UserInfo.self, response), player)
            }
            for token in [phone.token, tablet.token] {
                try await client.execute(uri: "/v1/me", method: .get, headers: self.bearer(token)) {
                    XCTAssertEqual($0.status, .unauthorized)
                }
            }
            try await client.execute(uri: "/v1/pair", method: .post,
                                     headers: [.contentType: "application/json"],
                                     body: try self.json(PairRequest(code: pairingCode, deviceName: "New device", platform: "iOS"))) {
                XCTAssertEqual($0.status, .unauthorized)
            }
            try await client.execute(uri: "/v1/admin/pair-requests/\(requestID)/approve", method: .post,
                                     headers: self.bearer(self.adminDevice.token),
                                     body: try self.json(PairRequestApproval(userID: player.id))) {
                XCTAssertEqual($0.status, .notFound)
            }
            try await client.execute(uri: "/v1/admin/users", method: .get,
                                     headers: self.bearer(self.adminDevice.token)) { response in
                XCTAssertFalse(try self.decode([UserInfo].self, response).contains(where: { $0.id == player.id }))
            }
            try await client.execute(uri: "/v1/admin/users/\(player.id)/games", method: .get,
                                     headers: self.bearer(self.adminDevice.token)) {
                XCTAssertEqual($0.status, .notFound)
            }
            try await client.execute(uri: "/v1/admin/users/\(player.id)", method: .delete,
                                     headers: self.bearer(self.adminDevice.token)) {
                XCTAssertEqual($0.status, .notFound)
            }
        }

        let persisted = try store.db.read { db in
            return (
                revokedAt: try Date.fetchOne(db, sql: "SELECT revoked_at FROM users WHERE id = ?", arguments: [player.id]),
                revokedDevices: try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM devices WHERE user_id = ? AND revoked_at IS NOT NULL",
                                                 arguments: [player.id]) ?? 0,
                userGrants: try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM game_permissions WHERE principal_type = 'user' AND principal_id = ?",
                                             arguments: [player.id]) ?? 0,
                memberships: try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM group_members WHERE user_id = ?", arguments: [player.id]) ?? 0,
                save: try Row.fetchOne(db, sql: "SELECT stored_path FROM save_revisions WHERE id = ?", arguments: [revisionID]),
                audit: try String.fetchOne(db, sql: "SELECT detail FROM audit_log WHERE action = 'users.remove' ORDER BY id DESC LIMIT 1")
            )
        }
        XCTAssertNotNil(persisted.revokedAt)
        XCTAssertEqual(persisted.revokedDevices, 2)
        XCTAssertEqual(persisted.userGrants, 0)
        XCTAssertEqual(persisted.memberships, 0)
        XCTAssertEqual(persisted.save?["stored_path"] as String?, "users/\(player.id)/saves/\(game)/\(revisionID)")
        XCTAssertTrue(FileManager.default.fileExists(atPath: savedFile.path))
        XCTAssertEqual(try Data(contentsOf: savedFile), Data("preserve this save".utf8))
        XCTAssertEqual(persisted.audit, "user=\(player.id)")
    }
}
