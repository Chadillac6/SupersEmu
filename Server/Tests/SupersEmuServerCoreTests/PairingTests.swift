import Foundation
import GRDB
import Hummingbird
import HummingbirdTesting
import SupersEmuKit
@testable import SupersEmuServerCore
import XCTest

final class PairingTests: XCTestCase {
    var store: ServerStore!
    var admin: UserInfo!
    var adminToken: String!

    override func setUp() async throws {
        store = try ServerStore.inMemory()
        admin = try store.createUser(displayName: "Chad", role: .admin)
        adminToken = try store.createDeviceToken(userID: admin.id, deviceName: "Chad's Mac").token
        PairingEnvironment.current = PairingEnvironment(
            urls: [URL(string: "https://mac-mini.local:8487")!, URL(string: "https://mac-mini.tail1234.ts.net:8487")!],
            certificateSHA256: String(repeating: "ab", count: 32))
    }

    override func tearDown() async throws {
        PairingEnvironment.current = nil
    }

    func app() -> some ApplicationProtocol { buildApplication(store: store, configuration: .init()) }

    func json<T: Encodable>(_ value: T) throws -> ByteBuffer { ByteBuffer(data: try SupersEmuJSON.encoder().encode(value)) }

    func decode<T: Decodable>(_ type: T.Type, _ response: TestResponse) throws -> T {
        try SupersEmuJSON.decoder().decode(T.self, from: Data(buffer: response.body))
    }

    func bearer(_ token: String) -> HTTPFields { [.authorization: "Bearer \(token)", .contentType: "application/json"] }

    // MARK: Routes

    func testPairingFlowIssuesWorkingDeviceTokenOnce() async throws {
        try await app().test(.router) { client in
            let code = try await client.execute(uri: "/v1/admin/pairing-codes", method: .post, headers: self.bearer(self.adminToken),
                                                body: try self.json(CreatePairingCodeRequest())) { response -> PairingCode in
                XCTAssertEqual(response.status, .created)
                return try self.decode(PairingCode.self, response)
            }
            XCTAssertEqual(code.code.count, 6)
            XCTAssertTrue(code.code.allSatisfy(\.isNumber))
            XCTAssertEqual(code.payload.code, code.code)
            XCTAssertEqual(code.payload.urls, PairingEnvironment.current?.urls)
            XCTAssertEqual(code.payload.certificateSHA256, PairingEnvironment.current?.certificateSHA256)
            XCTAssertEqual(code.expiresAt.timeIntervalSinceNow, PairingService.codeLifetime, accuracy: 5)
            XCTAssertEqual(try PairingLink.payload(from: code.qrURL), code.payload)

            let pair = PairRequest(code: code.code, deviceName: "Chad's iPhone", platform: "iOS")
            let paired = try await client.execute(uri: "/v1/pair", method: .post, headers: [.contentType: "application/json"],
                                                  body: try self.json(pair)) { response -> PairResponse in
                XCTAssertEqual(response.status, .ok)
                return try self.decode(PairResponse.self, response)
            }
            XCTAssertEqual(paired.user, self.admin)
            XCTAssertEqual(paired.serverName, "Test Server")

            try await client.execute(uri: "/v1/me", method: .get, headers: self.bearer(paired.token)) { response in
                XCTAssertEqual(response.status, .ok)
                XCTAssertEqual(try self.decode(MeResponse.self, response).deviceID, paired.deviceID)
            }
            // One-time use.
            try await client.execute(uri: "/v1/pair", method: .post, headers: [.contentType: "application/json"],
                                     body: try self.json(pair)) { XCTAssertEqual($0.status, .unauthorized) }
        }
    }

    func testWrongCodeIsRejected() async throws {
        let service = PairingService(store: store)
        let code = try service.createCode(for: nil, caller: try adminAuth()).code
        let wrong = String(format: "%06d", (Int(code)! + 1) % 1_000_000)
        try await app().test(.router) { client in
            for attempt in [wrong, "12345", "abcdef", ""] {
                try await client.execute(uri: "/v1/pair", method: .post, headers: [.contentType: "application/json"],
                                         body: try self.json(PairRequest(code: attempt, deviceName: "iPad", platform: "iPadOS"))) {
                    XCTAssertEqual($0.status, .unauthorized, "code \(attempt)")
                }
            }
        }
        // The real code still works afterwards.
        XCTAssertEqual(try service.pair(PairRequest(code: code, deviceName: "iPad", platform: "iPadOS")).user.id, admin.id)
    }

    func testCodeExpiresAfterTenMinutes() throws {
        let clock = TestClock(Date(timeIntervalSince1970: 1_800_000_000))
        let service = PairingService(store: store, now: { clock.now })
        let auth = try adminAuth()
        let early = try service.createCode(for: nil, caller: auth)
        let late = try service.createCode(for: nil, caller: auth)
        XCTAssertNotEqual(early.code, late.code)

        clock.now = clock.now.addingTimeInterval(9 * 60 + 59)
        XCTAssertNoThrow(try service.pair(PairRequest(code: early.code, deviceName: "iPhone", platform: "iOS")))

        clock.now = clock.now.addingTimeInterval(2)
        XCTAssertThrowsError(try service.pair(PairRequest(code: late.code, deviceName: "iPad", platform: "iPadOS"))) { error in
            XCTAssertEqual((error as? HTTPError)?.status, .unauthorized)
        }
    }

    func testCreatingCodesNeedsAdmin() async throws {
        let player = try store.createUser(displayName: "Alex", role: .player)
        let playerToken = try store.createDeviceToken(userID: player.id, deviceName: "Alex's iPhone").token
        let (_, readOnlyBot) = try store.createAPIToken(ownerUserID: admin.id, name: "bot", scopes: [.libraryRead])
        let (_, adminBot) = try store.createAPIToken(ownerUserID: admin.id, name: "openclaw", scopes: [.usersAdmin])
        try await app().test(.router) { client in
            let body = try self.json(CreatePairingCodeRequest())
            try await client.execute(uri: "/v1/admin/pairing-codes", method: .post, headers: [.contentType: "application/json"], body: body) {
                XCTAssertEqual($0.status, .unauthorized)
            }
            try await client.execute(uri: "/v1/admin/pairing-codes", method: .post, headers: self.bearer(playerToken), body: body) {
                XCTAssertEqual($0.status, .forbidden)
            }
            try await client.execute(uri: "/v1/admin/pairing-codes", method: .post, headers: self.bearer(readOnlyBot), body: body) {
                XCTAssertEqual($0.status, .forbidden)
            }
            try await client.execute(uri: "/v1/admin/pairing-codes", method: .post, headers: self.bearer(adminBot), body: body) {
                XCTAssertEqual($0.status, .created)
            }
        }
    }

    /// Phase 2 invite path: a code bound to a player pairs a device for that player, not the admin.
    func testInviteCodeForPlayerPairsAsPlayer() async throws {
        let player = try store.createUser(displayName: "Alex", role: .player)
        let service = PairingService(store: store)
        let code = try service.createCode(for: player.id, caller: try adminAuth())
        let paired = try service.pair(PairRequest(code: code.code, deviceName: "Alex's iPhone", platform: "iOS"))
        XCTAssertEqual(paired.user, player)
        XCTAssertEqual(try store.authenticate(token: paired.token)?.user.role, .player)

        XCTAssertThrowsError(try service.createCode(for: "no-such-user", caller: try adminAuth())) {
            XCTAssertEqual(($0 as? HTTPError)?.status, .notFound)
        }
    }

    func testCodesAreStoredHashed() throws {
        let code = try PairingService(store: store).createCode(for: nil, caller: try adminAuth()).code
        let rows = try store.db.read { try Row.fetchAll($0, sql: "SELECT * FROM pairing_codes") }
        XCTAssertEqual(rows.count, 1)
        for column in rows[0].columnNames {
            XCTAssertNotEqual(rows[0][column] as String?, code, column)
        }
    }

    func testPairEndpointIsRateLimited() async throws {
        try await app().test(.router) { client in
            let wrong = try self.json(PairRequest(code: "000000", deviceName: "x", platform: "iOS"))
            for _ in 0..<5 {
                try await client.execute(uri: "/v1/pair", method: .post, headers: [.contentType: "application/json"], body: wrong) {
                    XCTAssertEqual($0.status, .unauthorized)
                }
            }
            try await client.execute(uri: "/v1/pair", method: .post, headers: [.contentType: "application/json"], body: wrong) {
                XCTAssertEqual($0.status, .tooManyRequests)
            }
        }
    }

    func testRateLimiterWindowSlides() {
        let clock = TestClock(Date(timeIntervalSince1970: 0))
        let limiter = PairingRateLimiter(maxFailures: 2, window: 60, now: { clock.now })
        limiter.recordFailure(); limiter.recordFailure()
        XCTAssertFalse(limiter.allowAttempt())
        clock.now = clock.now.addingTimeInterval(61)
        XCTAssertTrue(limiter.allowAttempt())
    }

    // MARK: QR payload

    func testQRPayloadRoundTrip() throws {
        let payload = PairingPayload(serverName: "Chad’s Mac mini 🎮",
                                     urls: [URL(string: "https://chads-mac-mini.local:8487")!, URL(string: "https://100.101.102.103:8487")!],
                                     certificateSHA256: String(repeating: "0f", count: 32), code: "042137")
        let url = try payload.qrURL()
        XCTAssertEqual(url.scheme, "supersemu")
        XCTAssertEqual(url.host, "pair")
        let encoded = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first?.value)
        XCTAssertFalse(encoded.contains("=") || encoded.contains("+") || encoded.contains("/"))
        XCTAssertEqual(try PairingLink.payload(from: url), payload)
        XCTAssertEqual(try PairingLink.payload(from: "  \(url.absoluteString)\n"), payload)
    }

    func testQRPayloadRejectsOtherLinks() {
        XCTAssertThrowsError(try PairingLink.payload(from: "https://example.com/pair?d=abc")) {
            XCTAssertEqual($0 as? PairingLink.ParseError, .notAPairingLink)
        }
        XCTAssertThrowsError(try PairingLink.payload(from: "supersemu://pair")) {
            XCTAssertEqual($0 as? PairingLink.ParseError, .missingPayload)
        }
        XCTAssertThrowsError(try PairingLink.payload(from: "supersemu://pair?d=bm90IGpzb24")) {
            XCTAssertEqual($0 as? PairingLink.ParseError, .invalidPayload)
        }
    }

    func testBase64URLHandlesAllPaddingLengths() {
        for length in 0..<8 {
            let data = Data((0..<length).map { UInt8(250 - $0) })
            XCTAssertEqual(Base64URL.decode(Base64URL.encode(data)), data)
        }
    }

    // MARK: Helpers

    func adminAuth() throws -> AuthContext { try XCTUnwrap(store.authenticate(token: adminToken)) }
}

final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Date
    init(_ date: Date) { value = date }
    var now: Date {
        get { lock.withLock { value } }
        set { lock.withLock { value = newValue } }
    }
}
