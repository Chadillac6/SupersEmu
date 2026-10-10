import Foundation
import Network
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
    /// Home network / Tailscale / unreachable / signed out / certificate mismatch. Retries with backoff on its own.
    private(set) var connection: ConnectionState
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
    @ObservationIgnored private var monitor: ConnectionMonitor
    @ObservationIgnored private var retryTask: Task<Void, Never>?
    @ObservationIgnored private var trust: PinnedCertificateDelegate?
    @ObservationIgnored private var pathMonitor: NWPathMonitor?
    @ObservationIgnored private var lastPath: String?

    init(store: CredentialStore = ServerSession.defaultStore(), snapshotURL: URL = AppPaths.serverLibrarySnapshot) {
        self.store = store
        self.snapshotURL = snapshotURL
        let saved = store.load()
        credential = saved
        monitor = ConnectionMonitor(paired: saved != nil)
        connection = monitor.state
        if saved != nil { loadSnapshot() }
        startPathMonitor()
    }

    nonisolated static func defaultStore() -> CredentialStore {
        #if DEBUG
        if let store = LaunchEnvironmentCredentialStore() { return store }
        #endif
        return KeychainCredentialStore()
    }

    var isPaired: Bool { credential != nil }
    var isOnline: Bool { connection.isConnected }
    /// False once a refresh has found the server unreachable; save sync then queues without waiting on timeouts.
    var isReachable: Bool { connection.mayReachServer }

    var status: Status {
        switch connection {
        case .signedOut(.notPaired): return .notPaired
        case .connecting: return .connecting
        case .connected: return .online
        default: return .offline(connection.message(serverName: serverName)?.title ?? "Can't reach \(serverName)")
        }
    }
    var serverName: String { credential?.serverName ?? "SupersEmu Server" }

    /// Client for the server URL that answered last (LAN first, then Tailscale).
    func client() -> APIClient? {
        guard let credential, let url = activeURL ?? credential.urls.first else { return nil }
        return APIClient(baseURL: url, token: credential.token, session: session(pin: credential.certificateSHA256))
    }

    func pair(_ payload: PairingPayload) async throws {
        let request = PairRequest(code: payload.code, deviceName: Self.deviceName, platform: Self.platform)
        // Device tokens are bearer secrets: only pair over HTTPS (plain HTTP is allowed for loopback dev servers).
        let urls = payload.urls.filter { $0.scheme == "https" || ($0.scheme == "http" && Self.isLoopback($0)) }
        guard !urls.isEmpty else { throw PairingError.insecureAddress }
        var lastError: Error = APIClientError.invalidResponse
        for url in urls {
            let trust = PinnedCertificateDelegate(certificateSHA256: payload.certificateSHA256, trustOnFirstUse: true, expectedHost: url.host)
            let pairingSession = URLSession(configuration: Self.configuration, delegate: trust, delegateQueue: nil)
            defer { pairingSession.finishTasksAndInvalidate() }
            let client = APIClient(baseURL: url, token: nil, session: pairingSession)
            do {
                let response = try await client.pair(request)
                let pin = payload.certificateSHA256 ?? (url.scheme == "https" ? trust.observedSHA256 : nil)
                let credential = ServerCredential(
                    serverName: response.serverName, urls: urls, certificateSHA256: pin,
                    token: response.token, deviceID: response.deviceID, user: response.user)
                try store.save(credential)
                generation += 1
                refreshTask?.cancel()
                refreshTask = nil
                urlSession = nil
                self.credential = credential
                activeURL = url
                self.trust = nil
                monitor.paired()
                publish()
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

    /// Retry button: skips the remaining backoff.
    func retryNow() async {
        monitor.networkChanged()
        await refresh()
    }

    /// Re-fetches the library. Called on launch, when the app returns to the foreground, on network changes,
    /// from Retry and by the backoff timer.
    func refresh() async {
        if let refreshTask { return await refreshTask.value }
        let task = Task { await performRefresh() }
        refreshTask = task
        await task.value
        refreshTask = nil
    }

    private func performRefresh() async {
        guard let credential else {
            monitor.signedOut()
            publish()
            return
        }
        let generation = self.generation
        let candidates = [activeURL].compactMap { $0 } + credential.urls.filter { $0 != activeURL }
        var failure = ConnectionFailure.unreachable
        for url in candidates {
            let client = APIClient(baseURL: url, token: credential.token, session: session(pin: credential.certificateSHA256))
            let rejections = trust?.rejectionCount ?? 0
            do {
                let library = try await client.library()
                guard generation == self.generation else { return }
                activeURL = url
                apply(library.games)
                lastRefreshed = Date()
                monitor.succeeded(via: url)
                publish()
                retryTask?.cancel()
                retryTask = nil
                return
            } catch {
                guard generation == self.generation else { return }
                switch ConnectionFailure.classify(error, certificateRejected: (trust?.rejectionCount ?? 0) != rejections) {
                case .signedOut:
                    monitor.failed(.signedOut)
                    publish()
                    return
                case .certificateMismatch:
                    failure = .certificateMismatch
                case .unreachable:
                    continue
                }
            }
        }
        guard generation == self.generation else { return }
        monitor.failed(failure)
        publish()
        scheduleRetry()
    }

    private func publish() {
        if connection != monitor.state { connection = monitor.state }
    }

    private func scheduleRetry() {
        retryTask?.cancel()
        guard let delay = monitor.retryDelay else { return }
        let generation = self.generation
        retryTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled, let self, generation == self.generation else { return }
            await self.refresh()
        }
    }

    /// Joining Wi-Fi, leaving home or toggling Tailscale (a new utun interface) retries right away.
    private func startPathMonitor() {
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            let signature = "\(path.status)|" + path.availableInterfaces.map(\.name).joined(separator: ",")
            let satisfied = path.status == .satisfied
            Task { @MainActor [weak self] in self?.networkChanged(signature: signature, satisfied: satisfied) }
        }
        monitor.start(queue: DispatchQueue(label: "SupersEmu.ServerSession.path"))
        pathMonitor = monitor
    }

    private func networkChanged(signature: String, satisfied: Bool) {
        defer { lastPath = signature }
        guard let lastPath, lastPath != signature, credential != nil else { return }
        monitor.networkChanged()
        retryTask?.cancel()
        retryTask = nil
        guard satisfied else { return }
        // The old connection may be gone (or a better route available); drop pooled connections.
        urlSession?.finishTasksAndInvalidate()
        urlSession = nil
        trust = nil
        Task { await refresh() }
    }

    static func isLoopback(_ url: URL) -> Bool {
        ["127.0.0.1", "localhost", "::1"].contains(url.host?.lowercased() ?? "")
    }

    func signOut() {
        // Queued saves belong to this account; never let the next pairing upload them.
        Task { await SaveSync.shared.engine.reset() }
        generation += 1
        refreshTask?.cancel()
        refreshTask = nil
        retryTask?.cancel()
        retryTask = nil
        store.delete()
        urlSession = nil
        trust = nil
        credential = nil
        activeURL = nil
        games = []
        firstSeen = [:]
        try? FileManager.default.removeItem(at: snapshotURL)
        monitor.signedOut()
        publish()
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
        return GameDownloader(client: client, cache: cache, trust: { PinnedCertificateDelegate.disposition(for: $0, pin: pin) })
    }

    private func apply(_ games: [GameSummary]) {
        let now = Date()
        for game in games where firstSeen[game.id] == nil { firstSeen[game.id] = game.addedAt ?? now }
        firstSeen = firstSeen.filter { id, _ in games.contains { $0.id == id } }
        self.games = games
        saveSnapshot()
    }

    private static var configuration: URLSessionConfiguration {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 8
        configuration.waitsForConnectivity = false
        return configuration
    }

    private func session(pin: String?) -> URLSession {
        if let urlSession { return urlSession }
        let delegate = PinnedCertificateDelegate(certificateSHA256: pin)
        let session = URLSession(configuration: Self.configuration, delegate: delegate, delegateQueue: nil)
        if credential != nil {
            urlSession = session
            trust = delegate
        }
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

enum PairingError: LocalizedError {
    case insecureAddress

    var errorDescription: String? {
        switch self {
        case .insecureAddress: return "Use an https:// server address to pair."
        }
    }
}
