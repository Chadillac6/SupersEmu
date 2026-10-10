import Foundation
import Hummingbird
import SupersEmuKit

extension BackupOverview: ResponseEncodable {}
extension BackupInfo: ResponseEncodable {}
extension BackupConfig: ResponseEncodable {}
extension RestoreBackupResponse: ResponseEncodable {}

// Track: backups. /v1/admin/backups. Admin user + `users:admin` scope, like the other admin routes.
func registerBackupRoutes(_ group: RouterGroup<SERequestContext>, store: ServerStore) {
    let backups = group.group("admin/backups")

    @Sendable func adminCaller(_ context: SERequestContext) throws -> AuthContext {
        let auth = try context.caller()
        try auth.requireAdmin()
        try auth.require(.usersAdmin)
        return auth
    }

    @Sendable func audit(_ auth: AuthContext, _ action: String, _ detail: String) {
        try? store.db.write { try ServerStore.insertAudit($0, auth, action: action, detail: detail) }
    }

    @Sendable func mapped<T>(_ body: () async throws -> T) async throws -> T {
        do {
            return try await body()
        } catch let error as BackupError {
            let status: HTTPResponse.Status = switch error {
            case .notFound: .notFound
            case .corrupted: .unprocessableContent
            case .alreadyRunning, .restoreUnavailable: .conflict
            case .destinationUnavailable: .serviceUnavailable
            case .invalidConfig: .badRequest
            }
            throw HTTPError(status, message: error.description)
        }
    }

    backups.get { _, context in
        _ = try adminCaller(context)
        return await store.backups.overview()
    }

    backups.post { request, context in
        let auth = try adminCaller(context)
        let body = try await request.decode(as: CreateBackupRequest.self, context: context)
        let info = try await mapped { try await store.backups.create(trigger: .manual, includeROMs: body.includeROMs) }
        audit(auth, "backup.create", info.id)
        return EditedResponse(status: .created, response: info)
    }

    backups.get("config") { _, context in
        _ = try adminCaller(context)
        return await store.backups.config()
    }

    backups.put("config") { request, context in
        let auth = try adminCaller(context)
        let update = try await request.decode(as: BackupConfigUpdate.self, context: context)
        let config = try await mapped { try await store.backups.updateConfig(update) }
        audit(auth, "backup.config", "destination=\(config.destination ?? "default") keep=\(config.keep) includeROMs=\(config.includeROMs)")
        return config
    }

    backups.post(":id/verify") { _, context in
        _ = try adminCaller(context)
        let id = try context.parameters.require("id")
        return try await mapped { try await store.backups.verify(id: id) }
    }

    backups.post(":id/restore") { _, context in
        let auth = try adminCaller(context)
        let id = try context.parameters.require("id")
        let info = try await mapped { try await store.backups.requestRestore(id: id) }
        audit(auth, "backup.restore", info.id)
        return EditedResponse(status: .accepted, response: RestoreBackupResponse(
            backup: info, message: "Restoring \(info.id). The server stops serving, restores and restarts; this takes a few seconds.",
            certificateSHA256: TLSIdentity.storedFingerprint(paths: ServerPaths(root: URL(fileURLWithPath: info.path, isDirectory: true)))))
    }
}
