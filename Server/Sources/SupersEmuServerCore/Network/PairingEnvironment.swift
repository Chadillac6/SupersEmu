import Foundation
import Synchronization

public struct URLDetection: Sendable, Equatable {
    public var scheme: String
    public var port: Int
    public var tailscaleHost: String?

    public init(scheme: String, port: Int, tailscaleHost: String?) {
        self.scheme = scheme
        self.port = port
        self.tailscaleHost = tailscaleHost
    }
}

/// How devices should reach this server: put into every pairing QR. Set by `supersemu-server run`;
/// when unset (tests, router-only use) it falls back to the default port and the stored certificate.
public struct PairingEnvironment: Sendable, Equatable {
    public var urls: [URL]
    public var certificateSHA256: String?
    public var publicURL: URL?
    public var detection: URLDetection?

    public init(urls: [URL], certificateSHA256: String?, publicURL: URL? = nil, detection: URLDetection? = nil) {
        self.urls = urls
        self.certificateSHA256 = certificateSHA256
        self.publicURL = publicURL
        self.detection = detection
    }

    public var currentURLs: [URL] {
        guard let detection else { return urls }
        return LocalNetwork.advertisedURLs(
            scheme: detection.scheme,
            port: detection.port,
            tailscaleHost: detection.tailscaleHost)
    }

    private static let configured = Mutex<PairingEnvironment?>(nil)

    public static var current: PairingEnvironment? {
        get { configured.withLock { $0 } }
        set { configured.withLock { $0 = newValue } }
    }

    static func resolve(for store: ServerStore) -> PairingEnvironment {
        if let current { return current }
        let pin = TLSIdentity.storedFingerprint(paths: store.paths)
        let scheme = pin == nil ? "http" : "https"
        return PairingEnvironment(
            urls: LocalNetwork.advertisedURLs(scheme: scheme, port: ServerDefaults.port),
            certificateSHA256: pin,
            detection: URLDetection(scheme: scheme, port: ServerDefaults.port, tailscaleHost: nil))
    }
}

public enum ServerDefaults {
    public static let port = 8487
}
