import Foundation
import Hummingbird
import SupersEmuKit

extension AdminStatus: ResponseEncodable {}
extension UserInfo: ResponseEncodable {}
extension DeviceInfo: ResponseEncodable {}
extension TokenInfo: ResponseEncodable {}

// Track: CLI + admin. /v1/admin/users, /v1/admin/devices, /v1/admin/tokens, /v1/admin/status.
// Every route needs an admin user and the `users:admin` scope (device tokens of the admin have it).
func registerAdminUserRoutes(_ group: RouterGroup<SERequestContext>, store: ServerStore) {
    let admin = group.group("admin")

    @Sendable func adminCaller(_ context: SERequestContext) throws -> AuthContext {
        let auth = try context.caller()
        try auth.requireAdmin()
        try auth.require(.usersAdmin)
        return auth
    }

    admin.get("status") { _, context in
        _ = try adminCaller(context)
        return try store.adminStatus()
    }

    admin.get("users") { _, context in
        _ = try adminCaller(context)
        return try store.listUsers()
    }

    admin.post("users") { request, context in
        let auth = try adminCaller(context)
        let body = try await request.decode(as: CreateUserRequest.self, context: context)
        let name = body.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw HTTPError(.badRequest, message: "displayName is required") }
        let user = try store.createUser(displayName: name, role: .player)
        try store.audit(auth, action: "user.create", detail: "\(user.id) \(user.displayName)")
        return EditedResponse(status: .created, response: user)
    }

    admin.get("devices") { _, context in
        _ = try adminCaller(context)
        return try store.listDevices()
    }

    admin.delete("devices/:id") { _, context in
        let auth = try adminCaller(context)
        let id = try context.parameters.require("id")
        guard let device = try store.device(id: id) else { throw HTTPError(.notFound, message: "No device \(id)") }
        if device.revokedAt != nil { return device }
        try store.revokeDevice(id)
        try store.audit(auth, action: "device.revoke", detail: "\(id) \(device.name)")
        return try store.device(id: id) ?? device
    }

    admin.get("tokens") { _, context in
        _ = try adminCaller(context)
        return try store.listAPITokens()
    }

    admin.post("tokens") { request, context in
        let auth = try adminCaller(context)
        let body = try await request.decode(as: CreateTokenRequest.self, context: context)
        let name = body.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw HTTPError(.badRequest, message: "name is required") }
        let scopes = Scope.allCases.filter(body.scopes.contains)
        guard !scopes.isEmpty else { throw HTTPError(.badRequest, message: "At least one scope is required") }
        // A scoped token can't mint a token with more rights than it has.
        if let missing = scopes.first(where: { !auth.has($0) }) {
            throw HTTPError(.forbidden, message: "Caller lacks scope \(missing.rawValue)")
        }
        let (id, token) = try store.createAPIToken(ownerUserID: auth.user.id, name: name, scopes: scopes)
        try store.audit(auth, action: "token.create", detail: "\(id) \(name) [\(scopes.map(\.rawValue).joined(separator: ","))]")
        guard var info = try store.apiToken(id: id) else { throw HTTPError(.internalServerError) }
        info.token = token
        return EditedResponse(status: .created, response: info)
    }

    admin.delete("tokens/:id") { _, context in
        let auth = try adminCaller(context)
        let id = try context.parameters.require("id")
        guard let info = try store.apiToken(id: id) else { throw HTTPError(.notFound, message: "No token \(id)") }
        if info.revokedAt != nil { return info }
        try store.revokeAPIToken(id)
        try store.audit(auth, action: "token.revoke", detail: "\(id) \(info.name)")
        return try store.apiToken(id: id) ?? info
    }
}
