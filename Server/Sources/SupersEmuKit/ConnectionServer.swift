import Foundation

/// What a device remembers about a paired server. The device token itself lives in a `DeviceTokenStore`.
public struct ServerProfile: Codable, Sendable, Equatable {
    public var serverName: String
    /// LAN first, then Tailscale, as given by the pairing QR (plus any Bonjour discoveries).
    public var urls: [URL]
    public var certificateSHA256: String?
    /// The URL that answered last time; tried first.
    public var lastGoodURL: URL?
    public var userID: String?
    public var deviceID: String?

    public init(serverName: String, urls: [URL], certificateSHA256: String?, lastGoodURL: URL? = nil, userID: String? = nil, deviceID: String? = nil) {
        self.serverName = serverName; self.urls = urls; self.certificateSHA256 = certificateSHA256
        self.lastGoodURL = lastGoodURL; self.userID = userID; self.deviceID = deviceID
    }

    public init(payload: PairingPayload) {
        self.init(serverName: payload.serverName, urls: payload.urls, certificateSHA256: payload.certificateSHA256)
    }

    /// Keychain account for this server's device token.
    public var tokenAccount: String { certificateSHA256.map(CertificatePin.normalize) ?? serverName }
}

public enum ServerConnectionError: Error, Equatable, CustomStringConvertible {
    case noURLs
    case unreachable([String])
    case notPaired

    public var description: String {
        switch self {
        case .noURLs: return "The server has no addresses"
        case .unreachable(let errors): return "Couldn't reach the server (\(errors.joined(separator: "; ")))"
        case .notPaired: return "This device isn't paired with the server"
        }
    }
}

/// Reaches a paired server over whichever of its URLs works (LAN, then Tailscale), pinning its certificate.
public actor ServerConnection {
    public private(set) var profile: ServerProfile
    public let tokenStore: any DeviceTokenStore
    public nonisolated let session: URLSession
    private let onProfileChange: (@Sendable (ServerProfile) -> Void)?

    public init(profile: ServerProfile, tokenStore: any DeviceTokenStore = KeychainTokenStore(), session: URLSession? = nil,
                onProfileChange: (@Sendable (ServerProfile) -> Void)? = nil) {
        self.profile = profile
        self.tokenStore = tokenStore
        self.session = session ?? PinnedCertificateDelegate.session(certificateSHA256: profile.certificateSHA256, timeout: 8)
        self.onProfileChange = onProfileChange
    }

    /// The last good URL first, then the rest in their given order.
    public static func candidateOrder(urls: [URL], lastGood: URL?) -> [URL] {
        var ordered: [URL] = []
        for url in [lastGood].compactMap({ $0 }) + urls where !ordered.contains(url) { ordered.append(url) }
        return ordered
    }

    public var candidates: [URL] { Self.candidateOrder(urls: profile.urls, lastGood: profile.lastGoodURL) }

    /// Tries each candidate in order with `probe` and remembers the first that succeeds.
    @discardableResult
    public func resolveURL(probe: (@Sendable (URL) async throws -> Void)? = nil) async throws -> URL {
        let candidates = candidates
        guard !candidates.isEmpty else { throw ServerConnectionError.noURLs }
        let session = session
        let probe = probe ?? { url in _ = try await APIClient(baseURL: url, token: nil, session: session).health() }
        var errors: [String] = []
        for url in candidates {
            do {
                try await probe(url)
                if profile.lastGoodURL != url {
                    profile.lastGoodURL = url
                    onProfileChange?(profile)
                }
                return url
            } catch {
                errors.append("\(url.absoluteString): \(error)")
            }
        }
        throw ServerConnectionError.unreachable(errors)
    }

    /// An authenticated client on the first reachable URL.
    public func client() async throws -> APIClient {
        guard let token = try tokenStore.token(for: profile.tokenAccount) else { throw ServerConnectionError.notPaired }
        return APIClient(baseURL: try await resolveURL(), token: token, session: session)
    }

    /// Redeems the pairing code, stores the device token and records who we are.
    public func pair(code: String, deviceName: String, platform: String) async throws -> PairResponse {
        let url = try await resolveURL()
        let response = try await APIClient(baseURL: url, token: nil, session: session)
            .pair(PairRequest(code: code, deviceName: deviceName, platform: platform))
        try tokenStore.setToken(response.token, for: profile.tokenAccount)
        profile.serverName = response.serverName
        profile.userID = response.user.id
        profile.deviceID = response.deviceID
        onProfileChange?(profile)
        return response
    }

    /// Adds an address found on the LAN (Bonjour) ahead of the Tailscale ones.
    public func addDiscoveredURL(_ url: URL) {
        guard !profile.urls.contains(url) else { return }
        profile.urls.insert(url, at: 0)
        onProfileChange?(profile)
    }

    public func forget() throws {
        try tokenStore.removeToken(for: profile.tokenAccount)
    }

    /// Pairs from the QR payload in one step.
    public static func pair(payload: PairingPayload, deviceName: String, platform: String,
                            tokenStore: any DeviceTokenStore = KeychainTokenStore(),
                            onProfileChange: (@Sendable (ServerProfile) -> Void)? = nil) async throws -> (ServerConnection, PairResponse) {
        let connection = ServerConnection(profile: ServerProfile(payload: payload), tokenStore: tokenStore, onProfileChange: onProfileChange)
        let response = try await connection.pair(code: payload.code, deviceName: deviceName, platform: platform)
        return (connection, response)
    }
}
