import Foundation
import Hummingbird
import SupersEmuKit

extension CheatListResponse: ResponseEncodable {}
extension CheatRecord: ResponseEncodable {}

// Track: cheats. Every route is scoped to the caller's own user, like saves.
func registerCheatRoutes(_ group: RouterGroup<SERequestContext>, store: ServerStore) {
    let cheats = CheatStore(store: store)
    let saves = SaveStore(store: store)

    // Query: since=<revision>. Returns every change (tombstones included) newer than `since`.
    group.get("cheats") { request, context in
        let auth = try context.caller()
        try auth.require(.savesRead)
        let since = request.uri.queryParameters["since"].flatMap { Int(String($0)) } ?? 0
        return try cheats.changes(userID: auth.user.id, since: max(0, since))
    }

    group.get("cheats/:game") { _, context in
        let auth = try context.caller()
        try auth.require(.savesRead)
        let gameID = try context.parameters.require("game")
        try saves.authorize(gameID: gameID, auth: auth)
        return try cheats.list(userID: auth.user.id, gameID: gameID)
    }

    group.put("cheats/:game/:id") { request, context -> CheatRecord in
        let auth = try context.caller()
        guard case .device(let deviceID) = auth.credential else {
            throw HTTPError(.forbidden, message: "Only paired devices can change cheats")
        }
        let gameID = try context.parameters.require("game")
        try saves.authorize(gameID: gameID, auth: auth)
        guard let id = UUID(uuidString: try context.parameters.require("id")) else {
            throw HTTPError(.badRequest, message: "Invalid cheat id")
        }
        var request = request
        let body = try await request.collectBody(upTo: 16 * 1024)
        let record: CheatRecord
        do {
            record = try SupersEmuJSON.decoder().decode(CheatRecord.self, from: Data(body.readableBytesView))
        } catch {
            throw HTTPError(.badRequest, message: "Invalid cheat")
        }
        guard record.id == id, record.gameID == gameID else { throw HTTPError(.badRequest, message: "Cheat id or game doesn't match the URL") }
        let saved = try cheats.put(userID: auth.user.id, deviceID: deviceID, record)
        try store.audit(auth, action: "cheat.put", detail: "\(gameID) \(id.uuidString)\(saved.deleted ? " deleted" : "")")
        return saved
    }
}
