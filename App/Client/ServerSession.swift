import Foundation
import Network
import Observation
import SupersEmuKit
#if os(iOS)
import UIKit
#endif

private struct RefreshCandidateSuccess: @unchecked Sendable {
    let library: LibraryResponse
    let session: URLSession
    let trust: PinnedCertificateDelegate
}

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
    /// Home network / public internet / unreachable / signed out / certificate mismatch. Retries with backoff.
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
    /// Dropped (never invalidated directly) on reconnect: clients already handed to save sync, downloads, etc. keep it
    /// alive until they finish, and the lease invalidates it after that.
    @ObservationIgnored private var urlSession: URLSessionLease?
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
        var saved = store.load()
        if var loaded = saved {
            let filteredURLs = ServerAddressLearning.withoutLegacyOverlayAddresses(loaded.urls)
            if filteredURLs != loaded.urls {
                loaded.urls = filteredURLs
                Self.persist(loaded, to: store)
                saved = loaded
            }
        }
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

    /// Client for the server URL that answered last.
    func client() -> APIClient? {
        guard let credential, let url = activeURL ?? credential.urls.first ?? credential.publicURL else { return nil }
        return APIClient(baseURL: url, token: credential.token, lease: session(pin: credential.certificateSHA256))
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
        let urls = payload.urls.filter { $0.scheme == "https" || ($0.scheme == "http" && LoopbackHost.matches($0)) }
        let candidates = urls + [payload.publicURL].compactMap { $0 }.filter { !urls.contains($0) }
        guard !candidates.isEmpty else { throw PairingError.insecureAddress }
        let pin = payload.certificateSHA256 ?? confirmedCertificateSHA256
        guard !candidates.contains(where: { $0.scheme?.lowercased() == "https" }) || pin != nil else {
            throw PairingError.fingerprintConfirmationRequired
        }
        var lastError: Error = APIClientError.invalidResponse
        let webPKIEndpoints = WebPKIEndpoint.keys(for: payload.publicURL)
        for url in candidates {
            let trust = PinnedCertificateDelegate(certificateSHA256: pin, webPKIEndpoints: webPKIEndpoints)
            let pairingSession = URLSession(configuration: Self.configuration, delegate: trust, delegateQueue: nil)
            defer { pairingSession.finishTasksAndInvalidate() }
            let client = APIClient(baseURL: url, token: nil, session: pairingSession)
            do {
                let response = try await client.pair(request)
                let credential = ServerCredential(
                    serverName: response.serverName, urls: urls, publicURL: payload.publicURL, certificateSHA256: pin,
                    token: response.token, deviceID: response.deviceID, user: response.user)
                try await commitPairing(credential, at: url)
                return
            } catch let error as APIClientError {
                throw error
            } catch {
                lastError = error
            }
        }
        throw lastError
    }

    func pair(
        response: PairResponse,
        at url: URL,
        certificateSHA256: String,
        publicURL: URL? = nil,
        shouldCommit: () -> Bool
    ) async throws {
        guard shouldCommit() else {
            let client = APIClient(
                baseURL: url,
                token: response.token,
                session: PinnedCertificateDelegate.session(certificateSHA256: certificateSHA256,
                                                            webPKIEndpoints: WebPKIEndpoint.keys(for: publicURL))
            )
            let revocationFailure: String?
            do {
                _ = try await client.revokeCurrentDevice()
                revocationFailure = nil
            } catch {
                if let clientError = error as? APIClientError, case .http(let status, _) = clientError {
                    revocationFailure = "HTTP \(status)"
                } else {
                    let nsError = error as NSError
                    revocationFailure = "\(nsError.domain) \(nsError.code)"
                }
            }
            throw PairingError.approvedResponseFlowLost(
                deviceID: response.deviceID, revocationFailure: revocationFailure)
        }
        let credential = ServerCredential(serverName: response.serverName, urls: publicURL == nil ? [url] : [],
                                          publicURL: publicURL, certificateSHA256: certificateSHA256, token: response.token,
                                          deviceID: response.deviceID, user: response.user)
        try await commitPairing(credential, at: url)
    }

    /// Saves a newly paired credential and switches this session to it, dropping the previous connection's state.
    private func commitPairing(_ credential: ServerCredential, at url: URL) async throws {
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
        let primary = activeURL
        let others = credential.urls.filter { $0 != primary } +
            [credential.publicURL].compactMap { $0 }.filter { $0 != primary && !credential.urls.contains($0) }
        let token = credential.token
        let pin = credential.certificateSHA256
        let webPKIEndpoints = WebPKIEndpoint.keys(for: credential.publicURL)
        let result = await CandidateRacer.race(primary: primary, others: others) { url in
            let delegate = PinnedCertificateDelegate(certificateSHA256: pin, webPKIEndpoints: webPKIEndpoints)
            let candidateSession = URLSession(configuration: Self.configuration, delegate: delegate, delegateQueue: nil)
            let client = APIClient(baseURL: url, token: token, session: candidateSession)
            do {
                let library = try await client.library()
                return .success(RefreshCandidateSuccess(library: library, session: candidateSession, trust: delegate))
            } catch {
                candidateSession.invalidateAndCancel()
                return .failure(ConnectionFailure.classify(error, certificateRejected: delegate.rejectionCount > 0))
            }
        }

        guard generation == self.generation else {
            if case .success(_, let winner) = result { winner.session.invalidateAndCancel() }
            return
        }
        switch result {
        case .success(let url, let winner):
            urlSession = URLSessionLease(winner.session)
            trust = winner.trust
            activeURL = url
            apply(winner.library.games)
            lastRefreshed = Date()
            if connection == .unreachable || connection == .certificateMismatch { recoveredAt = Date() }
            monitor.succeeded(via: url, publicURL: credential.publicURL)
            publish()
            startHeartbeat()
            retryTask?.cancel()
            retryTask = nil
        case .failure(let failure):
            if failure == .signedOut {
                monitor.failed(.signedOut)
                publish()
                return
            }
            monitor.failed(failure)
            publish()
            scheduleRetry()
        }
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
        let client = APIClient(baseURL: url, token: credential.token, lease: session(pin: credential.certificateSHA256))
        let generation = self.generation
        do {
            let health = try await client.health()
            guard generation == self.generation else { return }
            learnPublicURL(health.publicURL, credential: credential, reachedAt: url)
            learnServerURLs(health.urls, reachedAt: url)
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

    /// Joining Wi-Fi, leaving home, or a network-interface change retries right away.
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
        urlSession = nil
        trust = nil
        // Always try again, even with no network (a loopback server still works): a failure schedules the backoff.
        Task {
            await refreshTask?.value
            await refresh()
        }
    }

    func signOut() {
        // Queued saves belong to this account; never let the next pairing upload them.
        Task { await SaveSync.shared.engine.reset() }
        Task { await CheatLibrary.shared.engine.resetSync() }
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
        let webPKIEndpoints = WebPKIEndpoint.keys(for: credential?.publicURL)
        return GameDownloader(client: client, cache: cache,
                              trust: { PinnedCertificateDelegate.disposition(for: $0, pin: pin, webPKIEndpoints: webPKIEndpoints) })
    }

    private func apply(_ games: [GameSummary]) {
        let now = Date()
        for game in games where firstSeen[game.id] == nil { firstSeen[game.id] = game.addedAt ?? now }
        firstSeen = firstSeen.filter { id, _ in games.contains { $0.id == id } }
        self.games = games
        saveSnapshot()
    }

    nonisolated private static var configuration: URLSessionConfiguration {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 8
        configuration.waitsForConnectivity = false
        return configuration
    }

    private func session(pin: String?) -> URLSessionLease {
        if let urlSession { return urlSession }
        let webPKIEndpoints = WebPKIEndpoint.keys(for: credential?.publicURL)
        let delegate = PinnedCertificateDelegate(certificateSHA256: pin, webPKIEndpoints: webPKIEndpoints)
        let session = URLSessionLease(URLSession(configuration: Self.configuration, delegate: delegate, delegateQueue: nil))
        if credential != nil {
            urlSession = session
            trust = delegate
        }
        return session
    }

    private func learnPublicURL(_ publicURL: URL?, credential: ServerCredential, reachedAt url: URL) {
        let currentPublicHost = credential.publicURL?.host?.lowercased()
        guard url.scheme?.lowercased() == "https",
              credential.certificateSHA256 != nil, let publicURL,
              publicURL.scheme?.lowercased() == "https", publicURL.host != nil,
              publicURL.user == nil, publicURL.password == nil,
              publicURL.query == nil, publicURL.fragment == nil,
              publicURL != credential.publicURL,
              url.host?.lowercased() != currentPublicHost else { return }
        var updated = credential
        updated.publicURL = publicURL
        Self.persist(updated, to: store)
        self.credential = updated
        urlSession = nil
        trust = nil
    }

    private func learnServerURLs(_ advertised: [URL]?, reachedAt url: URL) {
        guard var credential = self.credential,
              credential.certificateSHA256 != nil,
              url.scheme?.lowercased() == "https",
              url != credential.publicURL,
              let urls = ServerAddressLearning.merged(current: credential.urls, advertised: advertised, reachedAt: url) else { return }
        credential.urls = urls
        Self.persist(credential, to: store)
        self.credential = credential
    }

    /// Best-effort save of a learned address change: the session keeps using it either way, but a failed write is
    /// logged because the old addresses come back on the next launch.
    private static func persist(_ credential: ServerCredential, to store: CredentialStore) {
        do {
            try store.save(credential)
        } catch {
            AppLog.connection.error("Couldn't save the server credential: \(error.localizedDescription, privacy: .public)")
        }
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
    case approvedResponseFlowLost(deviceID: String, revocationFailure: String?)

    var errorDescription: String? {
        switch self {
        case .insecureAddress: return "Use an https:// server address to pair."
        case .fingerprintUnavailable: return "Couldn't read the server's TLS certificate fingerprint."
        case .fingerprintConfirmationRequired: return "Confirm the server's TLS fingerprint before pairing."
        case .approvedResponseFlowLost(let deviceID, let revocationFailure):
            if let revocationFailure {
                return "The approved pairing response arrived after this flow ended. Device \(deviceID) wasn't saved and couldn't be revoked automatically (\(revocationFailure)); revoke it in Server Mode."
            }
            return "The approved pairing response arrived after this flow ended. Device \(deviceID) wasn't saved and was revoked."
        }
    }
}
