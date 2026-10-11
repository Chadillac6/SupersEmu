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
    /// When the server came back after being unreachable (or presenting the wrong certificate).
    private(set) var recoveredAt: Date?

    @ObservationIgnored private let store: CredentialStore
    @ObservationIgnored private let snapshotURL: URL
    @ObservationIgnored private var urlSession: URLSession?
    @ObservationIgnored private var refreshTask: Task<Void, Never>?
    @ObservationIgnored private var libraryRevision: String?
    /// Bumped on pair/sign-out so responses for a previous connection are dropped.
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var monitor: ConnectionMonitor
    @ObservationIgnored private var retryTask: Task<Void, Never>?
    @ObservationIgnored private var heartbeatTask: Task<Void, Never>?
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

    func presentedCertificateSHA256(at url: URL) async throws -> String {
        guard url.scheme?.lowercased() == "https", let host = url.host else { throw PairingError.fingerprintUnavailable }
        let trust = PinnedCertificateDelegate(certificateSHA256: nil, trustOnFirstUse: true, expectedHost: host)
        let pairingSession = URLSession(configuration: Self.configuration, delegate: trust, delegateQueue: nil)
        defer { pairingSession.finishTasksAndInvalidate() }
        _ = try await APIClient(baseURL: url, token: nil, session: pairingSession).health()
        guard let fingerprint = trust.observedSHA256 else { throw PairingError.fingerprintUnavailable }
        return fingerprint
    }

    func pair(_ payload: PairingPayload, confirmedCertificateSHA256: String? = nil) async throws {
        let request = PairRequest(code: payload.code, deviceName: Self.deviceName, platform: Self.platform)
        // Device tokens are bearer secrets: only pair over HTTPS (plain HTTP is allowed for loopback dev servers).
        let urls = payload.urls.filter { $0.scheme == "https" || ($0.scheme == "http" && Self.isLoopback($0)) }
        guard !urls.isEmpty else { throw PairingError.insecureAddress }
        let pin = payload.certificateSHA256 ?? confirmedCertificateSHA256
        guard !urls.contains(where: { $0.scheme?.lowercased() == "https" }) || pin != nil else {
            throw PairingError.fingerprintConfirmationRequired
        }
        var lastError: Error = APIClientError.invalidResponse
        for url in urls {
            let trust = PinnedCertificateDelegate(certificateSHA256: pin)
            let pairingSession = URLSession(configuration: Self.configuration, delegate: trust, delegateQueue: nil)
            defer { pairingSession.finishTasksAndInvalidate() }
            let client = APIClient(baseURL: url, token: nil, session: pairingSession)
            do {
                let response = try await client.pair(request)
                let credential = ServerCredential(
                    serverName: response.serverName, urls: urls, certificateSHA256: pin,
                    token: response.token, deviceID: response.deviceID, user: response.user)
                try store.save(credential)
                generation += 1
                refreshTask?.cancel()
                refreshTask = nil
                urlSession = nil
                self.credential = credential
                libraryRevision = nil
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

    func pair(response: PairResponse, at url: URL, certificateSHA256: String) async throws {
        let credential = ServerCredential(serverName: response.serverName, urls: [url],
                                          certificateSHA256: certificateSHA256, token: response.token,
                                          deviceID: response.deviceID, user: response.user)
        try store.save(credential)
        generation += 1
        refreshTask?.cancel()
        refreshTask = nil
        urlSession = nil
        self.credential = credential
        libraryRevision = nil
        activeURL = url
        trust = nil
        monitor.paired()
        publish()
        await refresh()
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
                if connection == .unreachable || connection == .certificateMismatch { recoveredAt = Date() }
                monitor.succeeded(via: url)
                publish()
                startHeartbeat()
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

    /// Notices the server going away while connected (e.g. the Mac mini shut down) without waiting for a refresh.
    private func startHeartbeat() {
        guard heartbeatTask == nil else { return }
        heartbeatTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 15_000_000_000)
                guard !Task.isCancelled, let self else { return }
                await self.heartbeat()
            }
        }
    }

    private func heartbeat() async {
        guard connection.isConnected, refreshTask == nil, let credential, let url = activeURL else { return }
        let client = APIClient(baseURL: url, token: credential.token, session: session(pin: credential.certificateSHA256))
        do {
            let health = try await client.health()
            guard let revision = health.libraryRevision else { return }
            guard revision != libraryRevision else { return }
            libraryRevision = revision
            ArtworkCache.revalidateAll()
            await refresh()
        } catch {
            await refresh()
        }
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
            Task { @MainActor [weak self] in self?.networkChanged(signature: signature) }
        }
        monitor.start(queue: DispatchQueue(label: "SupersEmu.ServerSession.path"))
        pathMonitor = monitor
    }

    private func networkChanged(signature: String) {
        defer { lastPath = signature }
        guard let lastPath, lastPath != signature, credential != nil else { return }
        monitor.networkChanged()
        retryTask?.cancel()
        retryTask = nil
        // The old connection may be gone (or a better route available); drop pooled connections.
        urlSession?.finishTasksAndInvalidate()
        urlSession = nil
        trust = nil
        // Always try again, even with no network (a loopback server still works): a failure schedules the backoff.
        Task {
            await refreshTask?.value
            await refresh()
        }
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
        heartbeatTask?.cancel()
        heartbeatTask = nil
        store.delete()
        urlSession = nil
        trust = nil
        credential = nil
        libraryRevision = nil
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
    case fingerprintUnavailable
    case fingerprintConfirmationRequired

    var errorDescription: String? {
        switch self {
        case .insecureAddress: return "Use an https:// server address to pair."
        case .fingerprintUnavailable: return "Couldn't read the server's TLS certificate fingerprint."
        case .fingerprintConfirmationRequired: return "Confirm the server's TLS fingerprint before pairing."
        }
    }
}
