import SupersEmuKit
import XCTest

final class PairingFingerprintTests: XCTestCase {
    func testShortFingerprintUsesGroupedUppercaseHex() {
        XCTAssertEqual(
            PairingFingerprint.short(certificateSHA256: "abcdef0123456789" + String(repeating: "0", count: 48)),
            "ABCD-EF01-2345-6789"
        )
    }
}
