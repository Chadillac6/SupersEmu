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
        _ = try requireUsersAdmin(context)
        return await store.backups.overview()
    }

    backups.post { request, context in
        let auth = try requireUsersAdmin(context)
        let body = try await request.decode(as: CreateBackupRequest.self, context: context)
        let info = try await mapped { try await store.backups.create(trigger: .manual, includeROMs: body.includeROMs) }
        try store.audit(auth, action: "backup.create", detail: info.id)
        return EditedResponse(status: .created, response: info)
    }

    backups.get("config") { _, context in
        _ = try requireUsersAdmin(context)
        return await store.backups.config()
    }

    backups.put("config") { request, context in
        let auth = try requireUsersAdmin(context)
        let update = try await request.decode(as: BackupConfigUpdate.self, context: context)
        let config = try await mapped { try await store.backups.updateConfig(update) }
        try store.audit(auth, action: "backup.config", detail: "destination=\(config.destination ?? "default") keep=\(config.keep) includeROMs=\(config.includeROMs)")
        return config
    }

    backups.post(":id/verify") { _, context in
        _ = try requireUsersAdmin(context)
        let id = try context.parameters.require("id")
        return try await mapped { try await store.backups.verify(id: id) }
    }

    backups.post(":id/restore") { _, context in
        let auth = try requireUsersAdmin(context)
        let id = try context.parameters.require("id")
        let info = try await mapped { try await store.backups.requestRestore(id: id) }
        try store.audit(auth, action: "backup.restore", detail: info.id)
        return EditedResponse(status: .accepted, response: RestoreBackupResponse(
            backup: info, message: "Restoring \(info.id). The server stops serving, restores and restarts; this takes a few seconds.",
            certificateSHA256: TLSIdentity.storedFingerprint(paths: ServerPaths(root: URL(fileURLWithPath: info.path, isDirectory: true)))))
    }
}
