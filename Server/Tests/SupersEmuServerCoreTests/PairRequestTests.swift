import CryptoKit
import Foundation
import GRDB
import Hummingbird
import HummingbirdTesting
import SupersEmuKit
@testable import SupersEmuServerCore
import XCTest

final class PairRequestTests: XCTestCase {
    private var store: ServerStore!
    private var admin: UserInfo!
    private var service: PairRequestService!
    private var pairing: PairingService!

    override func setUp() async throws {
        store = try ServerStore.inMemory()
        admin = try store.createUser(displayName: "Owner", role: .admin)
        pairing = PairingService(store: store)
        service = PairRequestService(store: store, pairing: pairing)
        PairingEnvironment.current = PairingEnvironment(urls: [], certificateSHA256: String(repeating: "ab", count: 32))
    }

    override func tearDown() async throws {
        PairingEnvironment.current = nil
    }

    private func makeCaller() throws -> AuthContext {
        let token = try store.createDeviceToken(userID: admin.id, deviceName: "Mac").token
        return try XCTUnwrap(store.authenticate(token: token))
    }

    private func create() async throws -> PairRequestCreated {
        let digest = SHA256.hash(data: Data((0..<32).map { _ in UInt8(0x11) })).map { String(format: "%02x", $0) }.joined()
        return try await service.create(PairRequestCreate(deviceName: "iPhone", platform: "ios", claimHash: digest),
                                        remoteAddress: "192.0.2.10")
    }

    func testRoutesRequireAdminForApprovalAndLimitRequestCreation() async throws {
        let adminToken = try store.createDeviceToken(userID: admin.id, deviceName: "Owner Mac").token
        let player = try store.createUser(displayName: "Player", role: .player)
        let playerToken = try store.createDeviceToken(userID: player.id, deviceName: "Player Mac").token
        let secret = String(repeating: "11", count: 32)
        let digest = SHA256.hash(data: Data(repeating: 0x11, count: 32)).map { String(format: "%02x", $0) }.joined()
        let body = PairRequestCreate(deviceName: "iPhone", platform: "ios",
                                     claimHash: digest)
        func encoded<T: Encodable>(_ value: T) throws -> ByteBuffer {
            ByteBuffer(data: try SupersEmuJSON.encoder().encode(value))
        }
        try await buildApplication(store: store, configuration: .init()).test(.router) { client in
            var created: PairRequestCreated?
            try await client.execute(uri: "/v1/pair/requests", method: .post, headers: [.contentType: "application/json"],
                                     body: try encoded(body)) { response in
                XCTAssertEqual(response.status, .created)
                created = try SupersEmuJSON.decoder().decode(PairRequestCreated.self, from: Data(buffer: response.body))
            }
            try await client.execute(uri: "/v1/pair/requests/\(created!.requestID)/claim", method: .post,
                                     headers: [.contentType: "application/json"],
                                     body: try encoded(PairRequestClaim(claimSecret: secret))) {
                XCTAssertEqual($0.status, .accepted)
            }
            try await client.execute(uri: "/v1/pair/requests/\(created!.requestID)/claim", method: .post,
                                     headers: [.contentType: "application/json"],
                                     body: try encoded(PairRequestClaim(claimSecret: String(repeating: "22", count: 32)))) {
                XCTAssertEqual($0.status, .notFound)
            }
            try await client.execute(uri: "/v1/admin/pair-requests", method: .get) {
                XCTAssertEqual($0.status, .unauthorized)
            }
            try await client.execute(uri: "/v1/admin/pair-requests", method: .get,
                                     headers: [.authorization: "Bearer \(playerToken)"]) {
                XCTAssertEqual($0.status, .forbidden)
            }
            try await client.execute(uri: "/v1/admin/pair-requests/\(created!.requestID)/approve", method: .post,
                                     headers: [.authorization: "Bearer \(adminToken)", .contentType: "application/json"],
                                     body: try encoded(PairRequestApproval())) {
                XCTAssertEqual($0.status, .ok)
            }
            try await client.execute(uri: "/v1/pair/requests/\(created!.requestID)/claim", method: .post,
                                     headers: [.contentType: "application/json"],
                                     body: try encoded(PairRequestClaim(claimSecret: secret))) { response in
                XCTAssertEqual(response.status, .ok)
                let paired = try SupersEmuJSON.decoder().decode(PairResponse.self, from: Data(buffer: response.body))
                XCTAssertNotNil(try self.store.authenticate(token: paired.token))
            }
            try await client.execute(uri: "/v1/pair/requests/\(created!.requestID)/claim", method: .post,
                                     headers: [.contentType: "application/json"],
                                     body: try encoded(PairRequestClaim(claimSecret: secret))) {
                XCTAssertEqual($0.status, .gone)
            }
            for _ in 0..<4 {
                try await client.execute(uri: "/v1/pair/requests", method: .post, headers: [.contentType: "application/json"],
                                         body: try encoded(body)) { XCTAssertEqual($0.status, .created) }
            }
            try await client.execute(uri: "/v1/pair/requests", method: .post, headers: [.contentType: "application/json"],
                                     body: try encoded(body)) { XCTAssertEqual($0.status, .tooManyRequests) }
        }
    }

    func testApprovalClaimAndSingleUseTokenDelivery() async throws {
        let request = try await create()
        let secret = String(repeating: "11", count: 32)
        let pendingResult = try await service.claim(id: request.requestID, claimSecret: secret)
        XCTAssertEqual(pendingResult, .pending)
        try await service.approve(id: request.requestID, userID: nil, caller: try makeCaller())
        guard case .paired(let response) = try await service.claim(id: request.requestID, claimSecret: secret) else {
            return XCTFail("Expected approved response")
        }
        XCTAssertEqual(response.user.id, admin.id)
        XCTAssertNotNil(try store.authenticate(token: response.token))
        do {
            _ = try await service.claim(id: request.requestID, claimSecret: secret)
            XCTFail("Expected consumed response to be gone")
        } catch {
            XCTAssertEqual((error as? HTTPError)?.status, .gone)
        }
    }

    func testDeniedExpiredAndWrongSecretStatuses() async throws {
        let denied = try await create()
        do {
            _ = try await service.claim(id: denied.requestID, claimSecret: String(repeating: "22", count: 32))
            XCTFail("Expected wrong secret to be hidden")
        } catch {
            XCTAssertEqual((error as? HTTPError)?.status, .notFound)
        }
        try await service.deny(id: denied.requestID, caller: try makeCaller())
        do {
            _ = try await service.claim(id: denied.requestID, claimSecret: String(repeating: "11", count: 32))
            XCTFail("Expected denied request")
        } catch {
            XCTAssertEqual((error as? HTTPError)?.status, .forbidden)
        }

        let clock = TestClock(Date(timeIntervalSince1970: 1_800_000_000))
        let expiring = PairRequestService(store: store, pairing: pairing, now: { clock.now })
        let secret = String(repeating: "11", count: 32)
        let hash = SHA256.hash(data: Data(repeating: 0x11, count: 32)).map { String(format: "%02x", $0) }.joined()
        let request = try await expiring.create(PairRequestCreate(deviceName: "iPad", platform: "ipados", claimHash: hash), remoteAddress: "local")
        clock.now = clock.now.addingTimeInterval(301)
        do {
            _ = try await expiring.claim(id: request.requestID, claimSecret: secret)
            XCTFail("Expected expired request")
        } catch {
            XCTAssertEqual((error as? HTTPError)?.status, .gone)
        }
    }

    func testCreateRateLimitIsPerIPAndDoesNotBlockPairCodePairing() async throws {
        let digest = SHA256.hash(data: Data(repeating: 0x11, count: 32)).map { String(format: "%02x", $0) }.joined()
        let body = PairRequestCreate(deviceName: "iPhone", platform: "ios", claimHash: digest)
        let isolated = PairRequestService(store: store, pairing: pairing)
        for _ in 0..<5 {
            _ = try await isolated.create(body, remoteAddress: "192.0.2.10")
        }
        do {
            _ = try await isolated.create(body, remoteAddress: "192.0.2.10")
            XCTFail("Expected per-IP creation limit")
        } catch {
            XCTAssertEqual((error as? HTTPError)?.status, .tooManyRequests)
        }
        _ = try await isolated.create(body, remoteAddress: "192.0.2.11")

        let code = try pairing.createCode(for: nil, caller: makeCaller()).code
        try await buildApplication(store: store, configuration: .init()).test(.router) { client in
            for _ in 0..<5 {
                try await client.execute(uri: "/v1/pair/requests", method: .post,
                                         headers: [.contentType: "application/json"],
                                         body: ByteBuffer(data: try SupersEmuJSON.encoder().encode(body))) {
                    XCTAssertEqual($0.status, .created)
                }
            }
            try await client.execute(uri: "/v1/pair/requests", method: .post,
                                     headers: [.contentType: "application/json"],
                                     body: ByteBuffer(data: try SupersEmuJSON.encoder().encode(body))) {
                XCTAssertEqual($0.status, .tooManyRequests)
            }
            let pairingBody = PairRequest(code: code, deviceName: "iPhone", platform: "ios")
            try await client.execute(uri: "/v1/pair", method: .post,
                                     headers: [.contentType: "application/json"],
                                     body: ByteBuffer(data: try SupersEmuJSON.encoder().encode(pairingBody))) {
                XCTAssertEqual($0.status, .ok)
            }
        }
    }

    func testWrongAndUnknownClaimsCostFiveAndAreRateLimited() async throws {
        let claimSecret = String(repeating: "11", count: 32)
        let expectedHash = SHA256.hash(data: Data(repeating: 0x22, count: 32))
            .map { String(format: "%02x", $0) }.joined()
        let request = try await service.create(
            PairRequestCreate(deviceName: "iPhone", platform: "ios", claimHash: expectedHash),
            remoteAddress: "192.0.2.10"
        )
        for _ in 0..<6 {
            do {
                _ = try await service.claim(id: request.requestID, claimSecret: claimSecret,
                                            remoteAddress: "192.0.2.12")
                XCTFail("Expected wrong secret")
            } catch {
                XCTAssertEqual((error as? HTTPError)?.status, .notFound)
            }
        }
        for _ in 0..<6 {
            do {
                _ = try await service.claim(id: UUID(), claimSecret: claimSecret, remoteAddress: "192.0.2.12")
                XCTFail("Expected unknown request")
            } catch {
                XCTAssertEqual((error as? HTTPError)?.status, .notFound)
            }
        }
        do {
            _ = try await service.claim(id: UUID(), claimSecret: claimSecret, remoteAddress: "192.0.2.12")
            XCTFail("Expected claim rate limit")
        } catch {
            XCTAssertEqual((error as? HTTPError)?.status, .tooManyRequests)
        }
    }

    func testClaimRouteRateLimitsMalformedIDsByClientIP() async throws {
        let body = PairRequestClaim(claimSecret: String(repeating: "11", count: 32))
        func encoded<T: Encodable>(_ value: T) throws -> ByteBuffer {
            ByteBuffer(data: try SupersEmuJSON.encoder().encode(value))
        }

        try await buildApplication(store: store, configuration: .init()).test(.router) { client in
            for _ in 0..<12 {
                try await client.execute(uri: "/v1/pair/requests/not-a-uuid/claim", method: .post,
                                         headers: [.contentType: "application/json"], body: try encoded(body)) {
                    XCTAssertEqual($0.status, .notFound)
                }
            }
            try await client.execute(uri: "/v1/pair/requests/not-a-uuid/claim", method: .post,
                                     headers: [.contentType: "application/json"], body: try encoded(body)) {
                XCTAssertEqual($0.status, .tooManyRequests)
            }
        }
    }

    func testPerIPPendingCapReplacesOldestAndCreateLimitApplies() async throws {
        let clock = TestClock(Date(timeIntervalSince1970: 1_800_000_000))
        let capped = PairRequestService(store: store, pairing: pairing, now: { clock.now },
                                        maximumPendingPerClient: 2)
        let hash = SHA256.hash(data: Data(repeating: 0x11, count: 32)).map { String(format: "%02x", $0) }.joined()
        let body = PairRequestCreate(deviceName: "iPhone", platform: "ios", claimHash: hash)
        let first = try await capped.create(body, remoteAddress: "ip")
        clock.now = clock.now.addingTimeInterval(1)
        _ = try await capped.create(body, remoteAddress: "ip")
        clock.now = clock.now.addingTimeInterval(1)
        _ = try await capped.create(body, remoteAddress: "ip")
        let pending = await capped.pending()
        XCTAssertEqual(pending.count, 2)
        do {
            _ = try await capped.claim(id: first.requestID, claimSecret: String(repeating: "11", count: 32))
            XCTFail("Expected evicted request")
        } catch {
            XCTAssertEqual((error as? HTTPError)?.status, .gone)
        }
        _ = try await capped.create(body, remoteAddress: "ip")
        _ = try await capped.create(body, remoteAddress: "ip")
        do {
            _ = try await capped.create(body, remoteAddress: "ip")
            XCTFail("Expected per-IP creation limit")
        } catch {
            XCTAssertEqual((error as? HTTPError)?.status, .tooManyRequests)
        }
    }

    func testGlobalPendingCapRejectsWithoutEvictingExistingRequests() async throws {
        let hash = SHA256.hash(data: Data(repeating: 0x11, count: 32)).map { String(format: "%02x", $0) }.joined()
        let body = PairRequestCreate(deviceName: "iPhone", platform: "ios", claimHash: hash)
        let capped = PairRequestService(store: store, pairing: pairing)
        var existingIDs = Set<UUID>()
        for index in 0..<10 {
            let created = try await capped.create(body, remoteAddress: "192.0.2.\(index + 1)")
            existingIDs.insert(created.requestID)
        }
        do {
            _ = try await capped.create(body, remoteAddress: "192.0.2.50")
            XCTFail("Expected global pending cap")
        } catch {
            XCTAssertEqual((error as? HTTPError)?.status, .tooManyRequests)
        }
        let stillPending = await capped.pending()
        XCTAssertEqual(Set(stillPending.map(\.id)), existingIDs)
    }
}
