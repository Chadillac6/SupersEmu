import CryptoKit
import Foundation

/// Pins the server's self-signed certificate (SHA-256 of the leaf, from the pairing QR) for HTTPS.
/// Plain-HTTP servers and unpinned pairings fall back to the system's default handling.
final class PinnedTrustDelegate: NSObject, URLSessionDelegate, Sendable {
    let certificateSHA256: String?

    init(certificateSHA256: String?) {
        self.certificateSHA256 = certificateSHA256?.lowercased().replacingOccurrences(of: ":", with: "")
    }

    static func evaluate(_ challenge: URLAuthenticationChallenge, pin: String?) -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        guard let pin, !pin.isEmpty,
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
        let (disposition, credential) = Self.evaluate(challenge, pin: certificateSHA256)
        completionHandler(disposition, credential)
    }
}
