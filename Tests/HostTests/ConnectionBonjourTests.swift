import Network
import SupersEmuKit
import XCTest

final class ConnectionBonjourTests: XCTestCase {
    func testDiscoveredServerBuildsPinnedPairingPayload() throws {
        let endpoint = NWEndpoint.service(
            name: "supers-emu",
            type: SupersEmuBonjour.serviceType,
            domain: "local.",
            interface: nil
        )
        let server = DiscoveredServer(
            name: "supers-emu",
            txt: ["name": "Mac mini", "fp": String(repeating: "a", count: 64), "scheme": "https"],
            endpoint: endpoint
        )
        let address = try XCTUnwrap(URL(string: "https://192.168.1.20:8487"))

        let payload = server.pairingPayload(at: address, code: "123456")

        XCTAssertEqual(payload.serverName, "Mac mini")
        XCTAssertEqual(payload.urls, [address])
        XCTAssertEqual(payload.certificateSHA256, String(repeating: "a", count: 64))
        XCTAssertEqual(payload.code, "123456")
    }
}
