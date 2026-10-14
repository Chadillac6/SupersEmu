import Foundation
import SupersEmuKit
import XCTest

final class ServerAddressLearningTests: XCTestCase {
    func testMergePreservesAdvertisedOrderAndAppendsReachedURLOnlyWhenMissing() {
        let lan = URL(string: "https://192.168.1.20:8487")!
        let bonjour = URL(string: "https://mac-mini.local:8487")!
        let tailscaleIP = URL(string: "https://100.101.1.2:8487")!
        let magicDNS = URL(string: "https://mac-mini.tail1234.ts.net:8487")!
        let advertised = [lan, bonjour, tailscaleIP, magicDNS]

        XCTAssertEqual(ServerAddressLearning.merged(current: [lan], advertised: advertised, reachedAt: lan), advertised)

        let reachedAt = URL(string: "https://typed-name.example:8487")!
        XCTAssertEqual(
            ServerAddressLearning.merged(current: [lan], advertised: advertised, reachedAt: reachedAt),
            advertised + [reachedAt])
    }

    func testMergeKeepsLoopbackReachedURL() {
        let lan = URL(string: "https://192.168.1.20:8487")!
        let tailscale = URL(string: "https://100.101.1.2:8487")!
        let loopback = URL(string: "https://127.0.0.1:8487")!

        XCTAssertEqual(
            ServerAddressLearning.merged(current: [lan], advertised: [lan, tailscale], reachedAt: loopback),
            [lan, tailscale, loopback])
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
        let tailscale = URL(string: "https://100.101.1.2:8487")!

        XCTAssertNil(ServerAddressLearning.merged(current: [lan, tailscale], advertised: [lan, tailscale], reachedAt: lan))
    }

    func testMergeDropsStaleCurrentAddresses() {
        let lan = URL(string: "https://192.168.1.20:8487")!
        let stale = URL(string: "https://192.168.1.21:8487")!
        let tailscale = URL(string: "https://100.101.1.2:8487")!

        XCTAssertEqual(ServerAddressLearning.merged(current: [lan, stale], advertised: [lan, tailscale], reachedAt: lan), [lan, tailscale])
    }

    func testMergeDeduplicatesAdvertisedAddressesInOrder() {
        let lan = URL(string: "https://192.168.1.20:8487")!
        let tailscale = URL(string: "https://100.101.1.2:8487")!

        XCTAssertEqual(
            ServerAddressLearning.merged(current: [], advertised: [lan, lan, tailscale, tailscale], reachedAt: tailscale),
            [lan, tailscale])
    }
}
