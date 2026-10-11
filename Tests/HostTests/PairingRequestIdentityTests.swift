import XCTest
import SupersEmuKit

final class PairingRequestIdentityTests: XCTestCase {
    func testIdentityRequiresSameGenerationAndSource() {
        let identity = PairingRequestIdentity(generation: 3, source: "daemon")

        XCTAssertTrue(identity.matches(generation: 3, source: "daemon"))
        XCTAssertFalse(identity.matches(generation: 4, source: "daemon"))
        XCTAssertFalse(identity.matches(generation: 3, source: "session"))
    }
}
