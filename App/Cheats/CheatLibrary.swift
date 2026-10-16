import Foundation
import Observation
import SupersEmuKit

/// What the running core did with one saved cheat.
enum CheatRunState: Equatable {
    /// Turned off, so never sent.
    case off
    /// Not a valid code for this system; never sent.
    case invalid
    /// The core's cheat count went up after this code.
    case applied
    /// Sent, but the core can't confirm it took the code.
    case sent
    /// Sent and ignored by the core.
    case rejected

    var label: String {
        switch self {
        case .off: "Off"
        case .invalid: "Invalid code"
        case .applied: "Applied"
        case .sent: "Sent"
        case .rejected: "Rejected by core"
        }
    }
}

/// App-wide cheats: one `CheatSyncEngine` (files under `AppPaths.cheats`) shared by the library and the player.
@MainActor
@Observable
final class CheatLibrary {
    static let shared = CheatLibrary()

    @ObservationIgnored let engine: CheatSyncEngine
    private(set) var byGame: [String: [CheatRecord]] = [:]
    private(set) var status: CheatSyncStatus = .deviceOnly
    private(set) var isSyncing = false

    init(engine: CheatSyncEngine? = nil) {
        self.engine = engine ?? CheatSyncEngine(directory: AppPaths.cheats, provider: SaveSync.shared.provider)
    }

    func cheats(for gameID: String) -> [CheatRecord] { byGame[gameID] ?? [] }

    /// Reads this device's copy only, so launching a game never waits on the network.
    @discardableResult
    func load(_ gameID: String) async -> [CheatRecord] {
        let cheats = await engine.cheats(for: gameID)
        byGame[gameID] = cheats
        return cheats
    }

    func save(_ records: [CheatRecord]) async throws {
        // Reload even on failure: the record may be on disk though its upload couldn't be queued.
        do { try await engine.save(records) } catch {
            for gameID in Set(records.map(\.gameID)) { await load(gameID) }
            throw error
        }
        for gameID in Set(records.map(\.gameID)) { await load(gameID) }
        Task { await sync() }
    }

    func delete(_ cheat: CheatRecord) async throws {
        do { try await engine.delete(cheat.id, gameID: cheat.gameID) } catch {
            await load(cheat.gameID)
            throw error
        }
        await load(cheat.gameID)
        Task { await sync() }
    }

    func sync() async {
        isSyncing = true
        status = await engine.sync()
        isSyncing = false
        for gameID in byGame.keys { await load(gameID) }
    }

    var statusText: String {
        switch status {
        case .deviceOnly: "Saved on this device. Pair with your server to sync."
        case .serverTooOld: "Your server doesn't sync cheats yet. Saved on this device."
        case .offline(let pending): pending > 0 ? "Offline. \(pending) change\(pending == 1 ? "" : "s") will sync later." : "Offline. Saved on this device."
        case .failed(let message, let pending): "Couldn't sync (\(message)).\(pending > 0 ? " \(pending) change\(pending == 1 ? "" : "s") will retry." : "")"
        case .synced: "Synced with your server."
        }
    }

    var statusIsProblem: Bool {
        switch status {
        case .failed, .offline, .serverTooOld: true
        default: false
        }
    }
}
