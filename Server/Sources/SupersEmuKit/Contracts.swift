import Foundation

// Wave 1 API contracts. Fixed up front so the parallel tracks don't depend on each other.
// Server tracks implement the routes; app/CLI tracks call these client methods.

// MARK: Pairing (track: pairing + network)

/// Encoded into the QR code as `supersemu://pair?d=<base64url(JSON)>`.
public struct PairingPayload: Codable, Sendable, Equatable {
    public var serverName: String
    /// LAN first, then Tailscale (MagicDNS / 100.x). The app tries them in order.
    public var urls: [URL]
    /// SHA-256 (hex) of the server's self-signed TLS certificate; the client pins it.
    public var certificateSHA256: String?
    public var code: String
    public init(serverName: String, urls: [URL], certificateSHA256: String?, code: String) {
        self.serverName = serverName; self.urls = urls; self.certificateSHA256 = certificateSHA256; self.code = code
    }
}

public struct PairingCode: Codable, Sendable, Equatable {
    public var code: String
    public var expiresAt: Date
    public var payload: PairingPayload
    public var qrURL: String
    public init(code: String, expiresAt: Date, payload: PairingPayload, qrURL: String) {
        self.code = code; self.expiresAt = expiresAt; self.payload = payload; self.qrURL = qrURL
    }
}

public struct CreatePairingCodeRequest: Codable, Sendable, Equatable {
    /// Phase 1: omitted = Chad (admin). Phase 2: a player user ID (this is the invite).
    public var userID: String?
    public init(userID: String? = nil) { self.userID = userID }
}

public struct PairRequest: Codable, Sendable, Equatable {
    public var code: String
    public var deviceName: String
    public var platform: String
    public init(code: String, deviceName: String, platform: String) {
        self.code = code; self.deviceName = deviceName; self.platform = platform
    }
}

public struct PairResponse: Codable, Sendable, Equatable {
    public var token: String
    public var deviceID: String
    public var user: UserInfo
    public var serverName: String
    public init(token: String, deviceID: String, user: UserInfo, serverName: String) {
        self.token = token; self.deviceID = deviceID; self.user = user; self.serverName = serverName
    }
}

// MARK: Library admin (track: server library)

public struct ImportRequest: Codable, Sendable, Equatable {
    /// Paths on the server's filesystem (files, folders or .zip).
    public var paths: [String]
    public init(paths: [String]) { self.paths = paths }
}

public struct ReviewItem: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var filename: String
    public var reason: String
    public init(id: String, filename: String, reason: String) { self.id = id; self.filename = filename; self.reason = reason }
}

public struct ImportReport: Codable, Sendable, Equatable {
    public var imported: [GameSummary]
    public var duplicates: Int
    public var needsReview: [ReviewItem]
    public var unsupported: [String]
    public init(imported: [GameSummary], duplicates: Int, needsReview: [ReviewItem], unsupported: [String]) {
        self.imported = imported; self.duplicates = duplicates; self.needsReview = needsReview; self.unsupported = unsupported
    }
}

public enum PrincipalType: String, Codable, Sendable { case everyone, user, group }

public struct PermissionGrant: Codable, Sendable, Equatable {
    public var gameID: String
    public var principalType: PrincipalType
    public var principalID: String?
    public init(gameID: String, principalType: PrincipalType, principalID: String?) {
        self.gameID = gameID; self.principalType = principalType; self.principalID = principalID
    }
}

// MARK: Users, devices, tokens (track: CLI + admin)

public struct DeviceInfo: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var userID: String
    public var name: String
    public var createdAt: Date
    public var lastSeenAt: Date?
    public var revokedAt: Date?
    public init(id: String, userID: String, name: String, createdAt: Date, lastSeenAt: Date?, revokedAt: Date?) {
        self.id = id; self.userID = userID; self.name = name; self.createdAt = createdAt; self.lastSeenAt = lastSeenAt; self.revokedAt = revokedAt
    }
}

public struct CreateTokenRequest: Codable, Sendable, Equatable {
    public var name: String
    public var scopes: [Scope]
    public init(name: String, scopes: [Scope]) { self.name = name; self.scopes = scopes }
}

public struct TokenInfo: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var name: String
    public var scopes: [Scope]
    public var createdAt: Date
    public var revokedAt: Date?
    /// Only set in the response that creates the token.
    public var token: String?
    public init(id: String, name: String, scopes: [Scope], createdAt: Date, revokedAt: Date?, token: String?) {
        self.id = id; self.name = name; self.scopes = scopes; self.createdAt = createdAt; self.revokedAt = revokedAt; self.token = token
    }
}

public struct AdminStatus: Codable, Sendable, Equatable {
    public var health: HealthResponse
    public var dataDirectory: String
    public var freeBytes: Int64?
    public var gameCount: Int
    public var reviewCount: Int
    public var userCount: Int
    public var deviceCount: Int
    public init(health: HealthResponse, dataDirectory: String, freeBytes: Int64?, gameCount: Int, reviewCount: Int, userCount: Int, deviceCount: Int) {
        self.health = health; self.dataDirectory = dataDirectory; self.freeBytes = freeBytes
        self.gameCount = gameCount; self.reviewCount = reviewCount; self.userCount = userCount; self.deviceCount = deviceCount
    }
}

// MARK: Saves (track: save sync)

public struct SaveRevision: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var gameID: String
    public var kind: SaveKind
    /// "" for native and auto; slot name for manual states.
    public var slot: String
    public var parentID: String?
    public var sha256: String
    public var size: Int64
    public var coreID: String
    public var coreVersion: String
    public var deviceID: String?
    public var createdAt: Date
    /// True when this revision is the newest in its (kind, slot) line.
    public var isHead: Bool
    public init(id: String, gameID: String, kind: SaveKind, slot: String, parentID: String?, sha256: String, size: Int64,
                coreID: String, coreVersion: String, deviceID: String?, createdAt: Date, isHead: Bool) {
        self.id = id; self.gameID = gameID; self.kind = kind; self.slot = slot; self.parentID = parentID; self.sha256 = sha256
        self.size = size; self.coreID = coreID; self.coreVersion = coreVersion; self.deviceID = deviceID; self.createdAt = createdAt; self.isHead = isHead
    }
}

public struct SaveListResponse: Codable, Sendable, Equatable {
    public var revisions: [SaveRevision]
    public init(revisions: [SaveRevision]) { self.revisions = revisions }
}

public struct SaveUploadResponse: Codable, Sendable, Equatable {
    public var revision: SaveRevision
    /// True when `parent` was not the current head: nothing was overwritten, a branch was kept.
    public var branched: Bool
    public init(revision: SaveRevision, branched: Bool) { self.revision = revision; self.branched = branched }
}

// MARK: Client methods for the contracts above

extension APIClient {
    public func gameDetail(_ id: String) async throws -> GameDetail { try await get("/v1/games/\(id)") }
    /// Supports HTTP Range for resumable downloads.
    public func filePath(gameID: String, fileID: String) -> String { "/v1/games/\(gameID)/files/\(fileID)" }

    public func createPairingCode(_ request: CreatePairingCodeRequest = .init()) async throws -> PairingCode {
        try await send("POST", "/v1/admin/pairing-codes", body: request)
    }
    public func pair(_ request: PairRequest) async throws -> PairResponse { try await send("POST", "/v1/pair", body: request) }

    public func importLibrary(_ request: ImportRequest) async throws -> ImportReport {
        try await send("POST", "/v1/admin/library/import", body: request)
    }
    /// Imports everything in the server's `Incoming` folder.
    public func scanIncoming() async throws -> ImportReport { try await send("POST", "/v1/admin/library/scan", body: ImportRequest(paths: [])) }
    public func reviewQueue() async throws -> [ReviewItem] { try await get("/v1/admin/library/review") }
    public func grant(_ grant: PermissionGrant) async throws -> PermissionGrant { try await send("PUT", "/v1/admin/permissions", body: grant) }

    public func adminStatus() async throws -> AdminStatus { try await get("/v1/admin/status") }
    public func users() async throws -> [UserInfo] { try await get("/v1/admin/users") }
    public func devices() async throws -> [DeviceInfo] { try await get("/v1/admin/devices") }
    public func revokeDevice(_ id: String) async throws -> DeviceInfo { try await send("DELETE", "/v1/admin/devices/\(id)", body: Optional<String>.none) }
    public func tokens() async throws -> [TokenInfo] { try await get("/v1/admin/tokens") }
    public func createToken(_ request: CreateTokenRequest) async throws -> TokenInfo { try await send("POST", "/v1/admin/tokens", body: request) }
    public func revokeToken(_ id: String) async throws -> TokenInfo { try await send("DELETE", "/v1/admin/tokens/\(id)", body: Optional<String>.none) }

    public func saves(gameID: String) async throws -> SaveListResponse { try await get("/v1/saves/\(gameID)") }
    /// Body is the raw save bytes. Query: `slot`, `parent`, `core`, `coreVersion`.
    public func uploadSave(gameID: String, kind: SaveKind, slot: String, parentID: String?, coreID: String, coreVersion: String, data: Data) async throws -> SaveUploadResponse {
        var query = URLComponents()
        query.queryItems = [.init(name: "slot", value: slot), .init(name: "core", value: coreID), .init(name: "coreVersion", value: coreVersion)]
        if let parentID { query.queryItems?.append(.init(name: "parent", value: parentID)) }
        let body = try await raw("PUT", "/v1/saves/\(gameID)/\(kind.rawValue)?\(query.percentEncodedQuery ?? "")", body: data, contentType: "application/octet-stream")
        return try SupersEmuJSON.decoder().decode(SaveUploadResponse.self, from: body)
    }
    public func saveData(gameID: String, revisionID: String) async throws -> Data { try await raw("GET", "/v1/saves/\(gameID)/revisions/\(revisionID)") }
}
