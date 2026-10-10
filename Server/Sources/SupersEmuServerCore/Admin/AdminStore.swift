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
            try Row.fetchAll(db, sql: "SELECT id, user_id, name, created_at, last_seen_at, revoked_at FROM devices ORDER BY created_at")
                .map(Self.device(from:))
        }
    }

    public func device(id: String) throws -> DeviceInfo? {
        try db.read { db in
            try Row.fetchOne(db, sql: "SELECT id, user_id, name, created_at, last_seen_at, revoked_at FROM devices WHERE id = ?", arguments: [id])
                .map(Self.device(from:))
        }
    }

    public func listAPITokens() throws -> [TokenInfo] {
        try db.read { db in
            try Row.fetchAll(db, sql: "SELECT id, name, scopes, created_at, revoked_at FROM api_tokens ORDER BY created_at")
                .map { Self.tokenInfo(from: $0, plaintext: nil) }
        }
    }

    public func apiToken(id: String) throws -> TokenInfo? {
        try db.read { db in
            try Row.fetchOne(db, sql: "SELECT id, name, scopes, created_at, revoked_at FROM api_tokens WHERE id = ?", arguments: [id])
                .map { Self.tokenInfo(from: $0, plaintext: nil) }
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
