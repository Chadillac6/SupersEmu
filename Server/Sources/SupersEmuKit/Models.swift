import Foundation

public enum APIVersion {
    public static let current = "v1"
}

public enum Role: String, Codable, Sendable {
    case admin, player
}

/// Scopes for bot/CLI API tokens. Device tokens carry the full rights of their user.
public enum Scope: String, Codable, Sendable, CaseIterable {
    case libraryRead = "library:read"
    case libraryWrite = "library:write"
    case usersAdmin = "users:admin"
    case savesRead = "saves:read"
}

public enum SystemID: String, Codable, Sendable, CaseIterable {
    case snes, gb, gbc, gba, genesis, segacd, sega32x, psx, n64
}

public struct HealthResponse: Codable, Sendable, Equatable {
    public var status: String
    public var serverName: String
    public var serverVersion: String
    public var apiVersion: String

    public init(status: String, serverName: String, serverVersion: String, apiVersion: String = APIVersion.current) {
        self.status = status
        self.serverName = serverName
        self.serverVersion = serverVersion
        self.apiVersion = apiVersion
    }
}

public struct UserInfo: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var displayName: String
    public var role: Role

    public init(id: String, displayName: String, role: Role) {
        self.id = id
        self.displayName = displayName
        self.role = role
    }
}

public struct MeResponse: Codable, Sendable, Equatable {
    public var user: UserInfo
    /// Set when the caller is a paired device.
    public var deviceID: String?
    /// Set when the caller is a scoped API token (bots, CLI).
    public var scopes: [Scope]?

    public init(user: UserInfo, deviceID: String?, scopes: [Scope]?) {
        self.user = user
        self.deviceID = deviceID
        self.scopes = scopes
    }
}

public struct GameSummary: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var title: String
    public var system: SystemID
    public var year: Int?
    public var genre: String?
    /// Server-relative artwork path, e.g. `/v1/games/{id}/artwork/cover`. Nil until art exists.
    public var coverPath: String?
    public var totalSize: Int64
    /// When the game was added to the server (drives "Recently Added"). Optional so older servers still decode.
    public var addedAt: Date?

    public init(id: String, title: String, system: SystemID, year: Int?, genre: String?, coverPath: String?, totalSize: Int64,
                addedAt: Date? = nil) {
        self.id = id
        self.title = title
        self.system = system
        self.year = year
        self.genre = genre
        self.coverPath = coverPath
        self.totalSize = totalSize
        self.addedAt = addedAt
    }
}

public struct LibraryResponse: Codable, Sendable, Equatable {
    public var games: [GameSummary]

    public init(games: [GameSummary]) {
        self.games = games
    }
}

public enum GameFileRole: String, Codable, Sendable {
    case rom, disc, cue, m3u
}

public struct GameFileInfo: Codable, Sendable, Equatable, Identifiable {
    /// SHA-256 of the file contents.
    public var id: String
    public var filename: String
    public var role: GameFileRole
    public var size: Int64
    public var discNumber: Int?

    public init(id: String, filename: String, role: GameFileRole, size: Int64, discNumber: Int?) {
        self.id = id
        self.filename = filename
        self.role = role
        self.size = size
        self.discNumber = discNumber
    }
}

public struct GameDetail: Codable, Sendable, Equatable {
    public var game: GameSummary
    public var summary: String?
    public var files: [GameFileInfo]

    public init(game: GameSummary, summary: String?, files: [GameFileInfo]) {
        self.game = game
        self.summary = summary
        self.files = files
    }
}

public enum SaveKind: String, Codable, Sendable {
    case native, auto, manual
}

public struct APIErrorBody: Codable, Sendable, Equatable {
    public var error: String

    public init(error: String) {
        self.error = error
    }
}
