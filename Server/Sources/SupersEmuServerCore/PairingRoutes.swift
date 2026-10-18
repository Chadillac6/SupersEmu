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
func registerPairingRoutes(public publicGroup: RouterGroup<SERequestContext>, authed: RouterGroup<SERequestContext>,
                           store: ServerStore, services: PairingServices, exposure: RouterExposure,
                           includeAdminRoutes: Bool = true) {
    let service = services.pairing
    let requests = services.requests

    if includeAdminRoutes {
        authed.post("admin/pairing-codes") { request, context in
            let auth = try requireUsersAdmin(context)
            let body = try await request.decode(as: CreatePairingCodeRequest.self, context: context)
            let code = try service.createCode(for: body.userID, caller: auth)
            return EditedResponse(status: .created, response: code)
        }
    }

    publicGroup.post("pair") { request, context in
        let client = context.remoteAddress ?? "unknown"
        guard service.limiter.allowAttempt(client: client, exposure: exposure) else {
            throw HTTPError(.tooManyRequests, message: "Too many pairing attempts. Wait a minute and try again.")
        }
        let body = try await request.decode(as: PairRequest.self, context: context)
        return try service.pair(body, client: client, exposure: exposure)
    }

    publicGroup.post("pair/requests") { request, context in
        let client = context.remoteAddress ?? "unknown"
        let body = try await request.decode(as: PairRequestCreate.self, context: context)
        let created = try await requests.create(body, remoteAddress: client, exposure: exposure)
        return EditedResponse(status: .created, response: created)
    }

    publicGroup.post("pair/requests/:id/claim") { request, context in
        let id = UUID(uuidString: try context.parameters.require("id"))
        let body = try await request.decode(as: PairRequestClaim.self, context: context)
        switch try await requests.claim(id: id, claimSecret: body.claimSecret,
                                        remoteAddress: context.remoteAddress ?? "unknown", exposure: exposure) {
        case .pending:
            return try LibraryHTTP.json(PairRequestPending(), status: .accepted)
        case .paired(let response):
            return try LibraryHTTP.json(response)
        }
    }

    guard includeAdminRoutes else { return }

    authed.get("admin/pair-requests") { _, context in
        _ = try requireUsersAdmin(context)
        return await requests.pending()
    }

    authed.post("admin/pair-requests/:id/approve") { request, context in
        let auth = try requireUsersAdmin(context)
        guard let id = UUID(uuidString: try context.parameters.require("id")) else {
            throw HTTPError(.notFound, message: "No such pairing request")
        }
        let body = try await request.decode(as: PairRequestApproval.self, context: context)
        try await requests.approve(id: id, userID: body.userID, caller: auth)
        return PairRequestActionResponse(status: "approved")
    }

    authed.post("admin/pair-requests/:id/deny") { _, context in
        let auth = try requireUsersAdmin(context)
        guard let id = UUID(uuidString: try context.parameters.require("id")) else {
            throw HTTPError(.notFound, message: "No such pairing request")
        }
        try await requests.deny(id: id, caller: auth)
        return PairRequestActionResponse(status: "denied")
    }
}

public struct PairingServices: Sendable {
    let pairing: PairingService
    let requests: PairRequestService

    public init(store: ServerStore) {
        let pairing = PairingService(store: store)
        self.pairing = pairing
        self.requests = PairRequestService(store: store, pairing: pairing)
    }

    init(pairing: PairingService, requests: PairRequestService) {
        self.pairing = pairing
        self.requests = requests
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
            guard let target = try store.db.read({ try ServerStore.activeUser(id: userID, in: $0) }) else {
                throw HTTPError(.notFound, message: "No such user")
            }
            user = target
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
        let payload = PairingPayload(serverName: store.serverName, urls: environment.currentURLs,
                                     certificateSHA256: environment.certificateSHA256, code: code,
                                     publicURL: environment.publicURL)
        return PairingCode(code: code, expiresAt: expires, payload: payload, qrURL: try PairingLink.url(for: payload).absoluteString)
    }

    /// Consumes `request.code` and issues a device token for the code's user.
    public func pair(_ request: PairRequest, client: String = "local",
                     exposure: RouterExposure = .local) throws -> PairResponse {
        let code = request.code.filter(\.isNumber)
        let deviceName = request.deviceName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard code.count == 6 else {
            limiter.recordFailure(client: client, exposure: exposure)
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
            limiter.recordFailure(client: client, exposure: exposure)
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
            guard let target = try store.db.read({ try ServerStore.activeUser(id: userID, in: $0) }) else {
                throw HTTPError(.notFound, message: "No such user")
            }
            user = target
        } else {
            guard let owner = try store.adminUser() else { throw HTTPError(.notFound, message: "No owner user") }
            user = owner
        }
        let at = now()
        let device = try store.db.write { db in
            let device = try Self.mintDevice(db: db, user: user, deviceName: request.deviceName, platform: request.platform, at: at)
            try ServerStore.insertAudit(db, caller, action: "pairing.request_approved",
                                        detail: "id=\(request.id) user=\(user.id)", at: at)
            return device
        }
        return PairResponse(token: device.token, deviceID: device.deviceID, user: user, serverName: store.serverName)
    }

    private static func mintDevice(db: Database, user: UserInfo, deviceName: String, platform: String, at: Date) throws
        -> (deviceID: String, token: String) {
        let device = try ServerStore.insertDevice(db, userID: user.id, name: deviceName, at: at)
        try ServerStore.insertAudit(db, AuthContext(user: user, credential: .device(id: device.deviceID)),
                                    action: "pairing.device_paired", detail: "device=\(deviceName) platform=\(platform)", at: at)
        return device
    }
}

actor PairRequestService {
    private struct ClaimAttempt {
        let at: Date
        let cost: Int
    }

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
        var exposure: RouterExposure
    }

    private let store: ServerStore
    private let pairing: PairingService
    private let now: @Sendable () -> Date
    private let lifetime: TimeInterval
    private let rateLimitWindow: TimeInterval
    private let createLimitPerMinute: Int
    private let claimLimitPerMinute: Int
    private let maximumPendingPerClient: Int
    private let maximumPendingGlobally: Int
    private var entries: [UUID: Entry] = [:]
    private var createAttempts: [String: [Date]] = [:]
    private var claimAttempts: [String: [ClaimAttempt]] = [:]

    init(store: ServerStore, pairing: PairingService, now: @escaping @Sendable () -> Date = { Date() },
         lifetime: TimeInterval = 5 * 60, rateLimitWindow: TimeInterval = 60,
         createLimitPerMinute: Int = 5, claimLimitPerMinute: Int = 60,
         maximumPendingPerClient: Int = 2, maximumPendingGlobally: Int = 10) {
        self.store = store
        self.pairing = pairing
        self.now = now
        self.lifetime = lifetime
        self.rateLimitWindow = rateLimitWindow
        self.createLimitPerMinute = createLimitPerMinute
        self.claimLimitPerMinute = claimLimitPerMinute
        self.maximumPendingPerClient = maximumPendingPerClient
        self.maximumPendingGlobally = maximumPendingGlobally
    }

    func create(_ body: PairRequestCreate, remoteAddress: String,
                exposure: RouterExposure = .local) throws -> PairRequestCreated {
        let created = now()
        try recordCreateAttempt(remoteAddress: remoteAddress, at: created)
        let name = body.deviceName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.count <= 100,
              !body.platform.isEmpty, body.platform.count <= 40,
              body.claimHash.count == 64, body.claimHash.allSatisfy(\.isHexDigit) else {
            throw HTTPError(.badRequest, message: "Invalid pairing request")
        }
        entries = entries.filter { $0.value.request.expiresAt.addingTimeInterval(60 * 60) > created }
        let pendingFromClient = entries.values.filter {
            if case .waiting = $0.state {
                return $0.request.remoteAddress == remoteAddress && $0.request.expiresAt > created
            }
            return false
        }
        if pendingFromClient.count >= maximumPendingPerClient,
           let oldest = pendingFromClient.min(by: { $0.request.createdAt < $1.request.createdAt }) {
            entries[oldest.request.id]?.state = .expired
        }
        let pendingCount = entries.values.filter {
            if case .waiting = $0.state {
                return $0.exposure == exposure && $0.request.expiresAt > created
            }
            return false
        }.count
        guard pendingCount < maximumPendingGlobally else {
            throw HTTPError(.tooManyRequests,
                            message: "Too many pending connection requests — approve or deny them in the SupersEmu Server window")
        }
        let id = UUID()
        let expires = created.addingTimeInterval(lifetime)
        let certificate = PairingEnvironment.resolve(for: store).certificateSHA256 ?? ""
        let publicRequest = PendingPairRequest(
            id: id, deviceName: name, platform: String(body.platform.prefix(40)), remoteAddress: remoteAddress,
            matchCode: PairingMatchCode.compute(certificateSHA256: certificate, requestID: id, claimHash: body.claimHash),
            createdAt: created, expiresAt: expires)
        entries[id] = Entry(request: publicRequest, claimHash: body.claimHash.lowercased(),
                            state: .waiting, exposure: exposure)
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

    func claim(id: UUID?, claimSecret: String, remoteAddress: String = "unknown",
               exposure: RouterExposure = .local) throws -> PairRequestClaimResult {
        let claimedAt = now()
        // Every failed claim looks the same (status, message, rate-limit cost), so a probe learns nothing.
        guard let id, var entry = entries[id], entry.exposure == exposure,
              let secretBytes = Self.decodeHex(claimSecret),
              Self.constantTimeEquals(entry.claimHash, SHA256.hash(data: secretBytes).map { String(format: "%02x", $0) }.joined())
        else {
            try recordClaimAttempt(remoteAddress: remoteAddress, cost: 5, at: claimedAt)
            throw HTTPError(.notFound, message: "No such pairing request")
        }
        try recordClaimAttempt(remoteAddress: remoteAddress, cost: 1, at: claimedAt)
        if entry.request.expiresAt <= claimedAt {
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
        var entry = try waitingEntry(id)
        let response = try pairing.pairApprovedDevice(userID: userID, request: entry.request, caller: caller)
        entry.state = .approved(response)
        entries[id] = entry
    }

    func deny(id: UUID, caller: AuthContext) throws {
        var entry = try waitingEntry(id)
        entry.state = .denied
        entries[id] = entry
        try store.audit(caller, action: "pairing.request_denied", detail: "id=\(id)")
    }

    /// The request an admin can still approve or deny.
    private func waitingEntry(_ id: UUID) throws -> Entry {
        guard let entry = entries[id] else { throw HTTPError(.notFound, message: "No such pairing request") }
        guard entry.request.expiresAt > now() else { throw HTTPError(.gone, message: "Pairing request expired") }
        guard case .waiting = entry.state else { throw HTTPError(.gone, message: "Pairing request is no longer pending") }
        return entry
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

    private func recordCreateAttempt(remoteAddress: String, at: Date) throws {
        pruneAttempts(olderThan: at.addingTimeInterval(-rateLimitWindow))
        let attempts = createAttempts[remoteAddress, default: []]
        guard attempts.count < createLimitPerMinute else {
            throw HTTPError(.tooManyRequests, message: "Too many connection request creations. Wait a minute and try again.")
        }
        createAttempts[remoteAddress, default: []].append(at)
    }

    private func recordClaimAttempt(remoteAddress: String, cost: Int, at: Date) throws {
        pruneAttempts(olderThan: at.addingTimeInterval(-rateLimitWindow))
        let attempts = claimAttempts[remoteAddress, default: []]
        let used = attempts.reduce(0) { $0 + $1.cost }
        guard used + cost <= claimLimitPerMinute else {
            throw HTTPError(.tooManyRequests, message: "Too many connection request claims. Wait a minute and try again.")
        }
        claimAttempts[remoteAddress, default: []].append(ClaimAttempt(at: at, cost: cost))
    }

    private func pruneAttempts(olderThan cutoff: Date) {
        for remoteAddress in Array(createAttempts.keys) {
            createAttempts[remoteAddress]?.removeAll { $0 < cutoff }
            if createAttempts[remoteAddress]?.isEmpty == true { createAttempts[remoteAddress] = nil }
        }
        for remoteAddress in Array(claimAttempts.keys) {
            claimAttempts[remoteAddress]?.removeAll { $0.at < cutoff }
            if claimAttempts[remoteAddress]?.isEmpty == true { claimAttempts[remoteAddress] = nil }
        }
    }
}

/// Limits failed `/v1/pair` attempts per client IP (5 a minute by default), with a higher global ceiling so many
/// addresses can't brute-force together: at 60 failures a minute a 10-minute code faces at most ~600 guesses of
/// 1,000,000. One client's failures don't lock out others until the ceiling is reached.
public final class PairingRateLimiter: Sendable {
    private struct FailureState {
        var clients: [String: [Date]] = [:]
        var global: [RouterExposure: [Date]] = [:]
    }

    let maxFailures: Int
    let maxGlobalFailures: Int
    let window: TimeInterval
    let now: @Sendable () -> Date
    private let failures = Mutex(FailureState())

    public init(maxFailures: Int = 5, maxGlobalFailures: Int = 60, window: TimeInterval = 60,
                now: @escaping @Sendable () -> Date = { Date() }) {
        self.maxFailures = maxFailures
        self.maxGlobalFailures = maxGlobalFailures
        self.window = window
        self.now = now
    }

    public func allowAttempt(client: String, exposure: RouterExposure = .local) -> Bool {
        let cutoff = now().addingTimeInterval(-window)
        return failures.withLock { failures in
            for key in Array(failures.clients.keys) {
                failures.clients[key]?.removeAll { $0 < cutoff }
                if failures.clients[key]?.isEmpty == true { failures.clients[key] = nil }
            }
            for key in Array(failures.global.keys) {
                failures.global[key]?.removeAll { $0 < cutoff }
                if failures.global[key]?.isEmpty == true { failures.global[key] = nil }
            }
            return (failures.clients[client]?.count ?? 0) < maxFailures
                && (failures.global[exposure]?.count ?? 0) < maxGlobalFailures
        }
    }

    public func recordFailure(client: String, exposure: RouterExposure = .local) {
        recordAttempt(client: client, exposure: exposure)
    }

    public func recordAttempt(client: String, exposure: RouterExposure = .local) {
        let at = now()
        failures.withLock {
            $0.clients[client, default: []].append(at)
            $0.global[exposure, default: []].append(at)
        }
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
