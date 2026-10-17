import Foundation
import GRDB
import Hummingbird
import SupersEmuKit

// Track: server library. /v1/admin/library/import, scan, publish/permissions, review queue.
func registerAdminLibraryRoutes(_ group: RouterGroup<SERequestContext>, store: ServerStore, metadata: MetadataService? = nil) {
    let importer = LibraryImporter(store: store)

    group.post("admin/library/import") { request, context -> Response in
        let auth = try requireLibraryAdmin(context)
        try requireLibraryAvailable(store)
        let body = try await request.decode(as: ImportRequest.self, context: context)
        guard !body.paths.isEmpty else { throw HTTPError(.badRequest, message: "paths is empty") }
        let report = try await importer.importPaths(body.paths, auth: auth)
        metadata?.enqueue()
        return try LibraryHTTP.json(report)
    }

    // Body (an empty ImportRequest) is ignored: scan always reads the server's Incoming folder.
    group.post("admin/library/scan") { _, context -> Response in
        let auth = try requireLibraryAdmin(context)
        try requireLibraryAvailable(store)
        let report = try await importer.scanIncoming(auth: auth)
        metadata?.enqueue()
        return try LibraryHTTP.json(report)
    }

    group.post("admin/metadata/rematch") { request, context -> Response in
        let auth = try requireLibraryAdmin(context)
        let body = try await request.decode(as: MetadataRematchRequest.self, context: context)
        let queued = try await store.db.write { db -> Int in
            let count: Int
            if let gameIDs = body.gameIDs {
                let uniqueIDs = Array(Set(gameIDs))
                let existing = try Int.fetchOne(db, sql: """
                    SELECT COUNT(*) FROM games WHERE id IN (\(Array(repeating: "?", count: uniqueIDs.count).joined(separator: ",")))
                    """, arguments: StatementArguments(uniqueIDs)) ?? 0
                guard existing == uniqueIDs.count else { throw HTTPError(.notFound, message: "Game not found") }
                count = uniqueIDs.count
                if !uniqueIDs.isEmpty {
                    try db.execute(sql: "DELETE FROM metadata_jobs WHERE game_id IN (\(Array(repeating: "?", count: uniqueIDs.count).joined(separator: ",")))",
                                   arguments: StatementArguments(uniqueIDs))
                }
            } else {
                count = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM games") ?? 0
                try db.execute(sql: "DELETE FROM metadata_jobs")
            }
            try store.audit(auth, action: "metadata.rematch", detail: body.gameIDs?.joined(separator: ",") ?? "all", in: db)
            return count
        }
        metadata?.enqueue()
        return try LibraryHTTP.json(MetadataRematchResponse(queued: queued))
    }

    group.get("admin/library/review") { _, context -> Response in
        _ = try requireLibraryAdmin(context)
        return try LibraryHTTP.json(try importer.reviewQueue())
    }

    group.put("admin/permissions") { request, context -> Response in
        let auth = try requireLibraryAdmin(context)
        let requested = try await request.decode(as: PermissionGrant.self, context: context)
        let principalID = requested.principalType == .everyone ? "" : (requested.principalID?.trimmingCharacters(in: .whitespaces) ?? "")
        let grant = PermissionGrant(gameID: requested.gameID, principalType: requested.principalType,
                                    principalID: requested.principalType == .everyone ? nil : principalID)
        try await store.db.write { db in
            guard try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM games WHERE id = ?)", arguments: [grant.gameID]) == true else {
                throw HTTPError(.notFound, message: "Game not found")
            }
            switch grant.principalType {
            case .everyone:
                break
            case .user:
                guard try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM users WHERE id = ? AND revoked_at IS NULL)", arguments: [principalID]) == true else {
                    throw HTTPError(.notFound, message: "User not found")
                }
            case .group:
                guard try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM groups WHERE id = ?)", arguments: [principalID]) == true else {
                    throw HTTPError(.notFound, message: "Group not found")
                }
            }
            try db.execute(sql: "INSERT OR IGNORE INTO game_permissions (game_id, principal_type, principal_id) VALUES (?, ?, ?)",
                           arguments: [grant.gameID, grant.principalType.rawValue, grant.principalType == .everyone ? "" : principalID])
        }
        try store.audit(auth, action: "library.grant", detail: "\(grant.gameID) -> \(grant.principalType.rawValue):\(principalID)")
        return try LibraryHTTP.json(grant)
    }
}

@Sendable
func requireLibraryAdmin(_ context: SERequestContext) throws -> AuthContext {
    let auth = try context.caller()
    try auth.requireAdmin()
    try auth.require(.libraryWrite)
    return auth
}
