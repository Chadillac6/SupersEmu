import Foundation
import GRDB
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
        try FileManager.default.createDirectory(at: paths.userDirectory(user.id), withIntermediateDirectories: true)
        try db.write { db in
            try db.execute(sql: "INSERT INTO users (id, display_name, role, created_at) VALUES (?, ?, ?, ?)",
                           arguments: [user.id, user.displayName, user.role.rawValue, Date()])
            try Self.insertAudit(db, auth, action: "user.create", detail: "\(user.id) \(user.displayName)")
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
