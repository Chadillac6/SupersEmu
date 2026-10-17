import XCTest
@testable import SupersEmuServerCore

final class RemoteAccessCertificateHostTests: XCTestCase {
    func testExactDNSNameMatchesCaseInsensitively() {
        XCTAssertTrue(CertificateHostMatcher.matches(host: "games.example.com", dnsNames: ["GAMES.EXAMPLE.COM"]))
    }

    func testSingleLabelWildcardMatches() {
        XCTAssertTrue(CertificateHostMatcher.matches(host: "games.example.com", dnsNames: ["*.example.com"]))
    }

    func testWildcardDoesNotMatchMultipleLabels() {
        XCTAssertFalse(CertificateHostMatcher.matches(host: "a.games.example.com", dnsNames: ["*.example.com"]))
    }

    func testMismatchedDNSNameDoesNotMatch() {
        XCTAssertFalse(CertificateHostMatcher.matches(host: "games.example.com", dnsNames: ["other.example.com"]))
    }
}
