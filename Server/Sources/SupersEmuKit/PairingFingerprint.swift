import Foundation

public enum PairingFingerprint {
    public static func short(certificateSHA256: String) -> String? {
        let fingerprint = CertificatePin.normalize(certificateSHA256)
        guard fingerprint.count == 64 else { return nil }
        let prefix = String(fingerprint.prefix(8)).uppercased()
        return "\(prefix.prefix(4))-\(prefix.suffix(4))"
    }
}
