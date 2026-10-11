import CryptoKit
import Foundation
import GRDB
import Hummingbird
import SupersEmuKit
import Synchronization

extension PairingCode: ResponseEncodable {}
extension PairResponse: ResponseEncodable {}
extension PairRequestCreated: ResponseEncodable {}
extension PendingPairRequest: ResponseEncodable {}
extension PairRequestActionResponse: ResponseEncodable {}

// Track: pairing + network. POST /v1/admin/pairing-codes, POST /v1/pair.
func registerPairingRoutes(public publicGroup: RouterGroup<SERequestContext>, authed: RouterGroup<SERequestContext>, store: ServerStore) {
    let service = PairingService(store: store)
    let requests = PairRequestService(store: store, pairing: service)

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

    publicGroup.post("pair/requests") { request, context in
        let client = context.remoteAddress ?? "unknown"
        guard service.limiter.allowAttempt(client: client) else {
            throw HTTPError(.tooManyRequests, message: "Too many pairing requests. Wait a minute and try again.")
        }
        let body = try await request.decode(as: PairRequestCreate.self, context: context)
        let created = try await requests.create(body, remoteAddress: client)
        service.limiter.recordFailure(client: client)
        return EditedResponse(status: .created, response: created)
    }

    publicGroup.post("pair/requests/:id/claim") { request, context in
        let id = UUID(uuidString: try context.parameters.require("id"))
        guard let id else { throw HTTPError(.notFound, message: "No such pairing request") }
        let body = try await request.decode(as: PairRequestClaim.self, context: context)
        switch try await requests.claim(id: id, claimSecret: body.claimSecret) {
        case .pending:
            return try LibraryHTTP.json(PairRequestPending(), status: .accepted)
        case .paired(let response):
            return try LibraryHTTP.json(response)
        }
    }

    @Sendable func adminCaller(_ context: SERequestContext) throws -> AuthContext {
        let auth = try context.caller()
        try auth.requireAdmin()
        try auth.require(.usersAdmin)
        return auth
    }

    authed.get("admin/pair-requests") { _, context in
        _ = try adminCaller(context)
        return await requests.pending()
    }

    authed.post("admin/pair-requests/:id/approve") { request, context in
        let auth = try adminCaller(context)
        guard let id = UUID(uuidString: try context.parameters.require("id")) else {
            throw HTTPError(.notFound, message: "No such pairing request")
        }
        let body = try await request.decode(as: PairRequestApproval.self, context: context)
        try await requests.approve(id: id, userID: body.userID, caller: auth)
        return PairRequestActionResponse(status: "approved")
    }

    authed.post("admin/pair-requests/:id/deny") { _, context in
        let auth = try adminCaller(context)
        guard let id = UUID(uuidString: try context.parameters.require("id")) else {
            throw HTTPError(.notFound, message: "No such pairing request")
        }
        try await requests.deny(id: id, caller: auth)
        return PairRequestActionResponse(status: "denied")
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
            try db.execute(sql: "UPDATE pairing_codes SET used_at = ?, device_platform = ? WHERE id = ? AND used_at IS NULL",
                           arguments: [at, platform, codeID])
            guard db.changesCount == 1 else { return nil }
            let device = try Self.mintDevice(db: db, user: user, deviceName: deviceName, platform: platform, at: at)
            try db.execute(sql: "UPDATE pairing_codes SET device_id = ? WHERE id = ?", arguments: [device.deviceID, codeID])
            return (user, device.deviceID, device.token)
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

    func pairApprovedDevice(userID: String?, request: PendingPairRequest, caller: AuthContext) throws -> PairResponse {
        let user: UserInfo
        if let userID {
            guard let row = try store.db.read({ db in
                try Row.fetchOne(db, sql: "SELECT * FROM users WHERE id = ? AND revoked_at IS NULL", arguments: [userID])
            }) else { throw HTTPError(.notFound, message: "No such user") }
            user = ServerStore.user(from: row)
        } else {
            let ownerID = requestOwnerID
            guard let row = try store.db.read({ db in
                try Row.fetchOne(db, sql: "SELECT * FROM users WHERE id = ? AND revoked_at IS NULL", arguments: [ownerID])
            }) else { throw HTTPError(.notFound, message: "No owner user") }
            user = ServerStore.user(from: row)
        }
        let at = now()
        let device = try store.db.write { db in
            let device = try Self.mintDevice(db: db, user: user, deviceName: request.deviceName, platform: request.platform, at: at)
            try db.execute(sql: "INSERT INTO audit_log (at, actor_user_id, actor_credential, action, detail) VALUES (?, ?, ?, ?, ?)",
                           arguments: [at, caller.user.id, caller.credentialID, "pairing.request_approved", "id=\(request.id) user=\(user.id)"])
            return device
        }
        return PairResponse(token: device.token, deviceID: device.deviceID, user: user, serverName: store.serverName)
    }

    private var requestOwnerID: String {
        (try? store.db.read { db in
            try String.fetchOne(db, sql: "SELECT id FROM users WHERE role = 'admin' AND revoked_at IS NULL ORDER BY created_at LIMIT 1")
        }) ?? ""
    }

    private static func mintDevice(db: Database, user: UserInfo, deviceName: String, platform: String, at: Date) throws
        -> (deviceID: String, token: String) {
        let token = ServerStore.newToken(prefix: "sed_")
        let deviceID = UUID().uuidString.lowercased()
        try db.execute(sql: "INSERT INTO devices (id, user_id, name, token_hash, created_at) VALUES (?, ?, ?, ?, ?)",
                       arguments: [deviceID, user.id, deviceName, ServerStore.hash(token), at])
        let actor = AuthContext(user: user, credential: .device(id: deviceID))
        try db.execute(sql: "INSERT INTO audit_log (at, actor_user_id, actor_credential, action, detail) VALUES (?, ?, ?, ?, ?)",
                       arguments: [at, user.id, actor.credentialID, "pairing.device_paired", "device=\(deviceName) platform=\(platform)"])
        return (deviceID, token)
    }
}

actor PairRequestService {
    private enum State {
        case waiting
        case approved(PairResponse)
        case denied
        case expired
        case consumed
    }

    private struct Entry {
        var request: PendingPairRequest
        var claimHash: String
        var state: State
    }

    private let store: ServerStore
    private let pairing: PairingService
    private let now: @Sendable () -> Date
    private let lifetime: TimeInterval
    private let maximumPending: Int
    private var entries: [UUID: Entry] = [:]

    init(store: ServerStore, pairing: PairingService, now: @escaping @Sendable () -> Date = { Date() },
         lifetime: TimeInterval = 5 * 60, maximumPending: Int = 5) {
        self.store = store
        self.pairing = pairing
        self.now = now
        self.lifetime = lifetime
        self.maximumPending = maximumPending
    }

    func create(_ body: PairRequestCreate, remoteAddress: String) throws -> PairRequestCreated {
        let name = body.deviceName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.count <= 100,
              !body.platform.isEmpty, body.platform.count <= 40,
              body.claimHash.count == 64, body.claimHash.allSatisfy(\.isHexDigit) else {
            throw HTTPError(.badRequest, message: "Invalid pairing request")
        }
        let created = now()
        entries = entries.filter { $0.value.request.expiresAt.addingTimeInterval(60 * 60) > created }
        let pending = entries.values.filter { if case .waiting = $0.state { return $0.request.expiresAt > created }; return false }
        if pending.count >= maximumPending, let oldest = pending.min(by: { $0.request.createdAt < $1.request.createdAt }) {
            entries[oldest.request.id]?.state = .expired
        }
        let id = UUID()
        let expires = created.addingTimeInterval(lifetime)
        let certificate = PairingEnvironment.resolve(for: store).certificateSHA256 ?? ""
        let publicRequest = PendingPairRequest(
            id: id, deviceName: name, platform: String(body.platform.prefix(40)), remoteAddress: remoteAddress,
            matchCode: PairingMatchCode.compute(certificateSHA256: certificate, requestID: id, claimHash: body.claimHash),
            createdAt: created, expiresAt: expires)
        entries[id] = Entry(request: publicRequest, claimHash: body.claimHash.lowercased(), state: .waiting)
        try store.audit(nil, action: "pairing.request_created", detail: "id=\(id) device=\(name) platform=\(body.platform) address=\(remoteAddress)")
        return PairRequestCreated(requestID: id, expiresAt: expires)
    }

    func pending() -> [PendingPairRequest] {
        let at = now()
        return entries.values.compactMap { entry in
            guard case .waiting = entry.state, entry.request.expiresAt > at else { return nil }
            return entry.request
        }.sorted { $0.createdAt < $1.createdAt }
    }

    func claim(id: UUID, claimSecret: String) throws -> PairRequestClaimResult {
        guard var entry = entries[id] else { throw HTTPError(.notFound, message: "No such pairing request") }
        let secretBytes = Self.decodeHex(claimSecret)
        guard let secretBytes else { throw HTTPError(.notFound, message: "No such pairing request") }
        let suppliedHash = SHA256.hash(data: secretBytes).map { String(format: "%02x", $0) }.joined()
        guard Self.constantTimeEquals(entry.claimHash, suppliedHash) else {
            throw HTTPError(.notFound, message: "No such pairing request")
        }
        if entry.request.expiresAt <= now() {
            entry.state = .expired
            entries[id] = entry
        }
        switch entry.state {
        case .waiting:
            return .pending
        case .approved(let response):
            entry.state = .consumed
            entries[id] = entry
            return .paired(response)
        case .denied:
            throw HTTPError(.forbidden, message: "Pairing request denied")
        case .expired, .consumed:
            throw HTTPError(.gone, message: "Pairing request expired or already claimed")
        }
    }

    func approve(id: UUID, userID: String?, caller: AuthContext) throws {
        guard var entry = entries[id] else { throw HTTPError(.notFound, message: "No such pairing request") }
        guard entry.request.expiresAt > now() else { throw HTTPError(.gone, message: "Pairing request expired") }
        guard case .waiting = entry.state else { throw HTTPError(.gone, message: "Pairing request is no longer pending") }
        let response = try pairing.pairApprovedDevice(userID: userID, request: entry.request, caller: caller)
        entry.state = .approved(response)
        entries[id] = entry
    }

    func deny(id: UUID, caller: AuthContext) throws {
        guard var entry = entries[id] else { throw HTTPError(.notFound, message: "No such pairing request") }
        guard entry.request.expiresAt > now() else { throw HTTPError(.gone, message: "Pairing request expired") }
        guard case .waiting = entry.state else { throw HTTPError(.gone, message: "Pairing request is no longer pending") }
        entry.state = .denied
        entries[id] = entry
        try store.audit(caller, action: "pairing.request_denied", detail: "id=\(id)")
    }

    private static func decodeHex(_ value: String) -> Data? {
        guard value.count == 64, value.allSatisfy(\.isHexDigit) else { return nil }
        var result = Data()
        var index = value.startIndex
        while index < value.endIndex {
            let next = value.index(index, offsetBy: 2)
            guard let byte = UInt8(value[index..<next], radix: 16) else { return nil }
            result.append(byte)
            index = next
        }
        return result
    }

    private static func constantTimeEquals(_ lhs: String, _ rhs: String) -> Bool {
        let left = Array(lhs.utf8)
        let right = Array(rhs.utf8)
        var difference = UInt8(left.count ^ right.count)
        for index in 0..<max(left.count, right.count) {
            difference |= (index < left.count ? left[index] : 0) ^ (index < right.count ? right[index] : 0)
        }
        return difference == 0
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
        recordAttempt(client: client)
    }

    public func recordAttempt(client: String) {
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
