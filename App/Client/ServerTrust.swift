import CryptoKit
import Foundation

/// Pins the server's self-signed certificate (SHA-256 of the leaf, from the pairing QR) for HTTPS.
/// Plain-HTTP servers and unpinned pairings fall back to the system's default handling.
final class PinnedTrustDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    let certificateSHA256: String?
    /// Typed address + code has no fingerprint to pin. Then the first certificate seen during pairing is
    /// accepted and recorded (trust on first use) and pinned from then on.
    let trustOnFirstUse: Bool
    private let lock = NSLock()
    private var _observed: String?
    var observedSHA256: String? { lock.withLock { _observed } }

    /// TOFU only applies to the host the user typed; any other host gets default trust.
    let expectedHost: String?

    init(certificateSHA256: String?, trustOnFirstUse: Bool = false, expectedHost: String? = nil) {
        self.certificateSHA256 = Self.normalize(certificateSHA256)
        self.trustOnFirstUse = trustOnFirstUse && certificateSHA256 == nil && expectedHost != nil
        self.expectedHost = expectedHost?.lowercased()
    }

    /// The server never redirects; refusing keeps tokens, codes and pins bound to the paired host.
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }

    static func leafSHA256(_ trust: SecTrust) -> String? {
        guard let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate], let leaf = chain.first else { return nil }
        return SHA256.hash(data: SecCertificateCopyData(leaf) as Data).map { String(format: "%02x", $0) }.joined()
    }

    static func normalize(_ pin: String?) -> String? {
        pin?.lowercased().replacingOccurrences(of: ":", with: "").replacingOccurrences(of: " ", with: "")
    }

    static func evaluate(_ challenge: URLAuthenticationChallenge, pin: String?) -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        guard let pin = normalize(pin), !pin.isEmpty,
              challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = challenge.protectionSpace.serverTrust else { return (.performDefaultHandling, nil) }
        guard let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate], let leaf = chain.first else {
            return (.cancelAuthenticationChallenge, nil)
        }
        let digest = SHA256.hash(data: SecCertificateCopyData(leaf) as Data).map { String(format: "%02x", $0) }.joined()
        return digest == pin ? (.useCredential, URLCredential(trust: trust)) : (.cancelAuthenticationChallenge, nil)
    }

    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        if trustOnFirstUse, challenge.protectionSpace.host.lowercased() == expectedHost,
           challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
           let trust = challenge.protectionSpace.serverTrust, let digest = Self.leafSHA256(trust) {
            lock.withLock { _observed = digest }
            completionHandler(.useCredential, URLCredential(trust: trust))
            return
        }
        let (disposition, credential) = Self.evaluate(challenge, pin: certificateSHA256)
        completionHandler(disposition, credential)
    }
}
