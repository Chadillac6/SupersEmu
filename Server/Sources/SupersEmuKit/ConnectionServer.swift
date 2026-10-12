import Foundation

/// What a device remembers about a paired server. The device token itself lives in a `DeviceTokenStore`.
public struct ServerProfile: Codable, Sendable, Equatable {
    public var serverName: String
    /// LAN first, then Tailscale, as given by the pairing QR (plus any Bonjour discoveries).
    public var urls: [URL]
    public var certificateSHA256: String?
    public var publicURL: URL?
    /// The URL that answered last time; tried first.
    public var lastGoodURL: URL?
    public var userID: String?
    public var deviceID: String?
    /// Keychain account for this server's device token. Fixed at pairing so a server rename doesn't lose it.
    public var tokenAccount: String
    /// Allows sending the device token without a pinned HTTPS certificate (`--insecure-http` test servers only).
    public var allowsInsecureTransport: Bool

    public init(serverName: String, urls: [URL], certificateSHA256: String?, lastGoodURL: URL? = nil, userID: String? = nil, deviceID: String? = nil,
                tokenAccount: String? = nil, allowsInsecureTransport: Bool = false, publicURL: URL? = nil) {
        self.serverName = serverName; self.urls = urls; self.certificateSHA256 = certificateSHA256
        self.publicURL = publicURL
        self.lastGoodURL = lastGoodURL; self.userID = userID; self.deviceID = deviceID
        self.tokenAccount = tokenAccount ?? certificateSHA256.map(CertificatePin.normalize) ?? "unpinned:\(serverName)"
        self.allowsInsecureTransport = allowsInsecureTransport
    }

    public init(payload: PairingPayload, allowsInsecureTransport: Bool = false) {
        self.init(serverName: payload.serverName, urls: payload.urls, certificateSHA256: payload.certificateSHA256,
                  allowsInsecureTransport: allowsInsecureTransport, publicURL: payload.publicURL)
    }

    /// Whether a device token may be sent to `url`: only over HTTPS with a pinned certificate, unless opted out.
    public func isTrustedTransport(_ url: URL) -> Bool {
        let endpoint = WebPKIEndpoint.key(for: url)
        let isPublicEndpoint = endpoint != nil && endpoint == publicURL.flatMap { WebPKIEndpoint.key(for: $0) }
        return allowsInsecureTransport || (url.scheme?.lowercased() == "https" &&
            (certificateSHA256 != nil || isPublicEndpoint))
    }
}

extension ServerProfile {
    var webPKIEndpoints: Set<String> { WebPKIEndpoint.keys(for: publicURL) }

    /// Tolerates profiles saved before `tokenAccount` / `allowsInsecureTransport` existed.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let serverName = try c.decode(String.self, forKey: .serverName)
        let pin = try c.decodeIfPresent(String.self, forKey: .certificateSHA256)
        self.init(serverName: serverName, urls: try c.decode([URL].self, forKey: .urls), certificateSHA256: pin,
                  lastGoodURL: try c.decodeIfPresent(URL.self, forKey: .lastGoodURL),
                  userID: try c.decodeIfPresent(String.self, forKey: .userID),
                  deviceID: try c.decodeIfPresent(String.self, forKey: .deviceID),
                  tokenAccount: try c.decodeIfPresent(String.self, forKey: .tokenAccount) ?? pin.map(CertificatePin.normalize) ?? "unpinned:\(serverName)",
                  allowsInsecureTransport: try c.decodeIfPresent(Bool.self, forKey: .allowsInsecureTransport) ?? false,
                  publicURL: try c.decodeIfPresent(URL.self, forKey: .publicURL))
    }
}

public enum ServerConnectionError: Error, Equatable, CustomStringConvertible {
    case noURLs
    case unreachable([String])
    case notPaired
    case insecureTransport

    public var description: String {
        switch self {
        case .noURLs: return "The server has no addresses"
        case .unreachable(let errors): return "Couldn't reach the server (\(errors.joined(separator: "; ")))"
        case .notPaired: return "This device isn't paired with the server"
        case .insecureTransport: return "Refusing to send credentials without a pinned HTTPS certificate"
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
        self.session = session ?? PinnedCertificateDelegate.session(certificateSHA256: profile.certificateSHA256, timeout: 8,
                                                                    webPKIEndpoints: profile.webPKIEndpoints)
        self.onProfileChange = onProfileChange
    }

    /// The last good URL first, then the rest in their given order.
    public static func candidateOrder(urls: [URL], lastGood: URL?, publicURL: URL? = nil) -> [URL] {
        var ordered: [URL] = []
        for url in [lastGood].compactMap({ $0 }) + urls + [publicURL].compactMap({ $0 }) where !ordered.contains(url) {
            ordered.append(url)
        }
        return ordered
    }

    public var candidates: [URL] {
        Self.candidateOrder(urls: profile.urls, lastGood: profile.lastGoodURL, publicURL: profile.publicURL)
    }

    /// Tries each candidate in order with `probe` and remembers the first that succeeds.
    @discardableResult
    /// With `trustedOnly`, skips URLs that `isTrustedTransport` rejects (anything that will carry the token).
    public func resolveURL(trustedOnly: Bool = false, probe: (@Sendable (URL) async throws -> Void)? = nil) async throws -> URL {
        guard !candidates.isEmpty else { throw ServerConnectionError.noURLs }
        let candidates = trustedOnly ? candidates.filter(profile.isTrustedTransport) : candidates
        guard !candidates.isEmpty else { throw ServerConnectionError.insecureTransport }
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
        let url = try await resolveURL(trustedOnly: true)
        return APIClient(baseURL: url, token: token, session: session)
    }

    /// Redeems the pairing code, stores the device token and records who we are.
    public func pair(code: String, deviceName: String, platform: String) async throws -> PairResponse {
        let url = try await resolveURL(trustedOnly: true)
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
