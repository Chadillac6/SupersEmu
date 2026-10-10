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
/// With no pin it falls back to the system's default TLS handling.
public final class PinnedCertificateDelegate: NSObject, URLSessionDelegate, Sendable {
    public let certificateSHA256: String?

    public init(certificateSHA256: String?) {
        self.certificateSHA256 = certificateSHA256
    }

    public enum Decision: Equatable {
        case useTrust
        case reject
        case defaultHandling
    }

    public func decision(authenticationMethod: String, trust: SecTrust?) -> Decision {
        guard authenticationMethod == NSURLAuthenticationMethodServerTrust else { return .defaultHandling }
        guard let pin = certificateSHA256 else { return .defaultHandling }
        guard let trust, CertificatePin.evaluate(trust, expected: pin) else { return .reject }
        return .useTrust
    }

    public func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
                           completionHandler: @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        let trust = challenge.protectionSpace.serverTrust
        switch decision(authenticationMethod: challenge.protectionSpace.authenticationMethod, trust: trust) {
        case .useTrust: completionHandler(.useCredential, URLCredential(trust: trust!))
        case .reject: completionHandler(.cancelAuthenticationChallenge, nil)
        case .defaultHandling: completionHandler(.performDefaultHandling, nil)
        }
    }

    /// An ephemeral session pinned to `certificateSHA256`.
    public static func session(certificateSHA256: String?, timeout: TimeInterval = 15) -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeout
        configuration.waitsForConnectivity = false
        return URLSession(configuration: configuration, delegate: PinnedCertificateDelegate(certificateSHA256: certificateSHA256), delegateQueue: nil)
    }
}
