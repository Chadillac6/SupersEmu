import Foundation
import Synchronization

/// How devices should reach this server: put into every pairing QR. Set by `supersemu-server run`;
/// when unset (tests, router-only use) it falls back to the default port and the stored certificate.
public struct PairingEnvironment: Sendable, Equatable {
    public var urls: [URL]
    public var certificateSHA256: String?
    public var publicURL: URL?

    public init(urls: [URL], certificateSHA256: String?, publicURL: URL? = nil) {
        self.urls = urls
        self.certificateSHA256 = certificateSHA256
        self.publicURL = publicURL
    }

    private static let configured = Mutex<PairingEnvironment?>(nil)

    public static var current: PairingEnvironment? {
        get { configured.withLock { $0 } }
        set { configured.withLock { $0 = newValue } }
    }

    static func resolve(for store: ServerStore) -> PairingEnvironment {
        if let current { return current }
        let pin = TLSIdentity.storedFingerprint(paths: store.paths)
        return PairingEnvironment(urls: LocalNetwork.advertisedURLs(scheme: pin == nil ? "http" : "https", port: ServerDefaults.port),
                                  certificateSHA256: pin)
    }
}

public enum ServerDefaults {
    public static let port = 8487
}
