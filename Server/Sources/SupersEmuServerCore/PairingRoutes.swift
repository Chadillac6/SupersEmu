import CryptoKit
import Foundation
import GRDB
import Hummingbird
import SupersEmuKit
import Synchronization

extension PairingCode: ResponseEncodable {}
extension PairResponse: ResponseEncodable {}

// Track: pairing + network. POST /v1/admin/pairing-codes, POST /v1/pair.
func registerPairingRoutes(public publicGroup: RouterGroup<SERequestContext>, authed: RouterGroup<SERequestContext>, store: ServerStore) {
    let service = PairingService(store: store)

    authed.post("admin/pairing-codes") { request, context in
        let auth = try context.caller()
        try auth.requireAdmin()
        try auth.require(.usersAdmin)
        let body = try await request.decode(as: CreatePairingCodeRequest.self, context: context)
        let code = try service.createCode(for: body.userID, caller: auth)
        return EditedResponse(status: .created, response: code)
    }

    publicGroup.post("pair") { request, context in
        let client = context.remoteAddress ?? "unknown"
        guard service.limiter.allowAttempt(client: client) else {
            throw HTTPError(.tooManyRequests, message: "Too many pairing attempts. Wait a minute and try again.")
        }
        let body = try await request.decode(as: PairRequest.self, context: context)
        return try service.pair(body, client: client)
    }
}

/// One-time 6-digit pairing codes. A code is bound to a user: Chad in Phase 1, an invited player in Phase 2.
/// Codes are stored salted + hashed and are consumed atomically by `/v1/pair`.
public final class PairingService: Sendable {
    public static let codeLifetime: TimeInterval = 10 * 60

    let store: ServerStore
    let now: @Sendable () -> Date
    let limiter: PairingRateLimiter

    public init(store: ServerStore, now: @escaping @Sendable () -> Date = { Date() }, limiter: PairingRateLimiter = PairingRateLimiter()) {
        self.store = store
        self.now = now
        self.limiter = limiter
    }

    public func createCode(for userID: String?, caller: AuthContext) throws -> PairingCode {
        let user: UserInfo
        if let userID {
            guard let target = try store.db.read({ db in
                try Row.fetchOne(db, sql: "SELECT * FROM users WHERE id = ? AND revoked_at IS NULL", arguments: [userID])
            }) else { throw HTTPError(.notFound, message: "No such user") }
            user = ServerStore.user(from: target)
        } else {
            user = caller.user
        }

        let created = now()
        let expires = created.addingTimeInterval(Self.codeLifetime)
        let code = try store.db.write { db -> String in
            // Never hand out a code that collides with another live one.
            let live = try Row.fetchAll(db, sql: "SELECT salt, code_hash, expires_at FROM pairing_codes WHERE used_at IS NULL")
                .filter { ($0["expires_at"] as Date) > created }
            var code = Self.randomCode()
            while live.contains(where: { Self.hash(code, salt: $0["salt"]) == $0["code_hash"] }) { code = Self.randomCode() }
            let salt = UUID().uuidString
            try db.execute(sql: """
                INSERT INTO pairing_codes (id, user_id, created_by_user_id, salt, code_hash, created_at, expires_at)
                VALUES (?, ?, ?, ?, ?, ?, ?)
                """, arguments: [UUID().uuidString.lowercased(), user.id, caller.user.id, salt, Self.hash(code, salt: salt), created, expires])
            return code
        }
        try store.audit(caller, action: "pairing.code_created", detail: "user=\(user.id)")

        let environment = PairingEnvironment.resolve(for: store)
        let payload = PairingPayload(serverName: store.serverName, urls: environment.urls,
                                     certificateSHA256: environment.certificateSHA256, code: code)
        return PairingCode(code: code, expiresAt: expires, payload: payload, qrURL: try PairingLink.url(for: payload).absoluteString)
    }

    /// Consumes `request.code` and issues a device token for the code's user.
    public func pair(_ request: PairRequest, client: String = "local") throws -> PairResponse {
        let code = request.code.filter(\.isNumber)
        let deviceName = request.deviceName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard code.count == 6 else {
            limiter.recordFailure(client: client)
            throw HTTPError(.unauthorized, message: "Invalid or expired pairing code")
        }
        guard !deviceName.isEmpty, deviceName.count <= 100 else { throw HTTPError(.badRequest, message: "deviceName is required") }

        let at = now()
        let platform = String(request.platform.prefix(40))
        // Claim the code, create the device and audit in one transaction so a failure leaves the code usable.
        let paired: (user: UserInfo, deviceID: String, token: String)? = try store.db.write { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT p.id AS code_id, p.salt, p.code_hash, u.*
                FROM pairing_codes p JOIN users u ON u.id = p.user_id
                WHERE p.used_at IS NULL AND p.expires_at > ? AND u.revoked_at IS NULL
                """, arguments: [at])
            guard let row = rows.first(where: { Self.hash(code, salt: $0["salt"]) == $0["code_hash"] }) else { return nil }
            let codeID: String = row["code_id"]
            let user = ServerStore.user(from: row)
            let token = ServerStore.newToken(prefix: "sed_")
            let deviceID = UUID().uuidString.lowercased()
            try db.execute(sql: "UPDATE pairing_codes SET used_at = ?, device_platform = ?, device_id = ? WHERE id = ? AND used_at IS NULL",
                           arguments: [at, platform, deviceID, codeID])
            guard db.changesCount == 1 else { return nil }
            try db.execute(sql: "INSERT INTO devices (id, user_id, name, token_hash, created_at) VALUES (?, ?, ?, ?, ?)",
                           arguments: [deviceID, user.id, deviceName, ServerStore.hash(token), at])
            let actor = AuthContext(user: user, credential: .device(id: deviceID))
            try db.execute(sql: "INSERT INTO audit_log (at, actor_user_id, actor_credential, action, detail) VALUES (?, ?, ?, ?, ?)",
                           arguments: [at, user.id, actor.credentialID, "pairing.device_paired", "device=\(deviceName) platform=\(platform)"])
            return (user, deviceID, token)
        }
        guard let paired else {
            limiter.recordFailure(client: client)
            throw HTTPError(.unauthorized, message: "Invalid or expired pairing code")
        }
        return PairResponse(token: paired.token, deviceID: paired.deviceID, user: paired.user, serverName: store.serverName)
    }

    static func randomCode() -> String {
        var generator = SystemRandomNumberGenerator()
        return String(format: "%06d", Int.random(in: 0..<1_000_000, using: &generator))
    }

    static func hash(_ code: String, salt: String) -> String {
        SHA256.hash(data: Data("\(salt):\(code)".utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

/// Limits failed `/v1/pair` attempts per client IP (5 a minute by default), with a higher global ceiling so many
/// addresses can't brute-force together: at 60 failures a minute a 10-minute code faces at most ~600 guesses of
/// 1,000,000. One client's failures don't lock out others until the ceiling is reached.
public final class PairingRateLimiter: Sendable {
    let maxFailures: Int
    let maxGlobalFailures: Int
    let window: TimeInterval
    let now: @Sendable () -> Date
    private let failures = Mutex<[String: [Date]]>([:])

    public init(maxFailures: Int = 5, maxGlobalFailures: Int = 60, window: TimeInterval = 60,
                now: @escaping @Sendable () -> Date = { Date() }) {
        self.maxFailures = maxFailures
        self.maxGlobalFailures = maxGlobalFailures
        self.window = window
        self.now = now
    }

    public func allowAttempt(client: String) -> Bool {
        let cutoff = now().addingTimeInterval(-window)
        return failures.withLock { failures in
            for key in Array(failures.keys) {
                failures[key]?.removeAll { $0 < cutoff }
                if failures[key]?.isEmpty == true { failures[key] = nil }
            }
            let total = failures.values.reduce(0) { $0 + $1.count }
            return (failures[client]?.count ?? 0) < maxFailures && total < maxGlobalFailures
        }
    }

    public func recordFailure(client: String) {
        let at = now()
        failures.withLock { $0[client, default: []].append(at) }
    }
}

enum PairingMigrations {
    static func register(_ migrator: inout DatabaseMigrator) {
        migrator.registerMigration("v2_pairing_codes") { db in
            try db.execute(sql: """
                CREATE TABLE pairing_codes (
                    id TEXT PRIMARY KEY,
                    user_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
                    created_by_user_id TEXT,
                    salt TEXT NOT NULL,
                    code_hash TEXT NOT NULL,
                    created_at DATETIME NOT NULL,
                    expires_at DATETIME NOT NULL,
                    used_at DATETIME,
                    device_id TEXT,
                    device_platform TEXT
                );
                CREATE INDEX pairing_codes_unused ON pairing_codes (used_at, expires_at);
                """)
        }
    }
}
