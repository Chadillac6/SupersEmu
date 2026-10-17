import Foundation
import SupersEmuKit

/// The signed-in server, if any: the paired `ServerSession` (wired in `RootView`), or for dev/tests a fixed
/// client from `SUPERSEMU_SERVER_URL` + `SUPERSEMU_SERVER_TOKEN` (a device token). Neither = local-only.
final class CurrentServerProvider: SaveSyncServerProvider, @unchecked Sendable {
    private let lock = NSLock()
    private var client: APIClient?
    private var resolver: (@MainActor @Sendable () -> APIClient?)?
    private var reachable: (@MainActor @Sendable () -> Bool)?

    init(client: APIClient? = nil) { self.client = client }

    static func fromEnvironment(_ environment: [String: String] = ProcessInfo.processInfo.environment) -> CurrentServerProvider {
        guard let server = environment["SUPERSEMU_SERVER_URL"].flatMap(URL.init(string:)),
              LaunchEnvironment.isAllowedLaunchURL(server),
              let token = environment["SUPERSEMU_SERVER_TOKEN"], !token.isEmpty else { return CurrentServerProvider() }
        return CurrentServerProvider(client: APIClient(baseURL: server, token: token))
    }

    func set(_ client: APIClient?) { lock.withLock { self.client = client } }
    /// Asks `resolver` for the current client at each sync, so pairing, sign-out and network changes apply.
    func use(_ resolver: @escaping @MainActor @Sendable () -> APIClient?, reachable: (@MainActor @Sendable () -> Bool)? = nil) {
        lock.withLock {
            self.resolver = resolver
            self.reachable = reachable
        }
    }

    func isReachable() async -> Bool {
        let (client, reachable) = lock.withLock { (self.client, self.reachable) }
        guard client == nil, let reachable else { return true }
        return await reachable()
    }

    func currentClient() async -> APIClient? {
        let (client, resolver) = lock.withLock { (self.client, self.resolver) }
        if let client { return client }
        guard let resolver else { return nil }
        return await resolver()
    }
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

    static func nativeFile(for gameID: String) -> LocalSaveFile {
        // Battery saves are the game's own format, so any core version can use them.
        LocalSaveFile(line: SaveLine(gameID: gameID, kind: .native), url: AppPaths.saveRAM(for: gameID), core: nil,
                      requiresMatchingCore: false)
    }

    static func autoFile(for gameID: String, core: SaveCore) -> LocalSaveFile {
        LocalSaveFile(line: SaveLine(gameID: gameID, kind: .auto), url: AppPaths.autoState(for: gameID), core: core,
                      requiresMatchingCore: true)
    }

    static func manualFile(for gameID: String, slot: Int, core: SaveCore) -> LocalSaveFile {
        let store = SaveSlotStore(directory: AppPaths.stateDirectory(for: gameID))
        return LocalSaveFile(line: SaveLine(gameID: gameID, kind: .manual, slot: SaveSlotStore.lineSlot(slot)), url: store.stateURL(slot),
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
