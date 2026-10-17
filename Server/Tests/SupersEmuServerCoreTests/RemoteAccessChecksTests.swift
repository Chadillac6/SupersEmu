import Foundation
import SupersEmuKit
import XCTest

final class RemoteAccessChecksTests: XCTestCase {
    func testParsesOnlyUniqueIPv4AAnswersFromDoHJSON() throws {
        let data = try JSONSerialization.data(withJSONObject: [
            "Status": 0,
            "Answer": [
                ["type": 1, "data": "203.0.113.12"],
                ["type": 28, "data": "2001:db8::1"],
                ["type": 1, "data": "203.0.113.12"],
                ["type": 1, "data": "not-an-ip"]
            ]
        ])
        XCTAssertEqual(RemoteAccessChecks.dohAAnswers(from: data), ["203.0.113.12"])
        XCTAssertEqual(RemoteAccessChecks.dohAAnswers(from: Data("{}".utf8)), [])
    }

    func testOutsideCheckClassification() {
        XCTAssertEqual(RemoteAccessChecks.classifyOutsideCheck(
            healthOK: true, dnsAddresses: [], publicIP: "203.0.113.12", certificatePresent: false), .reachable)
        XCTAssertEqual(RemoteAccessChecks.classifyOutsideCheck(
            healthOK: false, dnsAddresses: ["203.0.113.12"], publicIP: "203.0.113.12", certificatePresent: true),
                       .unverifiedFromInside)
        XCTAssertEqual(RemoteAccessChecks.classifyOutsideCheck(
            healthOK: false, dnsAddresses: ["198.51.100.3"], publicIP: "203.0.113.12", certificatePresent: true),
                       .failed("DNS points at 198.51.100.3, this Mac's public IP is 203.0.113.12"))
    }

    func testParsesOsascriptExitCodesIncludingCancellation() {
        XCTAssertEqual(RemoteAccessChecks.osascriptExitStatus(stderr: "execution error: User canceled. (-128)\n"), -128)
        XCTAssertEqual(RemoteAccessChecks.osascriptExitStatus(stderr: "execution error: shell script failed (5)"), 5)
        XCTAssertNil(RemoteAccessChecks.osascriptExitStatus(stderr: "not an AppleScript error"))
    }
}
