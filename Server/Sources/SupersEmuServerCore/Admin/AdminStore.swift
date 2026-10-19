import Foundation
import GRDB
import Hummingbird
import Network
import Security
import SupersEmuKit
import SwiftASN1
import X509

/// Where `/v1/admin/remote-access` gets the public-access state it reports.
public enum RemoteAccessSource: Sendable {
    /// `public-access.json` as saved. For routers not started by `ServerLauncher`.
    case storedFile
    /// What the running public listener serves, command-line overrides included. Nil when it isn't running.
    case listener(PublicAccessConfiguration?)
}

/// Queries behind the users/devices/tokens admin API. Never exposes token hashes.
extension ServerStore {
    public func remoteAccessStatus(source: RemoteAccessSource = .storedFile) async -> RemoteAccessStatusResponse {
        // Same reader as the launcher, so an invalid file shows as off here just as the listener treats it.
        let stored = (try? PublicAccessConfiguration.stored(root: paths.root)) ?? nil
        let config: PublicAccessConfiguration?
        switch source {
        case .storedFile:
            config = stored
        case .listener(let active):
            // Off keeps the saved URL so the app can show and re-enable it.
            config = active ?? stored.map { var off = $0; off.enabled = false; return off }
        }
        let publicURL = config?.publicURL
        let ddnsURL = paths.root.appendingPathComponent("ddns-state.json")
        let ddns = (try? Data(contentsOf: ddnsURL)).flatMap {
            try? SupersEmuJSON.decoder().decode(RemoteAccessDDNSState.self, from: $0)
        }
        var certificateValidUntil = publicURL.flatMap { certificateExpiry(for: $0.host) }
        if certificateValidUntil == nil, let host = publicURL?.host {
            certificateValidUntil = await certificateExpiryFromTLS(host: host)
        }
        return RemoteAccessStatusResponse(
            enabled: config?.enabled ?? false,
            publicURL: publicURL,
            tokenSaved: FileManager.default.fileExists(atPath: paths.root.appendingPathComponent("cloudflare.token").path),
            ddnsIP: ddns?.ip,
            ddnsUpdatedAt: ddns?.updatedAt,
            ddnsLastCheckAt: ddns?.lastCheckAt,
            ddnsLastError: ddns?.lastError,
            certificateValidUntil: certificateValidUntil)
    }

    private func certificateExpiry(for host: String?) -> Date? {
        guard let host else { return nil }
        let certificates = paths.root.appendingPathComponent("caddy/caddy/certificates", isDirectory: true)
        guard let files = FileManager.default.enumerator(at: certificates, includingPropertiesForKeys: nil) else { return nil }
        for case let file as URL in files
        where file.lastPathComponent == "\(host).crt" && file.deletingLastPathComponent().lastPathComponent == host {
            guard let pem = try? String(contentsOf: file, encoding: .utf8),
                  let certificate = try? Certificate(pemEncoded: pem),
                  CertificateHostMatcher.matches(host: host, certificate: certificate) else { continue }
            return certificate.notValidAfter
        }
        return nil
    }

    private func certificateExpiryFromTLS(host: String) async -> Date? {
        let queue = DispatchQueue(label: "com.chadillac6.supersemu.remote-access-certificate")
        let capturedExpiry = CertificateExpiryCapture()
        let handshake = CertificateExpiryHandshake()
        let tlsOptions = NWProtocolTLS.Options()
        host.withCString {
            sec_protocol_options_set_tls_server_name(tlsOptions.securityProtocolOptions, $0)
        }
        sec_protocol_options_set_verify_block(tlsOptions.securityProtocolOptions, { _, trustReference, complete in
            let trust = sec_trust_copy_ref(trustReference).takeRetainedValue()
            if let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate],
               let leaf = chain.first,
               let certificate = try? Certificate(leaf),
               CertificateHostMatcher.matches(host: host, certificate: certificate) {
                capturedExpiry.store(certificate.notValidAfter)
            }
            complete(true)
        }, queue)

        let connection = NWConnection(
            host: NWEndpoint.Host("127.0.0.1"),
            port: 443,
            using: NWParameters(tls: tlsOptions))
        let timeout = DispatchWorkItem {
            if handshake.finish(nil) { connection.cancel() }
        }
        return await withCheckedContinuation { continuation in
            handshake.install(continuation)
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    timeout.cancel()
                    if handshake.finish(capturedExpiry.value) { connection.cancel() }
                case .failed, .cancelled:
                    timeout.cancel()
                    handshake.finish(nil)
                default:
                    break
                }
            }
            queue.asyncAfter(deadline: .now() + .seconds(3), execute: timeout)
            connection.start(queue: queue)
        }
    }

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

    public func setUserGames(userID: String, hiddenGameIDs: [String], by auth: AuthContext) throws -> UserGameAccess {
        guard hiddenGameIDs.count <= 10_000 else {
            throw HTTPError(.badRequest, message: "At most 10000 game IDs are allowed")
        }
        let requested = Array(Set(hiddenGameIDs)).sorted()
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

            let previouslyHidden = Set(try String.fetchAll(
                db, sql: "SELECT game_id FROM user_hidden_games WHERE user_id = ?", arguments: [userID]))
            try db.execute(sql: "DELETE FROM user_hidden_games WHERE user_id = ?", arguments: [userID])
            // Devices skipped these games' cheats while they were hidden; give them new revisions so they arrive.
            try CheatStore.republish(db, userID: userID, gameIDs: previouslyHidden.subtracting(requested))
            for gameID in requested {
                try db.execute(sql: """
                    INSERT INTO user_hidden_games (user_id, game_id) VALUES (?, ?)
                    """, arguments: [userID, gameID])
            }
            try Self.insertAudit(db, auth, action: "library.user_games",
                                 detail: "user=\(userID) hidden=\(requested.count)")
            return try Self.userGameAccess(db, userID: userID)
        }
    }

    public func updateUser(id: String, displayName: String, by auth: AuthContext) throws -> UserInfo {
        try db.write { db in
            guard let row = try Row.fetchOne(db, sql: "SELECT * FROM users WHERE id = ? AND revoked_at IS NULL",
                                             arguments: [id]) else {
                throw HTTPError(.notFound, message: "No user \(id)")
            }
            var user = Self.user(from: row)
            user.displayName = displayName
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
            try db.execute(sql: "DELETE FROM user_hidden_games WHERE user_id = ?", arguments: [id])
            try Self.insertAudit(db, auth, action: "users.remove", detail: "user=\(id)")
            return user
        }
    }

    private static func userGameAccess(_ db: Database, userID: String) throws -> UserGameAccess {
        let hiddenGameIDs = try String.fetchAll(db, sql: """
            SELECT game_id FROM user_hidden_games WHERE user_id = ? ORDER BY game_id
            """, arguments: [userID])
        return UserGameAccess(userID: userID, hiddenGameIDs: hiddenGameIDs)
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

enum CertificateHostMatcher {
    static func matches(host: String, certificate: Certificate) -> Bool {
        guard let names = try? certificate.extensions.subjectAlternativeNames else { return false }
        return matches(host: host, dnsNames: names.compactMap { name in
            if case .dnsName(let dnsName) = name { return dnsName }
            return nil
        })
    }

    static func matches(host: String, dnsNames: [String]) -> Bool {
        let normalizedHost = host.lowercased()
        guard !normalizedHost.isEmpty else { return false }
        let hostLabels = normalizedHost.split(separator: ".", omittingEmptySubsequences: false)
        guard !hostLabels.contains(where: { $0.isEmpty }) else { return false }

        return dnsNames.contains { dnsName in
            let normalizedName = dnsName.lowercased()
            if normalizedName == normalizedHost { return true }
            guard normalizedName.hasPrefix("*.") else { return false }
            let suffixLabels = normalizedName.dropFirst(2).split(separator: ".", omittingEmptySubsequences: false)
            return !suffixLabels.isEmpty
                && !suffixLabels.contains(where: { $0.isEmpty })
                && hostLabels.count == suffixLabels.count + 1
                && hostLabels.dropFirst().elementsEqual(suffixLabels)
        }
    }
}

private final class CertificateExpiryCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var expiry: Date?

    var value: Date? { lock.withLock { expiry } }

    func store(_ expiry: Date) { lock.withLock { self.expiry = expiry } }
}

private final class CertificateExpiryHandshake: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Date?, Never>?

    func install(_ continuation: CheckedContinuation<Date?, Never>) {
        lock.withLock { self.continuation = continuation }
    }

    @discardableResult
    func finish(_ expiry: Date?) -> Bool {
        let continuation = lock.withLock { () -> CheckedContinuation<Date?, Never>? in
            defer { self.continuation = nil }
            return self.continuation
        }
        continuation?.resume(returning: expiry)
        return continuation != nil
    }
}

private struct RemoteAccessDDNSState: Decodable {
    var ip: String?
    var updatedAt: Date?
    var lastCheckAt: Date?
    var lastError: String?
}
