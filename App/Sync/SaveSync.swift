import Foundation
import SupersEmuKit

/// The signed-in server, if any. The sign-in/pairing track sets `SaveSync.shared.provider`; until then the app
/// is local-only unless `SUPERSEMU_SERVER_URL` + `SUPERSEMU_SERVER_TOKEN` (a device token) are set.
final class CurrentServerProvider: SaveSyncServerProvider, @unchecked Sendable {
    private let lock = NSLock()
    private var client: APIClient?

    init(client: APIClient? = nil) { self.client = client }

    static func fromEnvironment(_ environment: [String: String] = ProcessInfo.processInfo.environment) -> CurrentServerProvider {
        guard let server = environment["SUPERSEMU_SERVER_URL"].flatMap(URL.init(string:)),
              let token = environment["SUPERSEMU_SERVER_TOKEN"], !token.isEmpty else { return CurrentServerProvider() }
        return CurrentServerProvider(client: APIClient(baseURL: server, token: token))
    }

    func set(_ client: APIClient?) { lock.withLock { self.client = client } }
    func currentClient() async -> APIClient? { lock.withLock { client } }
}

/// App-wide save sync: one engine (and one persisted offline queue) shared by every game session.
@MainActor
final class SaveSync {
    static let shared = SaveSync()

    let provider: CurrentServerProvider
    let engine: SaveSyncEngine

    init(provider: CurrentServerProvider = .fromEnvironment(),
         directory: URL = AppPaths.root.appendingPathComponent("Sync", isDirectory: true)) {
        self.provider = provider
        engine = SaveSyncEngine(directory: directory, provider: provider)
        Task { [engine] in await engine.flush() }
    }

    static let manualSlot = "slot1"

    static func nativeFile(for gameID: String) -> LocalSaveFile {
        // Battery saves are the game's own format, so any core version can use them.
        LocalSaveFile(line: SaveLine(gameID: gameID, kind: .native), url: AppPaths.saveRAM(for: gameID), core: nil,
                      requiresMatchingCore: false)
    }

    static func autoFile(for gameID: String, core: SaveCore) -> LocalSaveFile {
        LocalSaveFile(line: SaveLine(gameID: gameID, kind: .auto), url: AppPaths.autoState(for: gameID), core: core,
                      requiresMatchingCore: true)
    }

    static func manualFile(for gameID: String, core: SaveCore) -> LocalSaveFile {
        LocalSaveFile(line: SaveLine(gameID: gameID, kind: .manual, slot: manualSlot), url: AppPaths.manualState(for: gameID),
                      core: core, requiresMatchingCore: true)
    }

    /// Queues files that were just written locally and tries to upload them. Returns the line's sync status.
    @discardableResult
    func uploadAfterWrite(_ files: [LocalSaveFile]) async -> SaveSyncStatus? {
        var queued = false
        for file in files where FileManager.default.fileExists(atPath: file.url.path) {
            queued = await engine.enqueueUpload(file) || queued
        }
        guard queued, let last = files.last else { return nil }
        await engine.flush()
        return await engine.status(of: last.line)
    }
}
