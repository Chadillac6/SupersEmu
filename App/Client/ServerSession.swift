import Foundation
import Observation
import SupersEmuKit
#if os(iOS)
import UIKit
#endif

/// The app's connection to its SupersEmu Server: pairing, the last known library, and online/offline state.
@MainActor
@Observable
final class ServerSession {
    enum Status: Equatable {
        case notPaired
        case connecting
        case online
        case offline(String)
    }

    private(set) var credential: ServerCredential?
    private(set) var status: Status
    /// Last library the server returned; kept on disk so downloaded games stay browsable offline.
    private(set) var games: [GameSummary] = []
    private(set) var firstSeen: [String: Date] = [:]
    private(set) var activeURL: URL?
    private(set) var lastRefreshed: Date?

    @ObservationIgnored private let store: CredentialStore
    @ObservationIgnored private let snapshotURL: URL
    @ObservationIgnored private var urlSession: URLSession?
    @ObservationIgnored private var refreshTask: Task<Void, Never>?
    /// Bumped on pair/sign-out so responses for a previous connection are dropped.
    @ObservationIgnored private var generation = 0

    init(store: CredentialStore = ServerSession.defaultStore(), snapshotURL: URL = AppPaths.serverLibrarySnapshot) {
        self.store = store
        self.snapshotURL = snapshotURL
        let saved = store.load()
        credential = saved
        status = saved == nil ? .notPaired : .connecting
        if saved != nil { loadSnapshot() }
    }

    nonisolated static func defaultStore() -> CredentialStore {
        #if DEBUG
        if let store = LaunchEnvironmentCredentialStore() { return store }
        #endif
        return KeychainCredentialStore()
    }

    var isPaired: Bool { credential != nil }
    var isOnline: Bool { status == .online }
    var serverName: String { credential?.serverName ?? "SupersEmu Server" }

    /// Client for the server URL that answered last (LAN first, then Tailscale).
    func client() -> APIClient? {
        guard let credential, let url = activeURL ?? credential.urls.first else { return nil }
        return APIClient(baseURL: url, token: credential.token, session: session(pin: credential.certificateSHA256))
    }

    func pair(_ payload: PairingPayload) async throws {
        let request = PairRequest(code: payload.code, deviceName: Self.deviceName, platform: Self.platform)
        var lastError: Error = APIClientError.invalidResponse
        for url in payload.urls {
            let client = APIClient(baseURL: url, token: nil, session: session(pin: payload.certificateSHA256))
            do {
                let response = try await client.pair(request)
                let credential = ServerCredential(
                    serverName: response.serverName, urls: payload.urls, certificateSHA256: payload.certificateSHA256,
                    token: response.token, deviceID: response.deviceID, user: response.user)
                try store.save(credential)
                generation += 1
                refreshTask?.cancel()
                refreshTask = nil
                urlSession = nil
                self.credential = credential
                activeURL = url
                status = .connecting
                await refresh()
                return
            } catch let error as APIClientError {
                throw error
            } catch {
                lastError = error
            }
        }
        throw lastError
    }

    /// Re-fetches the library. Called on launch, when the app returns to the foreground, and from Retry.
    func refresh() async {
        if let refreshTask { return await refreshTask.value }
        let task = Task { await performRefresh() }
        refreshTask = task
        await task.value
        refreshTask = nil
    }

    private func performRefresh() async {
        guard let credential else { status = .notPaired; return }
        let generation = self.generation
        if status != .online { status = .connecting }
        let candidates = [activeURL].compactMap { $0 } + credential.urls.filter { $0 != activeURL }
        var failure = "Can't reach \(credential.serverName)"
        for url in candidates {
            let client = APIClient(baseURL: url, token: credential.token, session: session(pin: credential.certificateSHA256))
            do {
                let library = try await client.library()
                guard generation == self.generation else { return }
                activeURL = url
                apply(library.games)
                lastRefreshed = Date()
                status = .online
                return
            } catch APIClientError.http(let code, _) where code == 401 {
                guard generation == self.generation else { return }
                failure = "This device was signed out by \(credential.serverName). Pair it again."
                status = .offline(failure)
                return
            } catch {
                continue
            }
        }
        guard generation == self.generation else { return }
        status = .offline(failure)
    }

    func signOut() {
        generation += 1
        refreshTask?.cancel()
        refreshTask = nil
        store.delete()
        urlSession = nil
        credential = nil
        activeURL = nil
        games = []
        firstSeen = [:]
        try? FileManager.default.removeItem(at: snapshotURL)
        status = .notPaired
    }

    func detail(for gameID: String) async throws -> GameDetail {
        guard let client = client() else { throw APIClientError.invalidResponse }
        return try await client.gameDetail(gameID)
    }

    func data(atPath path: String) async throws -> Data {
        guard let client = client() else { throw APIClientError.invalidResponse }
        return try await client.raw("GET", path)
    }

    func downloader(cache: GameCache) -> GameDownloader? {
        guard let client = client() else { return nil }
        let pin = credential?.certificateSHA256
        return GameDownloader(client: client, cache: cache, trust: { PinnedTrustDelegate.evaluate($0, pin: pin) })
    }

    private func apply(_ games: [GameSummary]) {
        let now = Date()
        for game in games where firstSeen[game.id] == nil { firstSeen[game.id] = game.addedAt ?? now }
        firstSeen = firstSeen.filter { id, _ in games.contains { $0.id == id } }
        self.games = games
        saveSnapshot()
    }

    private func session(pin: String?) -> URLSession {
        if let urlSession { return urlSession }
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 8
        configuration.waitsForConnectivity = false
        let session = URLSession(configuration: configuration, delegate: PinnedTrustDelegate(certificateSHA256: pin), delegateQueue: nil)
        if credential != nil { urlSession = session }
        return session
    }

    private struct Snapshot: Codable {
        var games: [GameSummary]
        var firstSeen: [String: Date]
    }

    private func loadSnapshot() {
        guard let data = try? Data(contentsOf: snapshotURL),
              let snapshot = try? SupersEmuJSON.decoder().decode(Snapshot.self, from: data) else { return }
        games = snapshot.games
        firstSeen = snapshot.firstSeen
    }

    private func saveSnapshot() {
        try? FileManager.default.createDirectory(at: snapshotURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? SupersEmuJSON.encoder().encode(Snapshot(games: games, firstSeen: firstSeen)).write(to: snapshotURL, options: .atomic)
    }

    static var deviceName: String {
        #if os(iOS)
        UIDevice.current.name
        #else
        Host.current().localizedName ?? "Mac"
        #endif
    }

    static var platform: String {
        #if os(iOS)
        UIDevice.current.userInterfaceIdiom == .pad ? "ipados" : "ios"
        #else
        "macos"
        #endif
    }
}
