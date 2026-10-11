import Foundation
import GRDB
import Hummingbird
import HummingbirdTesting
import SupersEmuKit
@testable import SupersEmuServerCore
import XCTest

final class AdminUserRoutesTests: XCTestCase {
    var store: ServerStore!
    var admin: UserInfo!
    var adminDevice: (deviceID: String, token: String)!

    override func setUp() async throws {
        store = try ServerStore.inMemory()
        admin = try store.createUser(displayName: "Chad", role: .admin)
        adminDevice = try store.createDeviceToken(userID: admin.id, deviceName: "Chad's iPhone")
    }

    func app() -> some ApplicationProtocol { buildApplication(store: store, configuration: .init()) }

    func bearer(_ token: String) -> HTTPFields { [.authorization: "Bearer \(token)", .contentType: "application/json"] }

    func decode<T: Decodable>(_ type: T.Type, _ response: TestResponse) throws -> T {
        try SupersEmuJSON.decoder().decode(T.self, from: Data(buffer: response.body))
    }

    func json<T: Encodable>(_ value: T) throws -> ByteBuffer { ByteBuffer(data: try SupersEmuJSON.encoder().encode(value)) }

    func auditActions() throws -> [String] {
        try store.db.read { try String.fetchAll($0, sql: "SELECT action FROM audit_log ORDER BY id") }
    }

    static let adminRoutes: [(HTTPRequest.Method, String)] = [
        (.get, "/v1/admin/status"), (.get, "/v1/admin/users"), (.post, "/v1/admin/users"),
        (.get, "/v1/admin/devices"), (.delete, "/v1/admin/devices/x"),
        (.get, "/v1/admin/tokens"), (.post, "/v1/admin/tokens"), (.delete, "/v1/admin/tokens/x"),
    ]

    func testStatusReportsCountsAndFreeSpace() async throws {
        try await store.db.write { db in
            try db.execute(sql: "INSERT INTO games (id, title, system, created_at) VALUES ('g1', 'A', 'snes', ?), ('g2', 'B', 'snes', ?)", arguments: [Date(), Date()])
            try db.execute(sql: "UPDATE games SET needs_review = 1 WHERE id = 'g2'")
        }
        try await app().test(.router) { client in
            try await client.execute(uri: "/v1/admin/status", method: .get, headers: self.bearer(self.adminDevice.token)) { response in
                XCTAssertEqual(response.status, .ok)
                let status = try self.decode(AdminStatus.self, response)
                XCTAssertEqual(status.dataDirectory, self.store.paths.root.path)
                XCTAssertNotNil(status.freeBytes)
                XCTAssertGreaterThan(status.freeBytes ?? 0, 0)
                XCTAssertEqual(status.gameCount, 1)
                XCTAssertEqual(status.reviewCount, 1)
                XCTAssertEqual(status.userCount, 1)
                XCTAssertEqual(status.deviceCount, 1)
                XCTAssertEqual(status.health.serverName, "Test Server")
            }
        }
    }

    func testAdminRoutesRejectPlayersScopedTokensAndAnonymous() async throws {
        let player = try store.createUser(displayName: "Alex", role: .player)
        let playerDevice = try store.createDeviceToken(userID: player.id, deviceName: "Alex's iPhone").token
        // A player's token can't carry admin rights even if the scope is stored on it.
        let playerToken = try store.createAPIToken(ownerUserID: player.id, name: "alex-bot", scopes: Scope.allCases).token
        let libraryBot = try store.createAPIToken(ownerUserID: admin.id, name: "openclaw", scopes: [.libraryRead, .libraryWrite, .savesRead]).token
        try await app().test(.router) { client in
            for (method, uri) in Self.adminRoutes {
                try await client.execute(uri: uri, method: method, headers: [.contentType: "application/json"], body: ByteBuffer(string: "{}")) {
                    XCTAssertEqual($0.status, .unauthorized, "\(method) \(uri) anonymous")
                }
                for (label, token) in [("player device", playerDevice), ("player token", playerToken), ("library-scoped token", libraryBot)] {
                    try await client.execute(uri: uri, method: method, headers: self.bearer(token), body: ByteBuffer(string: "{}")) {
                        XCTAssertEqual($0.status, .forbidden, "\(method) \(uri) \(label)")
                    }
                }
            }
        }
        XCTAssertEqual(try auditActions(), [])
    }

    func testUsersAdminScopedTokenCanUseAdminRoutes() async throws {
        let bot = try store.createAPIToken(ownerUserID: admin.id, name: "admin-bot", scopes: [.usersAdmin]).token
        try await app().test(.router) { client in
            try await client.execute(uri: "/v1/admin/users", method: .get, headers: self.bearer(bot)) { response in
                XCTAssertEqual(response.status, .ok)
                XCTAssertEqual(try self.decode([UserInfo].self, response).map(\.displayName), ["Chad"])
            }
        }
    }

    func testCreateTokenReturnsPlaintextOnceAndNeverTheHash() async throws {
        let created: TokenInfo = try await app().test(.router) { client in
            let request = CreateTokenRequest(name: "openclaw", scopes: [.libraryWrite, .libraryRead])
            let created = try await client.execute(uri: "/v1/admin/tokens", method: .post, headers: self.bearer(self.adminDevice.token), body: try self.json(request)) { response in
                XCTAssertEqual(response.status, .created)
                return try self.decode(TokenInfo.self, response)
            }
            let token = try XCTUnwrap(created.token)
            XCTAssertTrue(token.hasPrefix("sek_"))
            XCTAssertEqual(created.scopes, [.libraryRead, .libraryWrite])
            XCTAssertNil(created.revokedAt)

            try await client.execute(uri: "/v1/admin/tokens", method: .get, headers: self.bearer(self.adminDevice.token)) { response in
                let body = String(buffer: response.body)
                XCTAssertFalse(body.contains(token))
                XCTAssertFalse(body.contains(ServerStore.hash(token)))
                XCTAssertFalse(body.contains("token_hash"))
                let list = try self.decode([TokenInfo].self, response)
                XCTAssertEqual(list.map(\.id), [created.id])
                XCTAssertNil(list.first?.token)
            }
            try await client.execute(uri: "/v1/me", method: .get, headers: self.bearer(token)) { response in
                XCTAssertEqual(response.status, .ok)
                XCTAssertEqual(try self.decode(MeResponse.self, response).scopes, [.libraryRead, .libraryWrite])
            }
            return created
        }
        let audit = try store.db.read { try Row.fetchAll($0, sql: "SELECT * FROM audit_log") }
        XCTAssertEqual(audit.map { $0["action"] as String }, ["token.create"])
        XCTAssertEqual(audit.first?["actor_credential"] as String?, "device:\(adminDevice.deviceID)")
        XCTAssertFalse((audit.first?["detail"] as String? ?? "").contains(created.token ?? "-"))
    }

    func testCreateTokenValidation() async throws {
        let narrow = try store.createAPIToken(ownerUserID: admin.id, name: "admin-only", scopes: [.usersAdmin]).token
        try await app().test(.router) { client in
            let headers = self.bearer(self.adminDevice.token)
            try await client.execute(uri: "/v1/admin/tokens", method: .post, headers: headers,
                                     body: try self.json(CreateTokenRequest(name: "x", scopes: []))) { XCTAssertEqual($0.status, .badRequest) }
            try await client.execute(uri: "/v1/admin/tokens", method: .post, headers: headers,
                                     body: try self.json(CreateTokenRequest(name: "  ", scopes: [.libraryRead]))) { XCTAssertEqual($0.status, .badRequest) }
            try await client.execute(uri: "/v1/admin/tokens", method: .post, headers: headers,
                                     body: ByteBuffer(string: #"{"name":"x","scopes":["root"]}"#)) { XCTAssertEqual($0.status, .badRequest) }
            // A scoped token can't mint more rights than it holds.
            try await client.execute(uri: "/v1/admin/tokens", method: .post, headers: self.bearer(narrow),
                                     body: try self.json(CreateTokenRequest(name: "wider", scopes: [.libraryWrite]))) { XCTAssertEqual($0.status, .forbidden) }
            try await client.execute(uri: "/v1/admin/tokens", method: .post, headers: self.bearer(narrow),
                                     body: try self.json(CreateTokenRequest(name: "same", scopes: [.usersAdmin]))) { XCTAssertEqual($0.status, .created) }
        }
        XCTAssertEqual(try auditActions(), ["token.create"])
    }

    func testRevokeDevice() async throws {
        let ipad = try store.createDeviceToken(userID: admin.id, deviceName: "Chad's iPad")
        try await app().test(.router) { client in
            let headers = self.bearer(self.adminDevice.token)
            try await client.execute(uri: "/v1/me", method: .get, headers: self.bearer(ipad.token)) { XCTAssertEqual($0.status, .ok) }
            let revokedAt = try await client.execute(uri: "/v1/admin/devices/\(ipad.deviceID)", method: .delete, headers: headers) { response in
                XCTAssertEqual(response.status, .ok)
                let device = try self.decode(DeviceInfo.self, response)
                XCTAssertEqual(device.name, "Chad's iPad")
                XCTAssertNotNil(device.revokedAt)
                return device.revokedAt
            }
            try await client.execute(uri: "/v1/me", method: .get, headers: self.bearer(ipad.token)) { XCTAssertEqual($0.status, .unauthorized) }
            // Idempotent: a second revoke keeps the original time and isn't audited again.
            try await client.execute(uri: "/v1/admin/devices/\(ipad.deviceID)", method: .delete, headers: headers) { response in
                XCTAssertEqual(response.status, .ok)
                XCTAssertEqual(try self.decode(DeviceInfo.self, response).revokedAt, revokedAt)
            }
            try await client.execute(uri: "/v1/admin/devices/nope", method: .delete, headers: headers) { XCTAssertEqual($0.status, .notFound) }
            try await client.execute(uri: "/v1/admin/devices", method: .get, headers: headers) { response in
                let body = String(buffer: response.body)
                XCTAssertFalse(body.contains(ServerStore.hash(ipad.token)))
                let devices = try self.decode([DeviceInfo].self, response)
                XCTAssertEqual(devices.map(\.name), ["Chad's iPhone", "Chad's iPad"])
                XCTAssertNotNil(devices.first?.lastSeenAt)
                XCTAssertNil(devices.first?.revokedAt)
                XCTAssertNotNil(devices.last?.revokedAt)
            }
            try await client.execute(uri: "/v1/admin/status", method: .get, headers: headers) {
                XCTAssertEqual(try self.decode(AdminStatus.self, $0).deviceCount, 1)
            }
        }
        XCTAssertEqual(try auditActions(), ["device.revoke"])
    }

    func testDeviceSelfRevokeRevokesOnlyCurrentDevice() async throws {
        let player = try store.createUser(displayName: "Alex", role: .player)
        let current = try store.createDeviceToken(userID: player.id, deviceName: "Alex's iPhone")
        let other = try store.createDeviceToken(userID: player.id, deviceName: "Alex's iPad")

        try await app().test(.router) { client in
            try await client.execute(uri: "/v1/devices/self", method: .delete, headers: self.bearer(current.token)) { response in
                XCTAssertEqual(response.status, .ok)
                let device = try self.decode(DeviceInfo.self, response)
                XCTAssertEqual(device.id, current.deviceID)
                XCTAssertNotNil(device.revokedAt)
            }
            try await client.execute(uri: "/v1/me", method: .get, headers: self.bearer(current.token)) {
                XCTAssertEqual($0.status, .unauthorized)
            }
            try await client.execute(uri: "/v1/me", method: .get, headers: self.bearer(other.token)) {
                XCTAssertEqual($0.status, .ok)
            }
            try await client.execute(uri: "/v1/devices/self", method: .delete, headers: self.bearer(current.token)) {
                XCTAssertEqual($0.status, .unauthorized)
            }
            try await client.execute(uri: "/v1/devices/self", method: .delete, headers: self.bearer("unknown-token")) {
                XCTAssertEqual($0.status, .unauthorized)
            }
        }
        XCTAssertEqual(try auditActions(), ["device.self_revoked"])
    }

    func testRevokeToken() async throws {
        let (id, token) = try store.createAPIToken(ownerUserID: admin.id, name: "openclaw", scopes: [.libraryRead])
        try await app().test(.router) { client in
            let headers = self.bearer(self.adminDevice.token)
            try await client.execute(uri: "/v1/library", method: .get, headers: self.bearer(token)) { XCTAssertEqual($0.status, .ok) }
            try await client.execute(uri: "/v1/admin/tokens/\(id)", method: .delete, headers: headers) { response in
                XCTAssertEqual(response.status, .ok)
                let info = try self.decode(TokenInfo.self, response)
                XCTAssertNotNil(info.revokedAt)
                XCTAssertNil(info.token)
            }
            try await client.execute(uri: "/v1/library", method: .get, headers: self.bearer(token)) { XCTAssertEqual($0.status, .unauthorized) }
            try await client.execute(uri: "/v1/admin/tokens/\(id)", method: .delete, headers: headers) { XCTAssertEqual($0.status, .ok) }
            try await client.execute(uri: "/v1/admin/tokens/nope", method: .delete, headers: headers) { XCTAssertEqual($0.status, .notFound) }
        }
        XCTAssertEqual(try auditActions(), ["token.revoke"])
    }

    func testConcurrentRevokesKeepFirstTimeAndAuditOnce() async throws {
        let auth = try XCTUnwrap(try store.authenticate(token: adminDevice.token))
        let ipad = try store.createDeviceToken(userID: admin.id, deviceName: "Chad's iPad")
        let (tokenID, _) = try store.createAPIToken(ownerUserID: admin.id, name: "openclaw", scopes: [.libraryRead])
        let store = self.store!
        let results = try await withThrowingTaskGroup(of: (Date?, Date?).self) { group in
            for _ in 0..<8 {
                group.addTask {
                    (try store.revokeDevice(id: ipad.deviceID, by: auth)?.revokedAt, try store.revokeAPIToken(id: tokenID, by: auth)?.revokedAt)
                }
            }
            return try await group.reduce(into: []) { $0.append($1) }
        }
        XCTAssertEqual(Set(results.map(\.0)).count, 1)
        XCTAssertEqual(Set(results.map(\.1)).count, 1)
        XCTAssertNotNil(results.first?.0 ?? nil)
        XCTAssertEqual(try auditActions().sorted(), ["device.revoke", "token.revoke"])
    }

    func testFailedAuditRollsBackTheMutation() throws {
        let auth = try XCTUnwrap(try store.authenticate(token: adminDevice.token))
        let ipad = try store.createDeviceToken(userID: admin.id, deviceName: "Chad's iPad")
        try store.db.write { try $0.execute(sql: "DROP TABLE audit_log") }
        XCTAssertThrowsError(try store.createAPIToken(by: auth, name: "openclaw", scopes: [.libraryRead]))
        XCTAssertThrowsError(try store.createPlayer(displayName: "Alex", by: auth))
        XCTAssertThrowsError(try store.revokeDevice(id: ipad.deviceID, by: auth))
        XCTAssertEqual(try store.listAPITokens(), [])
        XCTAssertEqual(try store.listUsers().map(\.displayName), ["Chad"])
        XCTAssertNil(try store.device(id: ipad.deviceID)?.revokedAt)
        let userDirs = try FileManager.default.contentsOfDirectory(atPath: store.paths.userDirectory(admin.id).deletingLastPathComponent().path)
        XCTAssertFalse(userDirs.contains { $0 != admin.id }, "failed player creation left \(userDirs)")
    }

    func testCreatePlayerUser() async throws {
        try await app().test(.router) { client in
            let headers = self.bearer(self.adminDevice.token)
            try await client.execute(uri: "/v1/admin/users", method: .post, headers: headers,
                                     body: try self.json(CreateUserRequest(displayName: " Alex "))) { response in
                XCTAssertEqual(response.status, .created)
                let user = try self.decode(UserInfo.self, response)
                XCTAssertEqual(user.displayName, "Alex")
                XCTAssertEqual(user.role, .player)
                XCTAssertTrue(FileManager.default.fileExists(atPath: self.store.paths.userDirectory(user.id).path))
            }
            try await client.execute(uri: "/v1/admin/users", method: .post, headers: headers,
                                     body: try self.json(CreateUserRequest(displayName: ""))) { XCTAssertEqual($0.status, .badRequest) }
            try await client.execute(uri: "/v1/admin/users", method: .get, headers: headers) {
                XCTAssertEqual(try self.decode([UserInfo].self, $0).map(\.role), [.admin, .player])
            }
        }
        XCTAssertEqual(try auditActions(), ["user.create"])
    }
}
