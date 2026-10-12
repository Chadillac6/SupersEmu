import CryptoKit
import Foundation
import Security

/// SHA-256 certificate pinning for the server's self-signed TLS certificate.
public enum CertificatePin {
    /// Lowercase hex SHA-256 of a DER certificate.
    public static func sha256(ofDER der: Data) -> String {
        SHA256.hash(data: der).map { String(format: "%02x", $0) }.joined()
    }

    /// Accepts `AB:CD…`, `abcd…` and whitespace variants.
    public static func normalize(_ fingerprint: String) -> String {
        fingerprint.lowercased().filter { $0.isHexDigit }
    }

    public static func matches(certificateDER der: Data, expected: String) -> Bool {
        let expected = normalize(expected)
        guard expected.count == 64 else { return false }
        return sha256(ofDER: der) == expected
    }

    /// The leaf certificate of `trust` must match the pin. Hostname and CA chain are deliberately not
    /// checked: the pin from the pairing QR is the trust anchor for LAN and Tailscale URLs alike.
    public static func evaluate(_ trust: SecTrust, expected: String) -> Bool {
        guard let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate], let leaf = chain.first else { return false }
        return matches(certificateDER: SecCertificateCopyData(leaf) as Data, expected: expected)
    }
}

/// URLSession delegate that only trusts a server whose certificate matches `certificateSHA256`.
/// With no pin it falls back to the system's default TLS handling. Never follows redirects, so tokens,
/// codes and pins stay bound to the host they were meant for.
public final class PinnedCertificateDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    public let certificateSHA256: String?
    public let webPKIHosts: Set<String>
    /// Typed address + code has no fingerprint to pin: the first certificate seen from `expectedHost`
    /// is accepted and recorded in `observedSHA256` (trust on first use), then pinned from then on.
    public let trustOnFirstUse: Bool
    public let expectedHost: String?
    private let lock = NSLock()
    private var observed: String?
    private var rejections = 0
    public var observedSHA256: String? { lock.withLock { observed } }
    /// Certificates refused so far; a change across a request means it failed on the pin, not the network.
    public var rejectionCount: Int { lock.withLock { rejections } }

    public init(certificateSHA256: String?, trustOnFirstUse: Bool = false, expectedHost: String? = nil,
                webPKIHosts: Set<String> = []) {
        self.certificateSHA256 = certificateSHA256
        self.webPKIHosts = Set(webPKIHosts.map { $0.lowercased() })
        self.trustOnFirstUse = trustOnFirstUse && certificateSHA256 == nil && expectedHost != nil
        self.expectedHost = expectedHost?.lowercased()
    }

    public enum Decision: Equatable {
        case useTrust
        case reject
        case defaultHandling
    }

    public func decision(authenticationMethod: String, trust: SecTrust?) -> Decision {
        Self.decision(authenticationMethod: authenticationMethod, trust: trust, pin: certificateSHA256,
                      host: nil, webPKIHosts: webPKIHosts)
    }

    public static func decision(authenticationMethod: String, trust: SecTrust?, pin: String?) -> Decision {
        decision(authenticationMethod: authenticationMethod, trust: trust, pin: pin, host: nil, webPKIHosts: [])
    }

    public static func decision(authenticationMethod: String, trust: SecTrust?, pin: String?,
                                host: String?, webPKIHosts: Set<String>) -> Decision {
        guard authenticationMethod == NSURLAuthenticationMethodServerTrust else { return .defaultHandling }
        if let host, webPKIHosts.contains(host.lowercased()) { return .defaultHandling }
        guard let pin else { return .defaultHandling }
        guard let trust, CertificatePin.evaluate(trust, expected: pin) else { return .reject }
        return .useTrust
    }

    /// Pin check for other delegates (e.g. `GameDownloader`'s trust handler).
    public static func disposition(for challenge: URLAuthenticationChallenge, pin: String?) -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        disposition(for: challenge, pin: pin, webPKIHosts: [])
    }

    public static func disposition(for challenge: URLAuthenticationChallenge, pin: String?,
                                   webPKIHosts: Set<String>) -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        let trust = challenge.protectionSpace.serverTrust
        switch decision(authenticationMethod: challenge.protectionSpace.authenticationMethod, trust: trust, pin: pin,
                        host: challenge.protectionSpace.host, webPKIHosts: webPKIHosts) {
        case .useTrust: return (.useCredential, URLCredential(trust: trust!))
        case .reject: return (.cancelAuthenticationChallenge, nil)
        case .defaultHandling: return (.performDefaultHandling, nil)
        }
    }

    public func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
                           completionHandler: @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        let space = challenge.protectionSpace
        if trustOnFirstUse, space.host.lowercased() == expectedHost,
           space.authenticationMethod == NSURLAuthenticationMethodServerTrust, let trust = space.serverTrust,
           let leaf = (SecTrustCopyCertificateChain(trust) as? [SecCertificate])?.first {
            let digest = CertificatePin.sha256(ofDER: SecCertificateCopyData(leaf) as Data)
            if acceptFirstUse(digest) {
                completionHandler(.useCredential, URLCredential(trust: trust))
            } else {
                completionHandler(.cancelAuthenticationChallenge, nil)
            }
            return
        }
        let (disposition, credential) = Self.disposition(for: challenge, pin: certificateSHA256, webPKIHosts: webPKIHosts)
        if disposition == .cancelAuthenticationChallenge { lock.withLock { rejections += 1 } }
        completionHandler(disposition, credential)
    }

    /// The first certificate is recorded; later connections in the same pairing must present the same one.
    public func acceptFirstUse(_ digest: String) -> Bool {
        lock.withLock {
            if let observed { return observed == digest }
            observed = digest
            return true
        }
    }

    public func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                           newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }

    /// An ephemeral session pinned to `certificateSHA256`.
    public static func session(certificateSHA256: String?, timeout: TimeInterval = 15,
                               webPKIHosts: Set<String> = []) -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeout
        configuration.waitsForConnectivity = false
        return URLSession(configuration: configuration,
                          delegate: PinnedCertificateDelegate(certificateSHA256: certificateSHA256, webPKIHosts: webPKIHosts),
                          delegateQueue: nil)
    }
}
