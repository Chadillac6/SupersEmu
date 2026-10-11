import Foundation

public enum PairingFingerprint {
    public static func short(certificateSHA256: String) -> String? {
        let fingerprint = CertificatePin.normalize(certificateSHA256)
        guard fingerprint.count == 64 else { return nil }
        let prefix = String(fingerprint.prefix(16)).uppercased()
        return [
            String(prefix.prefix(4)),
            String(prefix.dropFirst(4).prefix(4)),
            String(prefix.dropFirst(8).prefix(4)),
            String(prefix.suffix(4)),
        ].joined(separator: "-")
    }
}
