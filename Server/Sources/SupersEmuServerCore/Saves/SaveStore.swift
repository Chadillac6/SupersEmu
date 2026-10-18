import CryptoKit
import Foundation
import GRDB
import Hummingbird
import SupersEmuKit

public struct SaveConfiguration: Sendable {
    /// Largest accepted save body. PS1/N64 states are a few MB; 64 MiB leaves headroom.
    public var maxBytes: Int
    /// Auto-state revisions kept per game, and screenshot revisions ("auto-shot", "slot1-shot") kept per line and
    /// device. Other manual revisions and native revisions are never pruned.
    public var autoRevisionsKept: Int

    public init(maxBytes: Int = 64 << 20, autoRevisionsKept: Int = 10) {
        self.maxBytes = maxBytes
        self.autoRevisionsKept = max(1, autoRevisionsKept)
    }

    public static let standard = SaveConfiguration()
}

/// Immutable, per-user save revisions stored under `users/<userID>/saves/<game>/<rev>`.
/// Uploads never overwrite: a revision whose parent isn't the current head of its (kind, slot) line is kept as a branch.
public struct SaveStore: Sendable {
    public let store: ServerStore
    public let configuration: SaveConfiguration

    public init(store: ServerStore, configuration: SaveConfiguration = .standard) {
        self.store = store
        self.configuration = configuration
    }

    public struct Upload: Sendable {
        public var gameID: String
        public var kind: SaveKind
        public var slot: String
        public var parentID: String?
        public var coreID: String
        public var coreVersion: String
        public var deviceID: String?
        /// Optional client-computed SHA-256; the upload is rejected when it doesn't match the body.
        public var expectedSHA256: String?
        /// Keep this copy only as a branch: it never becomes the line head.
        public var keepAsBranch: Bool
        /// Keep this copy as a branch copy if `parentID` is no longer the line head (`ifHead=1`), so a stale upload
        /// never replaces another device's newer save.
        public var onlyIfHead: Bool
        public var data: Data

        public init(gameID: String, kind: SaveKind, slot: String, parentID: String?, coreID: String, coreVersion: String,
                    deviceID: String?, expectedSHA256: String? = nil, keepAsBranch: Bool = false, onlyIfHead: Bool = false,
                    data: Data) {
            self.gameID = gameID; self.kind = kind; self.slot = slot; self.parentID = parentID; self.coreID = coreID
            self.coreVersion = coreVersion; self.deviceID = deviceID; self.expectedSHA256 = expectedSHA256
            self.keepAsBranch = keepAsBranch; self.onlyIfHead = onlyIfHead; self.data = data
        }
    }

    // MARK: Validation

    /// Game IDs, slots and revision IDs become path components, so only a safe character set is accepted.
    public static func isValidIdentifier(_ value: String) -> Bool {
        guard (1...128).contains(value.count), value != ".", value != ".." else { return false }
        return value.unicodeScalars.allSatisfy { CharacterSet.alphanumerics.contains($0) && $0.isASCII || "-_.".unicodeScalars.contains($0) }
    }

    /// Phase 1: the admin may sync saves for any game (including ones only imported on a device).
    /// Players only for games `Permissions` lets them see.
    public func authorize(gameID: String, auth: AuthContext) throws {
        guard Self.isValidIdentifier(gameID) else { throw HTTPError(.badRequest, message: "Invalid game id") }
        if auth.isAdmin { return }
        let visible = try store.db.read { try Permissions.canSee(gameID: gameID, auth: auth, db: $0) }
        guard visible else { throw HTTPError(.notFound, message: "Game not found") }
    }

    // MARK: Reads

    public func list(userID: String, gameID: String) throws -> [SaveRevision] {
        try store.db.read { db in
            try Row.fetchAll(db, sql: """
                SELECT r.*, d.name AS device_name,
                       r.rowid IN (SELECT MAX(rowid) FROM save_revisions WHERE user_id = ? AND game_id = ? AND detached = 0
                                   GROUP BY kind, slot) AS is_head
                FROM save_revisions r LEFT JOIN devices d ON d.id = r.device_id
                WHERE r.user_id = ? AND r.game_id = ?
                ORDER BY r.rowid
                """, arguments: [userID, gameID, userID, gameID]).map(Self.revision(from:))
        }
    }

    /// The revision's bytes, verified against the stored SHA-256.
    /// Downloading by a device records the revision as that device's base for its line.
    public func data(userID: String, gameID: String, revisionID: String, deviceID: String? = nil) throws -> Data {
        guard Self.isValidIdentifier(revisionID) else { throw HTTPError(.notFound, message: "Save not found") }
        let row = try store.db.read { db in
            try Row.fetchOne(db, sql: "SELECT * FROM save_revisions WHERE id = ? AND user_id = ? AND game_id = ?",
                             arguments: [revisionID, userID, gameID])
        }
        guard let row else { throw HTTPError(.notFound, message: "Save not found") }
        let data = try Data(contentsOf: store.paths.root.appendingPathComponent(row["stored_path"] as String))
        guard Self.sha256(data) == row["sha256"] as String else {
            throw HTTPError(.internalServerError, message: "Stored save failed its integrity check")
        }
        if let deviceID, !(row["detached"] as Bool) {
            try store.db.write { try Self.recordBase(db: $0, userID: userID, deviceID: deviceID, row: row) }
        }
        return data
    }

    // MARK: Writes

    public func upload(userID: String, _ upload: Upload) throws -> SaveUploadResponse {
        guard Self.isValidIdentifier(upload.gameID) else { throw HTTPError(.badRequest, message: "Invalid game id") }
        switch upload.kind {
        case .native, .auto:
            guard upload.slot.isEmpty else { throw HTTPError(.badRequest, message: "\(upload.kind.rawValue) saves have no slot") }
        case .manual:
            guard Self.isValidIdentifier(upload.slot) else { throw HTTPError(.badRequest, message: "Manual states need a valid slot") }
        }
        if let parentID = upload.parentID, !Self.isValidIdentifier(parentID) {
            throw HTTPError(.badRequest, message: "Invalid parent revision")
        }
        guard (1...128).contains(upload.coreID.count), (1...128).contains(upload.coreVersion.count) else {
            throw HTTPError(.badRequest, message: "core and coreVersion are required (at most 128 characters)")
        }
        guard upload.data.count <= configuration.maxBytes else { throw HTTPError(.contentTooLarge, message: "Save is too large") }
        let sha = Self.sha256(upload.data)
        if let expected = upload.expectedSHA256, expected.lowercased() != sha {
            throw HTTPError(.badRequest, message: "SHA-256 mismatch: the upload was corrupted")
        }

        let revisionID = UUID().uuidString.lowercased()
        let relativeDirectory = "users/\(userID)/saves/\(upload.gameID)"
        let relativePath = "\(relativeDirectory)/\(revisionID)"
        let fileURL = store.paths.root.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(at: store.paths.root.appendingPathComponent(relativeDirectory, isDirectory: true),
                                                withIntermediateDirectories: true)
        try upload.data.write(to: fileURL, options: .atomic)

        let outcome: (response: SaveUploadResponse, inserted: Bool, pruned: [String])
        do {
            outcome = try store.db.write { db in
                let line: StatementArguments = [userID, upload.gameID, upload.kind.rawValue, upload.slot]
                let lineSQL = "user_id = ? AND game_id = ? AND kind = ? AND slot = ?"
                let head = try Row.fetchOne(db, sql: "SELECT id, sha256, parent_id, device_id FROM save_revisions WHERE \(lineSQL) AND detached = 0 ORDER BY rowid DESC LIMIT 1",
                                            arguments: line)
                let headID: String? = head?["id"]
                let stale = headID != nil && headID != upload.parentID
                let detached = upload.keepAsBranch || (upload.onlyIfHead && stale)

                // An `ifHead` retry whose first attempt (lost response) became the head now looks stale: return that head.
                // A historical attached match is not reused, so a stale device still gets a branch copy and the real head.
                let retryOfHead = !upload.keepAsBranch && upload.onlyIfHead && stale && head?["sha256"] == sha
                    && (head?["parent_id"] as String?) == upload.parentID && (head?["device_id"] as String?) == upload.deviceID
                // Retries after a lost response, and unchanged content on top of the head, return the existing revision.
                if let existingID = try (retryOfHead ? headID : nil) ?? String.fetchOne(db, sql: """
                    SELECT id FROM save_revisions WHERE \(lineSQL) AND sha256 = ? AND parent_id IS ? AND detached = ?
                    ORDER BY rowid DESC LIMIT 1
                    """, arguments: line + [sha, upload.parentID, detached])
                    ?? (!detached && head?["sha256"] == sha && headID == upload.parentID ? headID : nil) {
                    let existing = try revision(db, userID: userID, gameID: upload.gameID, id: existingID)
                    if let deviceID = upload.deviceID,
                       let row = try Row.fetchOne(db, sql: "SELECT * FROM save_revisions WHERE id = ? AND detached = 0",
                                                  arguments: [existingID]) {
                        try Self.recordBase(db: db, userID: userID, deviceID: deviceID, row: row)
                    }
                    return (SaveUploadResponse(revision: existing.revision, branched: existing.branched), false, [])
                }

                let branched = upload.keepAsBranch || stale
                try db.execute(sql: """
                    INSERT INTO save_revisions (id, user_id, game_id, kind, slot, parent_id, sha256, size, core_id, core_version,
                                                device_id, stored_path, created_at, branched, detached)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """, arguments: [revisionID, userID, upload.gameID, upload.kind.rawValue, upload.slot, upload.parentID, sha,
                                     upload.data.count, upload.coreID, upload.coreVersion, upload.deviceID, relativePath, Date(), branched,
                                     detached])
                if let deviceID = upload.deviceID, !detached,
                   let row = try Row.fetchOne(db, sql: "SELECT * FROM save_revisions WHERE id = ?", arguments: [revisionID]) {
                    try Self.recordBase(db: db, userID: userID, deviceID: deviceID, row: row)
                }
                let pruned: [String]
                if upload.kind == .auto {
                    pruned = try pruneAutoRevisions(db, userID: userID, gameID: upload.gameID)
                } else if upload.kind == .manual, Self.isScreenshotSlot(upload.slot) {
                    pruned = try pruneScreenshotRevisions(db, userID: userID, gameID: upload.gameID, slot: upload.slot)
                } else {
                    pruned = []
                }
                let inserted = try revision(db, userID: userID, gameID: upload.gameID, id: revisionID)
                return (SaveUploadResponse(revision: inserted.revision, branched: branched), true, pruned)
            }
        } catch {
            try? FileManager.default.removeItem(at: fileURL)
            throw error
        }
        if !outcome.inserted { try? FileManager.default.removeItem(at: fileURL) }
        for path in outcome.pruned { try? FileManager.default.removeItem(at: store.paths.root.appendingPathComponent(path)) }
        return outcome.response
    }

    private static func recordBase(db: Database, userID: String, deviceID: String, row: Row) throws {
        try db.execute(sql: """
            INSERT INTO save_device_bases (user_id, device_id, game_id, kind, slot, revision_id) VALUES (?, ?, ?, ?, ?, ?)
            ON CONFLICT (device_id, game_id, kind, slot) DO UPDATE SET revision_id = excluded.revision_id
            """, arguments: [userID, deviceID, row["game_id"] as String, row["kind"] as String, row["slot"] as String, row["id"] as String])
    }

    /// Keeps the newest `autoRevisionsKept` auto states per game. Never removes a line head or a revision a device
    /// last synced (its base), so ancestry stays provable for devices that were away, nor a device's newest branch copy
    /// (offline progress it may not have resolved yet).
    private func pruneAutoRevisions(_ db: Database, userID: String, gameID: String) throws -> [String] {
        let rows = try Row.fetchAll(db, sql: """
            SELECT id, stored_path FROM save_revisions
            WHERE user_id = ? AND game_id = ? AND kind = 'auto'
              AND rowid NOT IN (SELECT MAX(rowid) FROM save_revisions WHERE user_id = ? AND game_id = ? AND kind = 'auto'
                                AND detached = 0 GROUP BY slot)
              AND rowid NOT IN (SELECT MAX(rowid) FROM save_revisions WHERE user_id = ? AND game_id = ? AND kind = 'auto'
                                AND detached = 1 GROUP BY slot, device_id)
              AND id NOT IN (SELECT revision_id FROM save_device_bases WHERE user_id = ? AND game_id = ?)
            ORDER BY rowid DESC LIMIT -1 OFFSET ?
            """, arguments: [userID, gameID, userID, gameID, userID, gameID, userID, gameID,
                                configuration.autoRevisionsKept - 1])
        return try deleteRevisions(rows, db: db, userID: userID, gameID: gameID)
    }

    /// The screenshot lines the app writes: "auto-shot" and "slot<N>-shot". Any other manual slot keeps its history.
    static func isScreenshotSlot(_ slot: String) -> Bool {
        if slot == "auto-shot" { return true }
        guard slot.hasPrefix("slot"), slot.hasSuffix("-shot") else { return false }
        let number = slot.dropFirst(4).dropLast(5)
        return !number.isEmpty && number.allSatisfy(\.isASCII) && number.allSatisfy(\.isNumber)
    }

    /// Screenshots are previews, not progress: keeps the newest `autoRevisionsKept` per device on one screenshot line
    /// (enough to match the auto states kept), plus the line head and any device's base.
    private func pruneScreenshotRevisions(_ db: Database, userID: String, gameID: String, slot: String) throws -> [String] {
        let rows = try Row.fetchAll(db, sql: """
            SELECT id, stored_path FROM (
                SELECT id, stored_path, rowid AS rid,
                       ROW_NUMBER() OVER (PARTITION BY device_id ORDER BY rowid DESC) AS rank
                FROM save_revisions WHERE user_id = ? AND game_id = ? AND kind = 'manual' AND slot = ?)
            WHERE rank > ?
              AND rid NOT IN (SELECT MAX(rowid) FROM save_revisions WHERE user_id = ? AND game_id = ? AND kind = 'manual'
                              AND slot = ? AND detached = 0)
              AND id NOT IN (SELECT revision_id FROM save_device_bases WHERE user_id = ? AND game_id = ?)
            """, arguments: [userID, gameID, slot, configuration.autoRevisionsKept, userID, gameID, slot, userID, gameID])
        return try deleteRevisions(rows, db: db, userID: userID, gameID: gameID)
    }

    private func deleteRevisions(_ rows: [Row], db: Database, userID: String, gameID: String) throws -> [String] {
        for row in rows {
            // Re-parent children onto the pruned revision's parent so every kept revision still traces back
            // through `parentID` to the bases it descends from.
            let id: String = row["id"]
            try db.execute(sql: """
                UPDATE save_revisions SET parent_id = (SELECT parent_id FROM save_revisions WHERE id = ?)
                WHERE parent_id = ? AND user_id = ? AND game_id = ?
                """, arguments: [id, id, userID, gameID])
            try db.execute(sql: "DELETE FROM save_revisions WHERE id = ?", arguments: [id])
        }
        return rows.map { $0["stored_path"] }
    }

    private func revision(_ db: Database, userID: String, gameID: String, id: String) throws -> (revision: SaveRevision, branched: Bool) {
        guard let row = try Row.fetchOne(db, sql: """
            SELECT r.*, d.name AS device_name,
                   r.rowid = (SELECT MAX(rowid) FROM save_revisions h WHERE h.user_id = r.user_id AND h.game_id = r.game_id
                                                                       AND h.kind = r.kind AND h.slot = r.slot
                                                                       AND h.detached = 0) AS is_head
            FROM save_revisions r LEFT JOIN devices d ON d.id = r.device_id
            WHERE r.id = ? AND r.user_id = ? AND r.game_id = ?
            """, arguments: [id, userID, gameID]) else {
            throw HTTPError(.notFound, message: "Save not found")
        }
        return (Self.revision(from: row), row["branched"])
    }

    static func revision(from row: Row) -> SaveRevision {
        SaveRevision(
            id: row["id"], gameID: row["game_id"], kind: SaveKind(rawValue: row["kind"]) ?? .manual, slot: row["slot"],
            parentID: row["parent_id"], sha256: row["sha256"], size: row["size"], coreID: row["core_id"],
            coreVersion: row["core_version"], deviceID: row["device_id"], createdAt: row["created_at"], isHead: row["is_head"],
            deviceName: row["device_name"], isBranchCopy: row["detached"])
    }

    public static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
