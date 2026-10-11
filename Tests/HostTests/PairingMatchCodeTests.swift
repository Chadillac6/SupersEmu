import XCTest
import SupersEmuKit

final class PairingMatchCodeTests: XCTestCase {
    func testMatchCodeIsDeterministicAndFormatted() {
        let requestID = UUID(uuidString: "77d1fc45-1cad-4d98-a0c0-4c2243b402d3")!
        let code = PairingMatchCode.compute(
            certificateSHA256: String(repeating: "ab", count: 32),
            requestID: requestID,
            claimHash: String(repeating: "cd", count: 32)
        )

        XCTAssertEqual(code, PairingMatchCode.compute(
            certificateSHA256: String(repeating: "AB:", count: 31) + "AB",
            requestID: requestID,
            claimHash: String(repeating: "cd", count: 32)
        ))
        XCTAssertEqual(code, PairingMatchCode.compute(
            certificateSHA256: String(repeating: "ab", count: 32),
            requestID: requestID,
            claimHash: String(repeating: "cd", count: 32)
        ))
        XCTAssertEqual(code.count, 7)
        XCTAssertTrue(code.filter(\.isNumber).count == 6)
    }

    func testMatchCodeChangesWhenCertificateChanges() {
        let requestID = UUID(uuidString: "77d1fc45-1cad-4d98-a0c0-4c2243b402d3")!
        let claimHash = String(repeating: "cd", count: 32)
        let first = PairingMatchCode.compute(certificateSHA256: String(repeating: "ab", count: 32), requestID: requestID, claimHash: claimHash)
        let second = PairingMatchCode.compute(certificateSHA256: String(repeating: "ef", count: 32), requestID: requestID, claimHash: claimHash)
        XCTAssertNotEqual(first, second)
    }
}
