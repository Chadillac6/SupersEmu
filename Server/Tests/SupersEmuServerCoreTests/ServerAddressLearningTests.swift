import Foundation
import SupersEmuKit
import XCTest

final class ServerAddressLearningTests: XCTestCase {
    func testMergePreservesAdvertisedOrderAndAppendsReachedURLOnlyWhenMissing() {
        let lan = URL(string: "https://192.168.1.20:8487")!
        let bonjour = URL(string: "https://mac-mini.local:8487")!
        let overlayIP = URL(string: "https://100.101.1.2:8487")!
        let overlayDNS = URL(string: "https://mac-mini.tail1234.ts.net:8487")!
        let advertised = [lan, bonjour, overlayIP, overlayDNS]

        XCTAssertEqual(ServerAddressLearning.merged(current: [lan], advertised: advertised, reachedAt: lan), [lan, bonjour])

        let reachedAt = URL(string: "https://typed-name.example:8487")!
        XCTAssertEqual(
            ServerAddressLearning.merged(current: [lan], advertised: advertised, reachedAt: reachedAt),
            [lan, bonjour, reachedAt])
    }

    func testMergeKeepsLoopbackReachedURL() {
        let lan = URL(string: "https://192.168.1.20:8487")!
        let overlay = URL(string: "https://100.101.1.2:8487")!
        let loopback = URL(string: "https://127.0.0.1:8487")!

        XCTAssertEqual(
            ServerAddressLearning.merged(current: [lan], advertised: [lan, overlay], reachedAt: loopback),
            [lan, loopback])
    }

    func testMergeFiltersInsecureMalformedAndLoopbackAddresses() {
        let lan = URL(string: "https://mac-mini.local:8487")!
        let ipv4MappedLoopback = URL(string: "https://[::ffff:127.0.0.1]:8487")!
        let ipv4MappedLAN = URL(string: "https://[::ffff:192.168.1.20]:8487")!
        let advertised = [
            lan,
            URL(string: "http://192.168.1.20:8487")!,
            URL(string: "https://127.0.0.1:8487")!,
            URL(string: "https://127.255.255.255:8487")!,
            URL(string: "https://[::1]:8487")!,
            ipv4MappedLoopback,
            ipv4MappedLAN,
            URL(string: "https://localhost:8487")!,
            URL(string: "https://localhost.:8487")!,
            URL(string: "https://user@mac-mini.local:8487")!,
            URL(string: "https://user:secret@mac-mini.local:8487")!,
            URL(string: "https://mac-mini.local:8487?token=secret")!,
            URL(string: "https://mac-mini.local:8487#fragment")!,
            URL(string: "https:relative")!,
            URL(string: "https://100.101.1.2:8487")!,
            URL(string: "https://mac-mini.tail1234.ts.net:8487")!,
            URL(string: "https://[fd7a:115c:a1e0::1]:8487")!,
        ]

        XCTAssertEqual(
            ServerAddressLearning.merged(current: [], advertised: advertised, reachedAt: lan),
            [lan, ipv4MappedLAN])
    }

    func testMergeReturnsNilForMissingOrFullyFilteredAdvertisement() {
        let reachedAt = URL(string: "https://mac-mini.local:8487")!
        XCTAssertNil(ServerAddressLearning.merged(current: [reachedAt], advertised: nil, reachedAt: reachedAt))
        XCTAssertNil(ServerAddressLearning.merged(
            current: [reachedAt],
            advertised: [URL(string: "http://mac-mini.local:8487")!, URL(string: "https://localhost:8487")!],
            reachedAt: reachedAt))
    }

    func testMergeReturnsNilWhenAddressesAreUnchanged() {
        let lan = URL(string: "https://192.168.1.20:8487")!
        let overlay = URL(string: "https://100.101.1.2:8487")!

        XCTAssertNil(ServerAddressLearning.merged(current: [lan], advertised: [lan, overlay], reachedAt: lan))
    }

    func testMergeDropsStaleCurrentAddresses() {
        let lan = URL(string: "https://192.168.1.20:8487")!
        let stale = URL(string: "https://192.168.1.21:8487")!
        let overlay = URL(string: "https://100.101.1.2:8487")!

        XCTAssertEqual(ServerAddressLearning.merged(current: [lan, stale], advertised: [lan, overlay], reachedAt: lan), [lan])
    }

    func testMergeDeduplicatesAdvertisedAddressesInOrder() {
        let lan = URL(string: "https://192.168.1.20:8487")!
        let overlay = URL(string: "https://100.101.1.2:8487")!

        XCTAssertEqual(
            ServerAddressLearning.merged(current: [], advertised: [lan, lan, overlay, overlay], reachedAt: overlay),
            [lan])
    }

    func testStoredLegacyOverlayAddressesArePrunedOnHeartbeat() {
        let lan = URL(string: "https://192.168.1.20:8487")!
        let storedIPv4 = URL(string: "https://100.101.1.2:8487")!
        let storedHostname = URL(string: "https://mac-mini.tail1234.ts.net:8487")!
        XCTAssertEqual(
            ServerAddressLearning.merged(
                current: [lan, storedIPv4, storedHostname],
                advertised: [lan, storedIPv4, storedHostname],
                reachedAt: lan),
            [lan])
    }

    func testWithoutLegacyOverlayAddressesFiltersIPv4IPv6AndHostname() {
        let urls = [
            URL(string: "https://192.168.1.20:8487")!,
            URL(string: "https://100.64.0.1:8487")!,
            URL(string: "https://100.127.255.255:8487")!,
            URL(string: "https://100.128.0.1:8487")!,
            URL(string: "https://mini.tail1234.ts.net:8487")!,
            URL(string: "https://[fd7a:115c:a1e0::1]:8487")!,
            URL(string: "https://[fd7a:115c:a1e1::1]:8487")!,
        ]
        XCTAssertEqual(
            ServerAddressLearning.withoutLegacyOverlayAddresses(urls),
            [urls[0], urls[3], urls[6]])
    }
}
