import Foundation
import GRDB
import Hummingbird
import SupersEmuKit

/// Per-user cheat storage. Uploads merge field by field (`CheatMerge`), so replaying the same upload is a no-op.
public struct CheatStore: Sendable {
    public static let maxCodeLength = 64
    public static let maxLabelLength = 120
    public static let maxCheatsPerGame = 500
    /// Deleted cheats are forgotten after this long; a device offline for longer may bring one back.
    public static let tombstoneLifetime: TimeInterval = 90 * 24 * 3600

    let store: ServerStore
    public init(store: ServerStore) { self.store = store }

    /// `visibleTo` limits the feed to games that caller can see (hidden games are left out).
    public func changes(userID: String, since: Int, visibleTo auth: AuthContext? = nil) throws -> CheatListResponse {
        try store.db.read { db in
            var sql = "SELECT * FROM cheats WHERE user_id = ? AND revision > ?"
            var arguments: StatementArguments = [userID, since]
            if let auth, !auth.isAdmin {
                let visible = Permissions.visibleGameIDsSQL(for: auth)
                sql += " AND game_id IN (\(visible.sql))"
                arguments += visible.arguments
            }
            let rows = try Row.fetchAll(db, sql: sql + " ORDER BY revision", arguments: arguments)
            return CheatListResponse(cheats: try rows.map(Self.record), revision: try Self.head(db, userID: userID))
        }
    }

    public func list(userID: String, gameID: String) throws -> CheatListResponse {
        try store.db.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT * FROM cheats WHERE user_id = ? AND game_id = ? AND deleted = 0 ORDER BY created_at, id
                """, arguments: [userID, gameID])
            return CheatListResponse(cheats: try rows.map(Self.record), revision: try Self.head(db, userID: userID))
        }
    }

    public func put(userID: String, deviceID: String?, _ incoming: CheatRecord, now: Date = Date()) throws -> CheatRecord {
        guard incoming.code.count <= Self.maxCodeLength, !incoming.code.isEmpty else {
            throw HTTPError(.badRequest, message: "Cheat code must be 1–\(Self.maxCodeLength) characters")
        }
        guard incoming.label.count <= Self.maxLabelLength else {
            throw HTTPError(.badRequest, message: "Cheat name is too long")
        }
        return try store.db.write { db in
            try db.execute(sql: "DELETE FROM cheats WHERE user_id = ? AND deleted = 1 AND deleted_at < ?",
                           arguments: [userID, now.addingTimeInterval(-Self.tombstoneLifetime).timeIntervalSince1970])
            let existing = try Row.fetchOne(db, sql: "SELECT * FROM cheats WHERE user_id = ? AND id = ?",
                                            arguments: [userID, incoming.id.uuidString]).map(Self.record)
            if let existing, existing.gameID != incoming.gameID {
                throw HTTPError(.conflict, message: "Cheat belongs to another game")
            }
            if existing == nil {
                let count = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM cheats WHERE user_id = ? AND game_id = ? AND deleted = 0",
                                             arguments: [userID, incoming.gameID]) ?? 0
                guard count < Self.maxCheatsPerGame else { throw HTTPError(.badRequest, message: "Too many cheats for this game") }
            }
            var merged = existing.map { CheatMerge.merge($0, incoming) } ?? incoming
            if let existing {
                merged.revision = existing.revision
                if merged == existing { return existing }
            }
            merged.revision = try Self.nextRevision(db, userID: userID)
            try db.execute(sql: """
                INSERT INTO cheats (user_id, id, game_id, label, code, format, enabled, created_at, label_updated_at,
                    code_updated_at, enabled_updated_at, deleted, deleted_at, revision, updated_by_device)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(user_id, id) DO UPDATE SET label = excluded.label, code = excluded.code,
                    format = excluded.format, enabled = excluded.enabled, created_at = excluded.created_at,
                    label_updated_at = excluded.label_updated_at, code_updated_at = excluded.code_updated_at,
                    enabled_updated_at = excluded.enabled_updated_at, deleted = excluded.deleted,
                    deleted_at = excluded.deleted_at, revision = excluded.revision,
                    updated_by_device = excluded.updated_by_device
                """, arguments: [userID, merged.id.uuidString, merged.gameID, merged.label, merged.code, merged.format.rawValue,
                                 merged.enabled, merged.createdAt.timeIntervalSince1970, merged.labelUpdatedAt.timeIntervalSince1970,
                                 merged.codeUpdatedAt.timeIntervalSince1970, merged.enabledUpdatedAt.timeIntervalSince1970,
                                 merged.deleted, merged.deletedAt?.timeIntervalSince1970, merged.revision, deviceID])
            return merged
        }
    }

    static func head(_ db: Database, userID: String) throws -> Int {
        try Int.fetchOne(db, sql: "SELECT revision FROM cheat_revisions WHERE user_id = ?", arguments: [userID]) ?? 0
    }

    static func nextRevision(_ db: Database, userID: String) throws -> Int {
        try db.execute(sql: "INSERT INTO cheat_revisions (user_id, revision) VALUES (?, 1) ON CONFLICT(user_id) DO UPDATE SET revision = revision + 1",
                       arguments: [userID])
        return try head(db, userID: userID)
    }

    static func record(_ row: Row) throws -> CheatRecord {
        guard let id = UUID(uuidString: row["id"]) else { throw HTTPError(.internalServerError, message: "Bad cheat id") }
        var record = CheatRecord(id: id, gameID: row["game_id"], label: row["label"], code: row["code"],
                                 format: CheatFormat(rawValue: row["format"]) ?? .unknown, enabled: row["enabled"],
                                 now: Date(timeIntervalSince1970: row["created_at"]))
        record.labelUpdatedAt = Date(timeIntervalSince1970: row["label_updated_at"])
        record.codeUpdatedAt = Date(timeIntervalSince1970: row["code_updated_at"])
        record.enabledUpdatedAt = Date(timeIntervalSince1970: row["enabled_updated_at"])
        record.deleted = row["deleted"]
        record.deletedAt = (row["deleted_at"] as Double?).map(Date.init(timeIntervalSince1970:))
        record.revision = row["revision"]
        return record
    }
}
