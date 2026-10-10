import Foundation
import Hummingbird
import SupersEmuKit

extension SaveListResponse: ResponseEncodable {}
extension SaveUploadResponse: ResponseEncodable {}

// Track: save sync. Every route is scoped to the caller's own user; nobody can read another user's saves.
func registerSaveRoutes(_ group: RouterGroup<SERequestContext>, store: ServerStore, configuration: SaveConfiguration = .standard) {
    let saves = SaveStore(store: store, configuration: configuration)

    group.get("saves/:game") { _, context in
        let auth = try context.caller()
        try auth.require(.savesRead)
        let gameID = try context.parameters.require("game")
        try saves.authorize(gameID: gameID, auth: auth)
        return SaveListResponse(revisions: try saves.list(userID: auth.user.id, gameID: gameID))
    }

    // Query: slot, parent, core, coreVersion, optional sha256, optional branch=1 (keep as a branch, never the head).
    // Body: raw save bytes.
    group.put("saves/:game/:kind") { request, context -> SaveUploadResponse in
        let auth = try context.caller()
        // No API-token scope can write saves; only a paired device (acting as its user) uploads.
        guard case .device(let deviceID) = auth.credential else {
            throw HTTPError(.forbidden, message: "Only paired devices can upload saves")
        }
        let gameID = try context.parameters.require("game")
        try saves.authorize(gameID: gameID, auth: auth)
        guard let kind = SaveKind(rawValue: try context.parameters.require("kind")) else {
            throw HTTPError(.badRequest, message: "Unknown save kind")
        }
        let query = request.uri.queryParameters
        func value(_ name: String) -> String? { query[name[...]].map(String.init).flatMap { $0.isEmpty ? nil : $0 } }
        var request = request
        let body = try await request.collectBody(upTo: configuration.maxBytes)
        let response = try saves.upload(userID: auth.user.id, .init(
            gameID: gameID, kind: kind, slot: value("slot") ?? "", parentID: value("parent"),
            coreID: value("core") ?? "", coreVersion: value("coreVersion") ?? "", deviceID: deviceID,
            expectedSHA256: value("sha256"), keepAsBranch: value("branch") == "1", data: Data(body.readableBytesView)))
        try store.audit(auth, action: "save.upload",
                        detail: "\(gameID) \(kind.rawValue)/\(response.revision.slot) \(response.revision.id)\(response.branched ? " branched" : "")")
        return response
    }

    group.get("saves/:game/revisions/:rev") { _, context -> Response in
        let auth = try context.caller()
        try auth.require(.savesRead)
        let gameID = try context.parameters.require("game")
        try saves.authorize(gameID: gameID, auth: auth)
        var deviceID: String?
        if case .device(let id) = auth.credential { deviceID = id }
        let data = try saves.data(userID: auth.user.id, gameID: gameID, revisionID: try context.parameters.require("rev"), deviceID: deviceID)
        return Response(status: .ok, headers: [.contentType: "application/octet-stream"],
                        body: .init(byteBuffer: ByteBuffer(bytes: data)))
    }
}
