import Foundation
import Hummingbird
import SupersEmuKit

extension AdminStatus: ResponseEncodable {}
extension RemoteAccessStatusResponse: ResponseEncodable {}
extension UserInfo: ResponseEncodable {}
extension UserGameAccess: ResponseEncodable {}
extension DeviceInfo: ResponseEncodable {}
extension TokenInfo: ResponseEncodable {}

// Track: CLI + admin. /v1/admin/users, /v1/admin/devices, /v1/admin/tokens, /v1/admin/status.
// Every route needs an admin user and the `users:admin` scope (device tokens of the admin have it).
func registerAdminUserRoutes(_ group: RouterGroup<SERequestContext>, store: ServerStore,
                             remoteAccess: RemoteAccessSource = .storedFile) {
    let admin = group.group("admin")

    @Sendable func libraryAdminCaller(_ context: SERequestContext) throws -> AuthContext {
        let auth = try requireUsersAdmin(context)
        try auth.require(.libraryWrite)
        return auth
    }

    admin.get("status") { _, context in
        _ = try requireUsersAdmin(context)
        return try store.adminStatus()
    }

    admin.get("remote-access") { _, context in
        _ = try requireUsersAdmin(context)
        return await store.remoteAccessStatus(source: remoteAccess)
    }

    admin.get("users") { _, context in
        _ = try requireUsersAdmin(context)
        return try store.listUsers()
    }

    admin.get("users/:id/games") { _, context in
        _ = try requireUsersAdmin(context)
        let id = try context.parameters.require("id")
        return try store.userGameAccess(userID: id)
    }

    admin.put("users/:id/games") { request, context in
        let auth = try libraryAdminCaller(context)
        let id = try context.parameters.require("id")
        let body = try await request.decode(as: SetUserGamesRequest.self, context: context)
        return try store.setUserGames(userID: id, hiddenGameIDs: body.hiddenGameIDs, by: auth)
    }

    admin.patch("users/:id") { request, context in
        let auth = try requireUsersAdmin(context)
        let id = try context.parameters.require("id")
        let body = try await request.decode(as: UpdateUserRequest.self, context: context)
        return try store.updateUser(id: id, displayName: try validatedDisplayName(body.displayName), by: auth)
    }

    admin.delete("users/:id") { _, context in
        let auth = try requireUsersAdmin(context)
        let id = try context.parameters.require("id")
        return try store.removeUser(id: id, by: auth)
    }

    admin.post("users") { request, context in
        let auth = try requireUsersAdmin(context)
        let body = try await request.decode(as: CreateUserRequest.self, context: context)
        let name = try validatedDisplayName(body.displayName)
        return EditedResponse(status: .created, response: try store.createPlayer(displayName: name, by: auth))
    }

    admin.get("devices") { _, context in
        _ = try requireUsersAdmin(context)
        return try store.listDevices()
    }

    admin.delete("devices/:id") { _, context in
        let auth = try requireUsersAdmin(context)
        let id = try context.parameters.require("id")
        guard let device = try store.revokeDevice(id: id, by: auth) else { throw HTTPError(.notFound, message: "No device \(id)") }
        return device
    }

    admin.get("tokens") { _, context in
        _ = try requireUsersAdmin(context)
        return try store.listAPITokens()
    }

    admin.post("tokens") { request, context in
        let auth = try requireUsersAdmin(context)
        let body = try await request.decode(as: CreateTokenRequest.self, context: context)
        let name = body.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw HTTPError(.badRequest, message: "name is required") }
        let scopes = Scope.allCases.filter(body.scopes.contains)
        guard !scopes.isEmpty else { throw HTTPError(.badRequest, message: "At least one scope is required") }
        // A scoped token can't mint a token with more rights than it has.
        if let missing = scopes.first(where: { !auth.has($0) }) {
            throw HTTPError(.forbidden, message: "Caller lacks scope \(missing.rawValue)")
        }
        return EditedResponse(status: .created, response: try store.createAPIToken(by: auth, name: name, scopes: scopes))
    }

    admin.delete("tokens/:id") { _, context in
        let auth = try requireUsersAdmin(context)
        let id = try context.parameters.require("id")
        guard let info = try store.revokeAPIToken(id: id, by: auth) else { throw HTTPError(.notFound, message: "No token \(id)") }
        return info
    }
}

/// Trimmed display name for a new or renamed user: 1 to 100 characters.
func validatedDisplayName(_ raw: String) throws -> String {
    let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !name.isEmpty, name.count <= 100 else {
        throw HTTPError(.badRequest, message: "displayName must be 1 to 100 characters")
    }
    return name
}
