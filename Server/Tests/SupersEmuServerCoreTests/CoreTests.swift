import Foundation
import GRDB
import Hummingbird
import HummingbirdTesting
import SupersEmuKit
@testable import SupersEmuServerCore
import XCTest

final class CoreTests: XCTestCase {
    var store: ServerStore!
    var admin: UserInfo!
    var adminToken: String!

    override func setUp() async throws {
        store = try ServerStore.inMemory()
        admin = try store.createUser(displayName: "Chad", role: .admin)
        adminToken = try store.createDeviceToken(userID: admin.id, deviceName: "Chad's iPhone").token
    }

    func app() -> some ApplicationProtocol { buildApplication(store: store, configuration: .init()) }

    func insertGame(_ id: String, title: String) throws {
        try store.db.write { db in
            try db.execute(sql: "INSERT INTO games (id, title, system, created_at) VALUES (?, ?, 'snes', ?)", arguments: [id, title, Date()])
        }
    }

    func decode<T: Decodable>(_ type: T.Type, _ response: TestResponse) throws -> T {
        try SupersEmuJSON.decoder().decode(T.self, from: Data(buffer: response.body))
    }

    func testHealthNeedsNoToken() async throws {
        try await app().test(.router) { client in
            try await client.execute(uri: "/v1/health", method: .get) { response in
                XCTAssertEqual(response.status, .ok)
                XCTAssertEqual(try self.decode(HealthResponse.self, response).apiVersion, "v1")
            }
        }
    }

    func testMeRequiresValidToken() async throws {
        try await app().test(.router) { client in
            try await client.execute(uri: "/v1/me", method: .get) { XCTAssertEqual($0.status, .unauthorized) }
            try await client.execute(uri: "/v1/me", method: .get, headers: [.authorization: "Bearer nope"]) {
                XCTAssertEqual($0.status, .unauthorized)
            }
            try await client.execute(uri: "/v1/me", method: .get, headers: [.authorization: "Bearer \(self.adminToken!)"]) { response in
                XCTAssertEqual(response.status, .ok)
                XCTAssertEqual(try self.decode(MeResponse.self, response).user.role, .admin)
            }
        }
    }

    func testRevokedDeviceIsRejected() async throws {
        let (deviceID, token) = try store.createDeviceToken(userID: admin.id, deviceName: "Old iPad")
        try store.revokeDevice(deviceID)
        try await app().test(.router) { client in
            try await client.execute(uri: "/v1/me", method: .get, headers: [.authorization: "Bearer \(token)"]) {
                XCTAssertEqual($0.status, .unauthorized)
            }
        }
    }

    func testLibraryIsFilteredByPermission() async throws {
        try insertGame("g1", title: "Alpha")
        try insertGame("g2", title: "Bravo")
        let player = try store.createUser(displayName: "Alex", role: .player)
        let playerToken = try store.createDeviceToken(userID: player.id, deviceName: "Alex's iPhone").token
        try await store.db.write { db in
            try db.execute(sql: "INSERT INTO game_permissions (game_id, principal_type, principal_id) VALUES ('g2', 'user', ?)", arguments: [player.id])
        }
        try await app().test(.router) { client in
            try await client.execute(uri: "/v1/library", method: .get, headers: [.authorization: "Bearer \(self.adminToken!)"]) {
                XCTAssertEqual(try self.decode(LibraryResponse.self, $0).games.map(\.title), ["Alpha", "Bravo"])
            }
            try await client.execute(uri: "/v1/library", method: .get, headers: [.authorization: "Bearer \(playerToken)"]) {
                XCTAssertEqual(try self.decode(LibraryResponse.self, $0).games.map(\.title), ["Bravo"])
            }
        }
    }

    func testAPITokenScopes() async throws {
        let (_, noRead) = try store.createAPIToken(ownerUserID: admin.id, name: "bot", scopes: [.usersAdmin])
        let (_, reader) = try store.createAPIToken(ownerUserID: admin.id, name: "openclaw", scopes: [.libraryRead])
        try await app().test(.router) { client in
            try await client.execute(uri: "/v1/library", method: .get, headers: [.authorization: "Bearer \(noRead)"]) {
                XCTAssertEqual($0.status, .forbidden)
            }
            try await client.execute(uri: "/v1/library", method: .get, headers: [.authorization: "Bearer \(reader)"]) {
                XCTAssertEqual($0.status, .ok)
            }
        }
    }

    func testPlayerAPITokenCannotGainAdminScopes() throws {
        let player = try store.createUser(displayName: "Alex", role: .player)
        let auth = AuthContext(user: player, credential: .apiToken(id: "t", scopes: [.libraryWrite, .usersAdmin]))
        XCTAssertFalse(auth.has(.libraryWrite))
        XCTAssertFalse(auth.has(.usersAdmin))
    }
}
