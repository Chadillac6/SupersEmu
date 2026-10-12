import Foundation
import GRDB
import Hummingbird
import SupersEmuKit

/// Queries behind the users/devices/tokens admin API. Never exposes token hashes.
extension ServerStore {
    public func adminStatus() throws -> AdminStatus {
        let counts = try db.read { db in
            (games: try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM games WHERE needs_review = 0") ?? 0,
             review: try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM games WHERE needs_review = 1") ?? 0,
             users: try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM users WHERE revoked_at IS NULL") ?? 0,
             devices: try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM devices WHERE revoked_at IS NULL") ?? 0)
        }
        return AdminStatus(
            health: HealthResponse(status: "ok", serverName: serverName, serverVersion: ServerInfo.version),
            dataDirectory: paths.root.path, freeBytes: Self.freeBytes(at: paths.root),
            gameCount: counts.games, reviewCount: counts.review, userCount: counts.users, deviceCount: counts.devices)
    }

    static func freeBytes(at url: URL) -> Int64? {
        let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeAvailableCapacityKey])
        if let important = values?.volumeAvailableCapacityForImportantUsage, important > 0 { return important }
        return values?.volumeAvailableCapacity.map(Int64.init)
    }

    public func listUsers() throws -> [UserInfo] {
        try db.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM users WHERE revoked_at IS NULL ORDER BY created_at, display_name").map(Self.user(from:))
        }
    }

    public func userGameAccess(userID: String) throws -> UserGameAccess {
        try db.read { db in
            guard try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM users WHERE id = ? AND revoked_at IS NULL)",
                                   arguments: [userID]) == true else {
                throw HTTPError(.notFound, message: "No user \(userID)")
            }
            return try Self.userGameAccess(db, userID: userID)
        }
    }

    public func setUserGames(userID: String, gameIDs: [String], by auth: AuthContext) throws -> UserGameAccess {
        guard gameIDs.count <= 10_000 else {
            throw HTTPError(.badRequest, message: "At most 10000 game IDs are allowed")
        }
        let requested = Array(Set(gameIDs)).sorted()
        return try db.write { db in
            guard let row = try Row.fetchOne(db, sql: "SELECT * FROM users WHERE id = ? AND revoked_at IS NULL",
                                             arguments: [userID]) else {
                throw HTTPError(.notFound, message: "No user \(userID)")
            }
            guard Role(rawValue: row["role"]) == .player else {
                throw HTTPError(.badRequest, message: "Admins see every game")
            }

            var existing = Set<String>()
            for start in stride(from: 0, to: requested.count, by: 500) {
                let end = min(start + 500, requested.count)
                let chunk = Array(requested[start..<end])
                let placeholders = Array(repeating: "?", count: chunk.count).joined(separator: ",")
                existing.formUnion(try String.fetchAll(
                    db, sql: "SELECT id FROM games WHERE id IN (\(placeholders))", arguments: StatementArguments(chunk)))
            }
            let unknown = Set(requested).subtracting(existing)
            guard unknown.isEmpty else {
                throw HTTPError(.badRequest, message: "Unknown game IDs: \(unknown.sorted().joined(separator: ", "))")
            }

            try db.execute(sql: "DELETE FROM game_permissions WHERE principal_type = 'user' AND principal_id = ?",
                           arguments: [userID])
            for gameID in requested {
                try db.execute(sql: """
                    INSERT INTO game_permissions (game_id, principal_type, principal_id) VALUES (?, 'user', ?)
                    """, arguments: [gameID, userID])
            }
            try Self.insertAudit(db, auth, action: "library.user_games", detail: "user=\(userID) count=\(requested.count)")
            return try Self.userGameAccess(db, userID: userID)
        }
    }

    public func updateUser(id: String, displayName: String, by auth: AuthContext) throws -> UserInfo {
        try db.write { db in
            guard let row = try Row.fetchOne(db, sql: "SELECT * FROM users WHERE id = ? AND revoked_at IS NULL",
                                             arguments: [id]) else {
                throw HTTPError(.notFound, message: "No user \(id)")
            }
            let user = UserInfo(id: id, displayName: displayName, role: Role(rawValue: row["role"]) ?? .player)
            try db.execute(sql: "UPDATE users SET display_name = ? WHERE id = ?", arguments: [displayName, id])
            try Self.insertAudit(db, auth, action: "users.rename", detail: "user=\(id)")
            return user
        }
    }

    public func removeUser(id: String, by auth: AuthContext) throws -> UserInfo {
        try db.write { db in
            guard let row = try Row.fetchOne(db, sql: "SELECT * FROM users WHERE id = ? AND revoked_at IS NULL",
                                             arguments: [id]) else {
                throw HTTPError(.notFound, message: "No user \(id)")
            }
            let user = Self.user(from: row)
            guard user.role == .player else {
                throw HTTPError(.badRequest, message: "Admins cannot be removed")
            }
            let revokedAt = Date()
            try db.execute(sql: "UPDATE users SET revoked_at = ? WHERE id = ?", arguments: [revokedAt, id])
            try db.execute(sql: "UPDATE devices SET revoked_at = ? WHERE user_id = ? AND revoked_at IS NULL",
                           arguments: [revokedAt, id])
            try db.execute(sql: "DELETE FROM game_permissions WHERE principal_type = 'user' AND principal_id = ?",
                           arguments: [id])
            try db.execute(sql: "DELETE FROM group_members WHERE user_id = ?", arguments: [id])
            try Self.insertAudit(db, auth, action: "users.remove", detail: "user=\(id)")
            return user
        }
    }

    private static func userGameAccess(_ db: Database, userID: String) throws -> UserGameAccess {
        let gameIDs = try String.fetchAll(db, sql: """
            SELECT game_id FROM game_permissions WHERE principal_type = 'user' AND principal_id = ? ORDER BY game_id
            """, arguments: [userID])
        let everyoneGameIDs = try String.fetchAll(db, sql: """
            SELECT game_id FROM game_permissions WHERE principal_type = 'everyone' ORDER BY game_id
            """)
        let groupGameIDs = try String.fetchAll(db, sql: """
            SELECT DISTINCT p.game_id FROM game_permissions p
            JOIN group_members m ON m.group_id = p.principal_id
            WHERE p.principal_type = 'group' AND m.user_id = ?
            ORDER BY p.game_id
            """, arguments: [userID])
        return UserGameAccess(userID: userID, gameIDs: gameIDs,
                              everyoneGameIDs: everyoneGameIDs, groupGameIDs: groupGameIDs)
    }

    public func listDevices() throws -> [DeviceInfo] {
        try db.read { db in
            try Row.fetchAll(db, sql: Self.deviceColumns + " ORDER BY created_at")
                .map(Self.device(from:))
        }
    }

    public func device(id: String) throws -> DeviceInfo? {
        try db.read { db in
            try Row.fetchOne(db, sql: Self.deviceColumns + " WHERE id = ?", arguments: [id])
                .map(Self.device(from:))
        }
    }

    public func listAPITokens() throws -> [TokenInfo] {
        try db.read { db in
            try Row.fetchAll(db, sql: Self.tokenColumns + " ORDER BY created_at")
                .map { Self.tokenInfo(from: $0, plaintext: nil) }
        }
    }

    public func apiToken(id: String) throws -> TokenInfo? {
        try db.read { db in
            try Row.fetchOne(db, sql: Self.tokenColumns + " WHERE id = ?", arguments: [id])
                .map { Self.tokenInfo(from: $0, plaintext: nil) }
        }
    }

    // MARK: Mutations. Each change and its audit row commit in one transaction.

    private static let deviceColumns = "SELECT id, user_id, name, created_at, last_seen_at, revoked_at FROM devices"
    private static let tokenColumns = "SELECT id, name, scopes, created_at, revoked_at FROM api_tokens"

    /// Same row as `audit(_:action:detail:)`, inside an existing write transaction.
    static func insertAudit(_ db: Database, _ auth: AuthContext, action: String, detail: String) throws {
        try db.execute(sql: "INSERT INTO audit_log (at, actor_user_id, actor_credential, action, detail) VALUES (?, ?, ?, ?, ?)",
                       arguments: [Date(), auth.user.id, auth.credentialID, action, detail])
    }

    public func createPlayer(displayName: String, by auth: AuthContext) throws -> UserInfo {
        let user = UserInfo(id: UUID().uuidString.lowercased(), displayName: displayName, role: .player)
        let directory = paths.userDirectory(user.id)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        do {
            try db.write { db in
                try db.execute(sql: "INSERT INTO users (id, display_name, role, created_at) VALUES (?, ?, ?, ?)",
                               arguments: [user.id, user.displayName, user.role.rawValue, Date()])
                try Self.insertAudit(db, auth, action: "user.create", detail: "\(user.id) \(user.displayName)")
            }
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
        return user
    }

    /// Creates an API token owned by the caller. The result carries the plaintext token (only here).
    public func createAPIToken(by auth: AuthContext, name: String, scopes: [Scope]) throws -> TokenInfo {
        let token = Self.newToken(prefix: "sek_")
        let id = UUID().uuidString.lowercased()
        let scopeList = scopes.map(\.rawValue).joined(separator: ",")
        return try db.write { db in
            try db.execute(sql: """
                INSERT INTO api_tokens (id, owner_user_id, name, scopes, token_hash, created_at) VALUES (?, ?, ?, ?, ?, ?)
                """, arguments: [id, auth.user.id, name, scopeList, Self.hash(token), Date()])
            try Self.insertAudit(db, auth, action: "token.create", detail: "\(id) \(name) [\(scopeList)]")
            guard let row = try Row.fetchOne(db, sql: Self.tokenColumns + " WHERE id = ?", arguments: [id]) else {
                throw DatabaseError(message: "token \(id) missing after insert")
            }
            return Self.tokenInfo(from: row, plaintext: token)
        }
    }

    /// Revokes a device once; later or concurrent calls keep the first `revokedAt` and aren't audited.
    /// Returns nil if there is no such device.
    public func revokeDevice(id: String, by auth: AuthContext) throws -> DeviceInfo? {
        try db.write { db in
            try db.execute(sql: "UPDATE devices SET revoked_at = ? WHERE id = ? AND revoked_at IS NULL", arguments: [Date(), id])
            let changed = db.changesCount > 0
            guard let device = try Row.fetchOne(db, sql: Self.deviceColumns + " WHERE id = ?", arguments: [id]).map(Self.device(from:)) else {
                return nil
            }
            if changed { try Self.insertAudit(db, auth, action: "device.revoke", detail: "\(id) \(device.name)") }
            return device
        }
    }

    public func revokeOwnDevice(by auth: AuthContext) throws -> DeviceInfo? {
        guard case .device(let id) = auth.credential else {
            throw HTTPError(.forbidden, message: "A device token is required")
        }
        return try db.write { db in
            try db.execute(
                sql: "UPDATE devices SET revoked_at = ? WHERE id = ? AND user_id = ? AND revoked_at IS NULL",
                arguments: [Date(), id, auth.user.id]
            )
            let changed = db.changesCount > 0
            guard let device = try Row.fetchOne(
                db, sql: Self.deviceColumns + " WHERE id = ? AND user_id = ?", arguments: [id, auth.user.id]
            ).map(Self.device(from:)) else {
                return nil
            }
            if changed { try Self.insertAudit(db, auth, action: "device.self_revoked", detail: id) }
            return device
        }
    }

    /// Revokes an API token once, like `revokeDevice(id:by:)`.
    public func revokeAPIToken(id: String, by auth: AuthContext) throws -> TokenInfo? {
        try db.write { db in
            try db.execute(sql: "UPDATE api_tokens SET revoked_at = ? WHERE id = ? AND revoked_at IS NULL", arguments: [Date(), id])
            let changed = db.changesCount > 0
            guard let info = try Row.fetchOne(db, sql: Self.tokenColumns + " WHERE id = ?", arguments: [id])
                .map({ Self.tokenInfo(from: $0, plaintext: nil) }) else { return nil }
            if changed { try Self.insertAudit(db, auth, action: "token.revoke", detail: "\(id) \(info.name)") }
            return info
        }
    }

    static func device(from row: Row) -> DeviceInfo {
        DeviceInfo(id: row["id"], userID: row["user_id"], name: row["name"], createdAt: row["created_at"],
                   lastSeenAt: row["last_seen_at"], revokedAt: row["revoked_at"])
    }

    static func tokenInfo(from row: Row, plaintext: String?) -> TokenInfo {
        let scopes = (row["scopes"] as String).split(separator: ",").compactMap { Scope(rawValue: String($0)) }
        return TokenInfo(id: row["id"], name: row["name"], scopes: scopes, createdAt: row["created_at"],
                         revokedAt: row["revoked_at"], token: plaintext)
    }
}
