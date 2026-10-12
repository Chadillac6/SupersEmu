import Foundation
import GRDB
import HTTPTypes
import Hummingbird
import NIOCore
import SupersEmuKit

public struct AuthContext: Sendable, Equatable {
    public enum Credential: Sendable, Equatable {
        case device(id: String)
        case apiToken(id: String, scopes: Set<Scope>)
    }

    public var user: UserInfo
    public var credential: Credential

    public var isAdmin: Bool { user.role == .admin }

    public var credentialID: String {
        switch credential {
        case .device(let id): return "device:\(id)"
        case .apiToken(let id, _): return "token:\(id)"
        }
    }

    /// Devices act with their user's full rights; API tokens are limited to their scopes.
    public func has(_ scope: Scope) -> Bool {
        switch credential {
        case .device:
            switch scope {
            case .libraryRead, .savesRead: return true
            case .libraryWrite, .usersAdmin: return isAdmin
            }
        case .apiToken(_, let scopes):
            return scopes.contains(scope) && (isAdmin || scope == .libraryRead || scope == .savesRead)
        }
    }

    public func require(_ scope: Scope) throws {
        guard has(scope) else { throw HTTPError(.forbidden, message: "Missing scope \(scope.rawValue)") }
    }

    public func requireAdmin() throws {
        guard isAdmin else { throw HTTPError(.forbidden, message: "Admin only") }
    }
}

public struct SERequestContext: RequestContext {
    public var coreContext: CoreRequestContextStorage
    public var auth: AuthContext?
    /// Peer IP address, e.g. for per-client rate limits.
    public var remoteAddress: String?
    public var maxUploadSize: Int

    public init(source: ApplicationRequestContextSource) {
        coreContext = .init(source: source)
        auth = nil
        remoteAddress = source.channel.remoteAddress?.ipAddress
        maxUploadSize = 2 * 1024 * 1024
    }

    public var requestDecoder: JSONDecoder { SupersEmuJSON.decoder() }
    public var responseEncoder: JSONEncoder { SupersEmuJSON.encoder() }

    /// The authenticated caller. Only valid on routes behind `TokenAuthMiddleware`.
    public func caller() throws -> AuthContext {
        guard let auth else { throw HTTPError(.unauthorized) }
        return auth
    }
}

public struct TokenAuthMiddleware: RouterMiddleware {
    public typealias Context = SERequestContext
    let store: ServerStore
    let requiresDeviceToken: Bool

    public init(store: ServerStore, requiresDeviceToken: Bool = false) {
        self.store = store
        self.requiresDeviceToken = requiresDeviceToken
    }

    public func handle(_ request: Request, context: Context, next: (Request, Context) async throws -> Response) async throws -> Response {
        guard let header = request.headers[.authorization], header.hasPrefix("Bearer "),
              let auth = try store.authenticate(token: String(header.dropFirst("Bearer ".count))) else {
            throw HTTPError(.unauthorized, message: "Sign in required")
        }
        if requiresDeviceToken, case .apiToken = auth.credential {
            throw HTTPError(.unauthorized, message: "Use a paired device")
        }
        var context = context
        context.auth = auth
        return try await next(request, context)
    }
}

public struct PublicProxyMiddleware: RouterMiddleware {
    public typealias Context = SERequestContext
    private static let forwardedFor = HTTPField.Name("x-forwarded-for")!

    public init() {}

    public func handle(_ request: Request, context: Context,
                       next: (Request, Context) async throws -> Response) async throws -> Response {
        var context = context
        context.maxUploadSize = 64 * 1024
        if let forwarded = request.headers[Self.forwardedFor],
           let address = forwarded.split(separator: ",").last.map(String.init)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           (try? SocketAddress(ipAddress: address, port: 0)) != nil {
            context.remoteAddress = address
        } else {
            context.remoteAddress = "public-unknown"
        }
        return try await next(request, context)
    }
}

/// The single place that decides which games a caller can see. Phase 1: the admin sees everything.
/// Phase 2: players see games granted to everyone, to them, or to one of their groups.
public enum Permissions {
    public static func visibleGameIDsSQL(for auth: AuthContext) -> (sql: String, arguments: StatementArguments) {
        if auth.isAdmin { return ("SELECT id FROM games", []) }
        return ("""
            SELECT game_id FROM game_permissions
            WHERE principal_type = 'everyone'
               OR (principal_type = 'user' AND principal_id = ?)
               OR (principal_type = 'group' AND principal_id IN (SELECT group_id FROM group_members WHERE user_id = ?))
            """, [auth.user.id, auth.user.id])
    }

    public static func canSee(gameID: String, auth: AuthContext, db: Database) throws -> Bool {
        let visible = visibleGameIDsSQL(for: auth)
        return try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM (\(visible.sql)) v WHERE v.\(auth.isAdmin ? "id" : "game_id") = ?)",
                                 arguments: visible.arguments + [gameID]) ?? false
    }
}
