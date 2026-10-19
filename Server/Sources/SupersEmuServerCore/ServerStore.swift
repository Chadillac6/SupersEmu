import CryptoKit
import Foundation
import GRDB
import SupersEmuKit

public struct ServerPaths: Sendable {
    public var root: URL
    /// Where games, BIOS, artwork, Incoming and Imported live. Defaults to `root`; Move Library points it elsewhere
    /// (`storage.json`). The database, TLS identity, tokens and saves always stay in `root`.
    public let storage: LibraryStorage
    public var database: URL { root.appendingPathComponent("library.sqlite") }
    public var libraryRoot: URL { storage.root }
    public var games: URL { libraryRoot.appendingPathComponent("games", isDirectory: true) }
    public var artwork: URL { libraryRoot.appendingPathComponent("artwork", isDirectory: true) }
    public var bios: URL { libraryRoot.appendingPathComponent("bios", isDirectory: true) }
    public var users: URL { root.appendingPathComponent("users", isDirectory: true) }
    public var incoming: URL { libraryRoot.appendingPathComponent("Incoming", isDirectory: true) }
    public var imported: URL { libraryRoot.appendingPathComponent("Imported", isDirectory: true) }
    /// Downloaded libretro-database DATs (docs/specs/metadata-and-artwork.md).
    public var metadata: URL { root.appendingPathComponent("metadata", isDirectory: true) }
    public var adminToken: URL { root.appendingPathComponent("admin.token") }
    public var storageConfig: URL { root.appendingPathComponent("storage.json") }

    /// A library file recorded in the database (`games/…`, `bios/…`, `artwork/…`), relative to the library root.
    public func libraryFile(_ storedPath: String) -> URL { libraryRoot.appendingPathComponent(storedPath) }

    /// Default for the launch daemon. Chad can point `--data-dir` at an external drive.
    public static let defaultRoot = URL(fileURLWithPath: "/Library/Application Support/SupersEmu Server", isDirectory: true)

    public init(root: URL, libraryRoot: URL? = nil) {
        self.root = root
        storage = LibraryStorage(root: libraryRoot ?? root)
    }

    public func userDirectory(_ userID: String) -> URL {
        users.appendingPathComponent(userID, isDirectory: true)
    }

    public func createDirectories() throws {
        for url in [root, users] {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }
        try createLibraryDirectories()
    }

    /// Never creates a moved library's folder: if its drive isn't mounted, that would fill the boot disk instead.
    public func createLibraryDirectories() throws {
        guard storage.isAvailable else { return }
        for url in [games, artwork, incoming] {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }
    }
}

/// Owns the database and data directory. Every track goes through this.
public final class ServerStore: @unchecked Sendable {
    public let db: any DatabaseWriter
    public let paths: ServerPaths
    public let serverName: String
    public let backups: BackupManager
    private let libraryRevisionEpoch = UUID().uuidString

    public init(db: any DatabaseWriter, paths: ServerPaths, serverName: String = Host.current().localizedName ?? "SupersEmu Server") throws {
        self.db = db
        self.paths = paths
        self.serverName = serverName
        self.backups = BackupManager(paths: paths, db: db, serverName: serverName)
        try ServerMigrations.migrator.migrate(db)
    }

    public static func open(paths: ServerPaths) throws -> ServerStore {
        try paths.storage.load(config: paths.storageConfig, dataRoot: paths.root)
        try paths.createDirectories()
        paths.storage.shareIncomingWithAdmins(paths.incoming)
        return try ServerStore(db: DatabasePool(path: paths.database.path), paths: paths)
    }

    public func close() throws { try db.close() }

    public func libraryRevision() throws -> String {
        try db.read { db in
            let value = try String.fetchOne(db, sql: "SELECT CAST(value AS TEXT) FROM library_revision WHERE id = 1") ?? "1"
            return "\(libraryRevisionEpoch):\(value)"
        }
    }

    public static func inMemory(root: URL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)) throws -> ServerStore {
        let paths = ServerPaths(root: root)
        try paths.createDirectories()
        return try ServerStore(db: DatabaseQueue(), paths: paths, serverName: "Test Server")
    }

    // MARK: Users and credentials

    @discardableResult
    public func createUser(displayName: String, role: Role) throws -> UserInfo {
        let user = UserInfo(id: UUID().uuidString.lowercased(), displayName: displayName, role: role)
        try db.write { db in
            try db.execute(sql: "INSERT INTO users (id, display_name, role, created_at) VALUES (?, ?, ?, ?)",
                           arguments: [user.id, user.displayName, user.role.rawValue, Date()])
        }
        try FileManager.default.createDirectory(at: paths.userDirectory(user.id), withIntermediateDirectories: true)
        return user
    }

    public func adminUser() throws -> UserInfo? {
        try db.read { db in
            try Row.fetchOne(db, sql: "SELECT * FROM users WHERE role = 'admin' AND revoked_at IS NULL ORDER BY created_at LIMIT 1")
                .map(Self.user(from:))
        }
    }

    /// Issues a device token for `userID`. The plaintext token is returned once; only its hash is stored.
    public func createDeviceToken(userID: String, deviceName: String) throws -> (deviceID: String, token: String) {
        let token = Self.newToken(prefix: "sed_")
        let deviceID = UUID().uuidString.lowercased()
        try db.write { db in
            try db.execute(sql: """
                INSERT INTO devices (id, user_id, name, token_hash, created_at) VALUES (?, ?, ?, ?, ?)
                """, arguments: [deviceID, userID, deviceName, Self.hash(token), Date()])
        }
        return (deviceID, token)
    }

    /// Issues a scoped API token (bots, scripts, OpenClaw) acting on behalf of `ownerUserID`.
    public func createAPIToken(ownerUserID: String, name: String, scopes: [Scope]) throws -> (tokenID: String, token: String) {
        let token = Self.newToken(prefix: "sek_")
        let tokenID = UUID().uuidString.lowercased()
        try db.write { db in
            try db.execute(sql: """
                INSERT INTO api_tokens (id, owner_user_id, name, scopes, token_hash, created_at) VALUES (?, ?, ?, ?, ?, ?)
                """, arguments: [tokenID, ownerUserID, name, scopes.map(\.rawValue).joined(separator: ","), Self.hash(token), Date()])
        }
        return (tokenID, token)
    }

    public func revokeDevice(_ deviceID: String) throws {
        try db.write { db in
            try db.execute(sql: "UPDATE devices SET revoked_at = ? WHERE id = ?", arguments: [Date(), deviceID])
        }
    }

    public func revokeAPIToken(_ tokenID: String) throws {
        try db.write { db in
            try db.execute(sql: "UPDATE api_tokens SET revoked_at = ? WHERE id = ?", arguments: [Date(), tokenID])
        }
    }

    public func authenticate(token: String) throws -> AuthContext? {
        let tokenHash = Self.hash(token)
        return try db.write { db in
            if let row = try Row.fetchOne(db, sql: """
                SELECT u.*, d.id AS device_id FROM devices d JOIN users u ON u.id = d.user_id
                WHERE d.token_hash = ? AND d.revoked_at IS NULL AND u.revoked_at IS NULL
                """, arguments: [tokenHash]) {
                let deviceID: String = row["device_id"]
                try db.execute(sql: "UPDATE devices SET last_seen_at = ? WHERE id = ?", arguments: [Date(), deviceID])
                return AuthContext(user: Self.user(from: row), credential: .device(id: deviceID))
            }
            if let row = try Row.fetchOne(db, sql: """
                SELECT u.*, t.id AS token_id, t.scopes AS token_scopes FROM api_tokens t JOIN users u ON u.id = t.owner_user_id
                WHERE t.token_hash = ? AND t.revoked_at IS NULL AND u.revoked_at IS NULL
                """, arguments: [tokenHash]) {
                let scopes = (row["token_scopes"] as String).split(separator: ",").compactMap { Scope(rawValue: String($0)) }
                return AuthContext(user: Self.user(from: row), credential: .apiToken(id: row["token_id"], scopes: Set(scopes)))
            }
            return nil
        }
    }

    public func audit(_ auth: AuthContext?, action: String, detail: String? = nil) throws {
        try db.write { db in
            try audit(auth, action: action, detail: detail, in: db)
        }
    }

    func audit(_ auth: AuthContext?, action: String, detail: String? = nil, in db: Database) throws {
        try db.execute(sql: "INSERT INTO audit_log (at, actor_user_id, actor_credential, action, detail) VALUES (?, ?, ?, ?, ?)",
                       arguments: [Date(), auth?.user.id, auth?.credentialID, action, detail])
    }

    static func user(from row: Row) -> UserInfo {
        UserInfo(id: row["id"], displayName: row["display_name"], role: Role(rawValue: row["role"]) ?? .player)
    }

    static func newToken(prefix: String) -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        precondition(SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess)
        return prefix + Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }

    public static func hash(_ token: String) -> String {
        Hashing.sha256Hex(Data(token.utf8))
    }
}
