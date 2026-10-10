import Foundation
import GRDB
import Hummingbird
import SupersEmuKit

extension HealthResponse: ResponseEncodable {}
extension MeResponse: ResponseEncodable {}
extension LibraryResponse: ResponseEncodable {}
extension GameDetail: ResponseEncodable {}
extension APIErrorBody: ResponseEncodable {}

public enum ServerInfo {
    public static let version = "0.1.0"
}

public func buildRouter(store: ServerStore, metadata: MetadataService? = nil) -> Router<SERequestContext> {
    let router = Router(context: SERequestContext.self)
    router.add(middleware: LogRequestsMiddleware(.info))

    router.group("v1").get("health") { _, _ in
        HealthResponse(status: "ok", serverName: store.serverName, serverVersion: ServerInfo.version)
    }

    let authed = router.group("v1").add(middleware: TokenAuthMiddleware(store: store))
    authed.get("me") { _, context in
        let auth = try context.caller()
        let scopes: [Scope]? = {
            if case .apiToken(_, let scopes) = auth.credential { return scopes.sorted { $0.rawValue < $1.rawValue } }
            return nil
        }()
        let deviceID: String? = { if case .device(let id) = auth.credential { return id }; return nil }()
        return MeResponse(user: auth.user, deviceID: deviceID, scopes: scopes)
    }
    authed.get("library") { _, context in
        let auth = try context.caller()
        try auth.require(.libraryRead)
        return LibraryResponse(games: try LibraryQueries.visibleGames(for: auth, store: store))
    }

    // Each Wave 1 track owns one of these files and fills in its routes.
    registerLibraryRoutes(authed, store: store)
    registerBIOSRoutes(authed, store: store)
    registerAdminLibraryRoutes(authed, store: store, metadata: metadata)
    registerAdminLibraryManagementRoutes(authed, store: store, metadata: metadata)
    registerAdminUserRoutes(authed, store: store)
    registerBackupRoutes(authed, store: store)
    registerPairingRoutes(public: router.group("v1"), authed: authed, store: store)
    registerSaveRoutes(authed, store: store)
    return router
}

public func buildApplication(store: ServerStore, metadata: MetadataService? = nil, configuration: ApplicationConfiguration) -> some ApplicationProtocol {
    Application(router: buildRouter(store: store, metadata: metadata), configuration: configuration)
}

public enum LibraryQueries {
    public static func visibleGames(for auth: AuthContext, store: ServerStore) throws -> [GameSummary] {
        let visible = Permissions.visibleGameIDsSQL(for: auth)
        return try store.db.read { db in
            let merged = try MetadataMerge.load(gameIDsSQL: visible.sql, arguments: visible.arguments, db: db)
            return try Row.fetchAll(db, sql: """
                SELECT g.*, COALESCE((SELECT SUM(size) FROM game_files f WHERE f.game_id = g.id), 0) AS total_size
                FROM games g WHERE g.id IN (\(visible.sql)) AND g.needs_review = 0
                ORDER BY g.title COLLATE NOCASE
                """, arguments: visible.arguments).map { summary(from: $0, merged: merged[$0["id"]] ?? MetadataMerge.Merged()) }
                .sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
        }
    }

    public static func summary(from row: Row) -> GameSummary {
        summary(from: row, merged: MetadataMerge.Merged())
    }

    /// Imported values (`games`) overlaid with merged provider metadata.
    static func summary(from row: Row, merged: MetadataMerge.Merged) -> GameSummary {
        let id: String = row["id"]
        let manualCover: String? = row["cover_artwork"]
        let genre: String? = row["genre"]
        let genres = merged.genres ?? genre.map { [$0] }
        return GameSummary(
            id: id, title: merged.title ?? row["title"], system: SystemID(rawValue: row["system"]) ?? .snes,
            year: merged.year ?? row["year"], genre: genres?.first,
            coverPath: manualCover != nil ? "/v1/games/\(id)/artwork/cover" : merged.artworkPath(id, .cover),
            totalSize: row["total_size"] ?? 0, addedAt: row["created_at"],
            publisher: merged.publisher, region: merged.region, genres: genres, players: merged.players,
            criticScore: merged.criticScore, backdropPath: merged.artworkPath(id, .backdrop), heroPath: merged.heroPath(id),
            logoPath: merged.artworkPath(id, .logo))
    }
}
