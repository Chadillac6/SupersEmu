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
    /// Merged from every metadata provider (docs/specs/metadata-and-artwork.md); each is nil when unknown.
    public var publisher: String?
    public var region: String?
    public var genres: [String]?
    public var players: Int?
    public var criticScore: CriticScore?
    /// Wide hero art. Same form as `coverPath`.
    public var backdropPath: String?
    /// Best wide art for a hero banner: the backdrop, else an in-game screenshot or title screen.
    public var heroPath: String?
    /// Transparent title logo.
    public var logoPath: String?

    public init(id: String, title: String, system: SystemID, year: Int?, genre: String?, coverPath: String?, totalSize: Int64,
                addedAt: Date? = nil, publisher: String? = nil, region: String? = nil, genres: [String]? = nil, players: Int? = nil,
                criticScore: CriticScore? = nil, backdropPath: String? = nil, heroPath: String? = nil, logoPath: String? = nil) {
        self.id = id
        self.title = title
        self.system = system
        self.year = year
        self.genre = genre
        self.coverPath = coverPath
        self.totalSize = totalSize
        self.addedAt = addedAt
        self.publisher = publisher
        self.region = region
        self.genres = genres
        self.players = players
        self.criticScore = criticScore
        self.backdropPath = backdropPath
        self.heroPath = heroPath
        self.logoPath = logoPath
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
    /// The game's description ("intro").
    public var summary: String?
    public var files: [GameFileInfo]
    public var developer: String?
    public var logoPath: String?
    public var titleScreenPath: String?
    /// In-game screenshots, in display order.
    public var screenshotPaths: [String]?
    /// Where the metadata came from, for attribution.
    public var sources: [MetadataSource]?
    /// Who wrote `summary`, when a provider did (e.g. Wikipedia).
    public var summarySource: MetadataSource?
    /// A short critical-reception summary, e.g. from Wikipedia's Reception section.
    public var reception: ReceptionSummary?
    /// Where to read full reviews, e.g. IGN.
    public var reviewLink: ReviewLink?

    public init(game: GameSummary, summary: String?, files: [GameFileInfo], developer: String? = nil, logoPath: String? = nil,
                titleScreenPath: String? = nil, screenshotPaths: [String]? = nil, sources: [MetadataSource]? = nil,
                summarySource: MetadataSource? = nil, reception: ReceptionSummary? = nil, reviewLink: ReviewLink? = nil) {
        self.game = game
        self.summary = summary
        self.files = files
        self.developer = developer
        self.logoPath = logoPath
        self.titleScreenPath = titleScreenPath
        self.screenshotPaths = screenshotPaths
        self.sources = sources
        self.summarySource = summarySource
        self.reception = reception
        self.reviewLink = reviewLink
    }
}

/// A few sentences on how a game was received, quoted from `source` (which must be shown as attribution).
public struct ReceptionSummary: Codable, Sendable, Equatable {
    public var text: String
    public var source: String
    public var url: String?

    public init(text: String, source: String, url: String? = nil) {
        self.text = text
        self.source = source
        self.url = url
    }
}

/// An outside page with full reviews, e.g. "IGN".
public struct ReviewLink: Codable, Sendable, Equatable {
    public var name: String
    public var url: String

    public init(name: String, url: String) {
        self.name = name
        self.url = url
    }
}

/// A critic/aggregate review score normalised to 0-100, with where it came from.
public struct CriticScore: Codable, Sendable, Equatable {
    public var score: Int
    public var source: String
    public var url: String?

    public init(score: Int, source: String, url: String? = nil) {
        self.score = score
        self.source = source
        self.url = url
    }
}

/// One metadata provider that contributed to a game, e.g. `libretro` / "No-Intro via libretro-database".
public struct MetadataSource: Codable, Sendable, Equatable {
    public var provider: String
    public var name: String
    public var url: String?

    public init(provider: String, name: String, url: String? = nil) {
        self.provider = provider
        self.name = name
        self.url = url
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

/// A BIOS/firmware file the server holds for disc systems (see docs/specs/disc-games.md).
public struct BIOSFileInfo: Codable, Sendable, Equatable, Identifiable {
    /// SHA-256 of the file contents.
    public var id: String
    /// Canonical filename the core looks for in the system directory.
    public var filename: String
    public var system: SystemID
    public var region: String?
    public var required: Bool

    public init(id: String, filename: String, system: SystemID, region: String?, required: Bool) {
        self.id = id
        self.filename = filename
        self.system = system
        self.region = region
        self.required = required
    }
}

