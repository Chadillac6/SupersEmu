import CryptoKit
import Foundation

public enum PairingMatchCode {
    public static func compute(certificateSHA256: String, requestID: UUID, claimHash: String) -> String {
        let certificate = CertificatePin.normalize(certificateSHA256)
        let claim = claimHash.lowercased()
        let input = "\(certificate):\(requestID.uuidString.lowercased()):\(claim)"
        let digest = SHA256.hash(data: Data(input.utf8))
        var decimalDigits = [0]
        for byte in digest {
            var carry = Int(byte)
            for index in decimalDigits.indices {
                let value = decimalDigits[index] * 256 + carry
                decimalDigits[index] = value % 10
                carry = value / 10
            }
            while carry > 0 {
                decimalDigits.append(carry % 10)
                carry /= 10
            }
        }
        let decimal = decimalDigits.reversed().map(String.init).joined()
        let code = String(decimal.prefix(6))
        return "\(code.prefix(3)) \(code.suffix(3))"
    }
}
