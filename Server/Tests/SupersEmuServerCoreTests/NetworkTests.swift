import Foundation
import CryptoKit
import Hummingbird
import HummingbirdTesting
import Logging
import NIOCore
import Network
import Security
@testable import SupersEmuKit
@testable import SupersEmuServerCore
import XCTest

final class NetworkTests: XCTestCase {
    override func tearDown() async throws {
        PairingEnvironment.current = nil
    }

    // MARK: Certificate pinning

    func makeTrust(_ identity: TLSIdentity) throws -> SecTrust {
        let certificate = try XCTUnwrap(SecCertificateCreateWithData(nil, identity.certificateDER as CFData))
        var trust: SecTrust?
        XCTAssertEqual(SecTrustCreateWithCertificates(certificate, SecPolicyCreateSSL(true, "localhost" as CFString), &trust), errSecSuccess)
        return try XCTUnwrap(trust)
    }

    func testPinnedDelegateAcceptsOnlyMatchingCertificate() throws {
        let identity = try TLSIdentity.generate(commonName: "Test", dnsNames: ["localhost"])
        let other = try TLSIdentity.generate(commonName: "Impostor", dnsNames: ["localhost"])
        let trust = try makeTrust(identity)
        let serverTrust = NSURLAuthenticationMethodServerTrust

        XCTAssertEqual(PinnedCertificateDelegate(certificateSHA256: identity.sha256).decision(authenticationMethod: serverTrust, trust: trust), .useTrust)
        XCTAssertEqual(PinnedCertificateDelegate(certificateSHA256: other.sha256).decision(authenticationMethod: serverTrust, trust: trust), .reject)
        XCTAssertEqual(PinnedCertificateDelegate(certificateSHA256: identity.sha256).decision(authenticationMethod: serverTrust, trust: nil), .reject)
        XCTAssertEqual(PinnedCertificateDelegate(certificateSHA256: "abc").decision(authenticationMethod: serverTrust, trust: trust), .reject)
        // Not a TLS server-trust challenge, or no pin: system default handling.
        XCTAssertEqual(PinnedCertificateDelegate(certificateSHA256: identity.sha256)
            .decision(authenticationMethod: NSURLAuthenticationMethodHTTPBasic, trust: nil), .defaultHandling)
        XCTAssertEqual(PinnedCertificateDelegate(certificateSHA256: nil).decision(authenticationMethod: serverTrust, trust: trust), .defaultHandling)
    }

    func testFingerprintNormalization() throws {
        let identity = try TLSIdentity.generate(commonName: "Test", dnsNames: [])
        let colonUpper = stride(from: 0, to: 64, by: 2).map { i -> String in
            let start = identity.sha256.index(identity.sha256.startIndex, offsetBy: i)
            return String(identity.sha256[start..<identity.sha256.index(start, offsetBy: 2)]).uppercased()
        }.joined(separator: ":")
        XCTAssertTrue(CertificatePin.matches(certificateDER: identity.certificateDER, expected: colonUpper))
        XCTAssertEqual(identity.sha256.count, 64)
    }

    func testTLSIdentityIsCreatedOnceAndReused() throws {
        let store = try ServerStore.inMemory()
        let first = try TLSIdentity.loadOrCreate(paths: store.paths, commonName: "Test")
        let second = try TLSIdentity.loadOrCreate(paths: store.paths, commonName: "Test")
        XCTAssertEqual(first.sha256, second.sha256)
        XCTAssertEqual(TLSIdentity.storedFingerprint(paths: store.paths), first.sha256)
        let keyMode = try FileManager.default.attributesOfItem(atPath: TLSIdentity.keyURL(store.paths).path)[.posixPermissions] as? Int
        XCTAssertEqual(keyMode, 0o600)
    }

    /// End to end over real HTTPS: pair through `ServerConnection` with the pin from the QR payload, then a
    /// session pinned to a different certificate can't connect.
    func testHTTPSPairingWithPinnedCertificate() async throws {
        let store = try ServerStore.inMemory()
        let admin = try store.createUser(displayName: "Chad", role: .admin)
        var options = ServerRunOptions()
        options.hostname = "127.0.0.1"
        options.port = 0
        options.bonjour = false
        options.metadata = false
        let (portStream, portContinuation) = AsyncStream.makeStream(of: Int.self)
        let (application, _, environment) = try ServerLauncher.makeApplication(store: store, options: options) { channel in
            portContinuation.yield(channel.localAddress?.port ?? 0)
        }
        let server = Task { try await application.runService() }
        defer { server.cancel() }
        var ports = portStream.makeAsyncIterator()
        let nextPort = await ports.next()
        let port = try XCTUnwrap(nextPort)
        let pin = try XCTUnwrap(environment.certificateSHA256)
        XCTAssertEqual(pin, TLSIdentity.storedFingerprint(paths: store.paths))
        PairingEnvironment.current = PairingEnvironment(
            urls: [URL(string: "https://127.0.0.1:1")!, URL(string: "https://127.0.0.1:\(port)")!], certificateSHA256: pin)

        let adminAuth = AuthContext(user: admin, credential: .device(id: "setup"))
        let code = try PairingService(store: store).createCode(for: nil, caller: adminAuth)
        let payload = try PairingLink.payload(from: code.qrURL)

        let tokens = InMemoryTokenStore()
        let (connection, paired) = try await ServerConnection.pair(payload: payload, deviceName: "Test iPhone", platform: "iOS", tokenStore: tokens)
        XCTAssertEqual(paired.user, admin)
        let profile = await connection.profile
        XCTAssertEqual(profile.lastGoodURL, URL(string: "https://127.0.0.1:\(port)"))
        XCTAssertEqual(try tokens.token(for: profile.tokenAccount), paired.token)
        let me = try await connection.client().me()
        XCTAssertEqual(me.deviceID, paired.deviceID)

        let impostorPin = try TLSIdentity.generate(commonName: "x", dnsNames: []).sha256
        let wrongPin = APIClient(baseURL: URL(string: "https://127.0.0.1:\(port)")!, token: nil,
                                 session: PinnedCertificateDelegate.session(certificateSHA256: impostorPin, timeout: 5))
        do {
            _ = try await wrongPin.health()
            XCTFail("A session pinned to another certificate must not connect")
        } catch {
            XCTAssertNotNil(error as? URLError)
        }
    }

    // MARK: ServerConnection

    func testConnectionFallsBackAndRemembersLastGoodURL() async throws {
        let lan = URL(string: "https://mac-mini.local:8487")!
        let remote = URL(string: "https://games.supersemu.com:8487")!
        let changes = TestBox<[URL?]>([])
        let connection = ServerConnection(profile: ServerProfile(serverName: "Mini", urls: [lan, remote], certificateSHA256: nil),
                                          tokenStore: InMemoryTokenStore(),
                                          onProfileChange: { profile in changes.update { $0.append(profile.lastGoodURL) } })
        let tried = TestBox<[URL]>([])
        let url = try await connection.resolveURL { url in
            tried.update { $0.append(url) }
            if url == lan { throw URLError(.cannotFindHost) }
        }
        XCTAssertEqual(url, remote)
        XCTAssertEqual(tried.value, [lan, remote])
        XCTAssertEqual(changes.value, [remote])
        let candidates = await connection.candidates
        XCTAssertEqual(candidates, [remote, lan])

        do {
            try await connection.resolveURL { _ in throw URLError(.timedOut) }
            XCTFail("expected unreachable")
        } catch let error as ServerConnectionError {
            guard case .unreachable(let errors) = error else { return XCTFail("\(error)") }
            XCTAssertEqual(errors.count, 2)
        }
        do {
            _ = try await connection.client()
            XCTFail("expected notPaired")
        } catch {
            XCTAssertEqual(error as? ServerConnectionError, .notPaired)
        }
    }

    func testCandidateOrderDeduplicates() {
        let a = URL(string: "https://a:1")!, b = URL(string: "https://b:1")!
        XCTAssertEqual(ServerConnection.candidateOrder(urls: [a, b], lastGood: nil), [a, b])
        XCTAssertEqual(ServerConnection.candidateOrder(urls: [a, b], lastGood: b), [b, a])
        XCTAssertEqual(ServerConnection.candidateOrder(urls: [a], lastGood: b), [b, a])
    }

    // MARK: LAN URLs and Bonjour

    func testAdvertisedURLsKeepLANAndExcludeOverlayVPNAddresses() {
        let urls = LocalNetwork.advertisedURLs(
            scheme: "https", port: 8487, hostName: "Chads-Mac-mini",
            addresses: [.init(interface: "utun4", address: "100.101.1.2"), .init(interface: "en0", address: "192.168.1.20"),
                        .init(interface: "en1", address: "169.254.3.4"), .init(interface: "en0", address: "192.168.1.20"),
                        .init(interface: "utun4", address: "fd7a:115c:a1e0::1")])
        XCTAssertEqual(urls.map(\.absoluteString), [
            "https://Chads-Mac-mini.local:8487", "https://192.168.1.20:8487",
        ])
        XCTAssertTrue(LocalNetwork.isOverlayVPNAddress("100.64.0.1"))
        XCTAssertTrue(LocalNetwork.isOverlayVPNAddress("100.127.255.255"))
        XCTAssertTrue(LocalNetwork.isOverlayVPNAddress("fd7a:115c:a1e0::1"))
        XCTAssertFalse(LocalNetwork.isOverlayVPNAddress("100.128.0.1"))
        XCTAssertFalse(LocalNetwork.isOverlayVPNAddress("10.0.0.1"))
    }

    func testPairingEnvironmentUsesSnapshotWithoutDetection() {
        let urls = [URL(string: "https://mini.local:8487")!]
        let environment = PairingEnvironment(urls: urls, certificateSHA256: "pin")
        XCTAssertEqual(environment.currentURLs, urls)
    }

    func testPairingEnvironmentDetectsCurrentURLsWhenConfigured() {
        let detection = URLDetection(scheme: "https", port: 8487)
        let environment = PairingEnvironment(urls: [], certificateSHA256: "pin", detection: detection)
        XCTAssertEqual(
            environment.currentURLs,
            LocalNetwork.advertisedURLs(scheme: detection.scheme, port: detection.port))
    }

    func testPairingEnvironmentFallbackEnablesRuntimeDetection() throws {
        PairingEnvironment.current = nil
        let environment = PairingEnvironment.resolve(for: try ServerStore.inMemory())
        let detection = try XCTUnwrap(environment.detection)
        XCTAssertEqual(detection.scheme, environment.certificateSHA256 == nil ? "http" : "https")
        XCTAssertEqual(detection.port, ServerDefaults.port)
    }

    func testServerLauncherUsesDetectionUnlessAdvertiseURLsAreExplicit() throws {
        let store = try ServerStore.inMemory()
        var options = ServerRunOptions()
        options.insecureHTTP = true
        options.metadata = false
        options.port = 8487

        let detected = try ServerLauncher.makeApplication(store: store, options: options).environment
        XCTAssertEqual(detected.detection, URLDetection(scheme: "http", port: 8487))

        let explicitURLs = [URL(string: "https://manual.example.com:8487")!]
        options.advertiseURLs = explicitURLs
        let overridden = try ServerLauncher.makeApplication(store: store, options: options).environment
        XCTAssertNil(overridden.detection)
        XCTAssertEqual(overridden.currentURLs, explicitURLs)
    }

    func testBonjourTXTRoundTripAndURLs() {
        let txt = SupersEmuBonjour.txtRecord(scheme: "https", certificateSHA256: "AB:CD", serverName: "Mac mini")
        XCTAssertEqual(SupersEmuBonjour.decodeTXT(SupersEmuBonjour.encodeTXT(txt)), txt)
        XCTAssertEqual(txt["fp"], "abcd")
        XCTAssertEqual(SupersEmuBonjour.url(scheme: "https", host: "fe80::1%en0", port: 8487)?.absoluteString, "https://[fe80::1]:8487")
        XCTAssertEqual(SupersEmuBonjour.url(scheme: "https", host: "192.168.1.2", port: 8487)?.absoluteString, "https://192.168.1.2:8487")
        XCTAssertEqual(SupersEmuBonjour.url(scheme: "https", host: "mini.local", port: 8487)?.absoluteString, "https://mini.local:8487")
        XCTAssertEqual(SupersEmuBonjour.url(scheme: "https", host: "[2001:db8::1]", port: 8487)?.absoluteString,
                       "https://[2001:db8::1]:8487")

        let discovered = DiscoveredServer(name: "Mini", txt: txt, endpoint: .hostPort(host: "localhost", port: 1))
        XCTAssertTrue(discovered.matches(ServerProfile(serverName: "Mini", urls: [], certificateSHA256: "abcd")))
        XCTAssertFalse(discovered.matches(ServerProfile(serverName: "Mini", urls: [], certificateSHA256: "ffff")))
    }

    /// Advertise with dns_sd, find it with NWBrowser, resolve it to a URL. Needs a working mDNSResponder.
    func testBonjourAdvertiseBrowseResolve() async throws {
        let name = "SupersEmu Test \(UUID().uuidString.prefix(6))"
        let advertiser = try BonjourAdvertiser(name: name, port: 48_487,
                                               txt: SupersEmuBonjour.txtRecord(scheme: "https", certificateSHA256: "ab", serverName: name))
        defer { advertiser.stop() }
        let browser = ServerBrowser()
        let found = try await withThrowingTaskGroup(of: DiscoveredServer?.self) { group in
            group.addTask {
                for await servers in browser.servers() {
                    if let match = servers.first(where: { $0.name == name }) { return match }
                }
                return nil
            }
            group.addTask { try await Task.sleep(nanoseconds: 10_000_000_000); return nil }
            let result = try await group.next() ?? nil
            group.cancelAll()
            browser.cancel()
            return result
        }
        let server = try XCTUnwrap(found, "Bonjour service not found within 10s")
        XCTAssertEqual(server.serverName, name)
        XCTAssertEqual(server.certificateSHA256, "ab")
        XCTAssertEqual(server.scheme, "https")
    }

    // MARK: Bootstrap + token store

    func testBootstrapWritesAdminTokenOnce() throws {
        let store = try ServerStore.inMemory()
        let (admin, wrote) = try ServerBootstrap.ensureAdmin(store: store, displayName: "Chad")
        XCTAssertTrue(wrote)
        let token = try String(contentsOf: store.paths.adminToken, encoding: .utf8)
        XCTAssertEqual(try store.authenticate(token: token)?.user, admin)
        let mode = try FileManager.default.attributesOfItem(atPath: store.paths.adminToken.path)[.posixPermissions] as? Int
        XCTAssertEqual(mode, 0o600)
        let again = try ServerBootstrap.ensureAdmin(store: store, displayName: "Someone else")
        XCTAssertEqual(again.admin, admin)
        XCTAssertFalse(again.wroteToken)
        XCTAssertEqual(try String(contentsOf: store.paths.adminToken, encoding: .utf8), token)
    }

    func testKeychainTokenStore() throws {
        let store = KeychainTokenStore(service: "com.chadillac6.supersemu.tests.\(UUID().uuidString)")
        do {
            try store.setToken("sed_one", for: "server")
        } catch let error as KeychainError {
            throw XCTSkip("Keychain unavailable in this environment: \(error)")
        }
        XCTAssertEqual(try store.token(for: "server"), "sed_one")
        try store.setToken("sed_two", for: "server")
        XCTAssertEqual(try store.token(for: "server"), "sed_two")
        try store.removeToken(for: "server")
        XCTAssertNil(try store.token(for: "server"))
        XCTAssertNoThrow(try store.removeToken(for: "server"))
    }
}

final class PublicAccessTests: XCTestCase {
    private var store: ServerStore!
    private var admin: UserInfo!
    private var adminDevice: String!

    override func setUp() async throws {
        PairingEnvironment.current = nil
        store = try ServerStore.inMemory()
        admin = try store.createUser(displayName: "Chad", role: .admin)
        adminDevice = try store.createDeviceToken(userID: admin.id, deviceName: "Admin device").token
    }

    override func tearDown() async throws {
        PairingEnvironment.current = nil
    }

    private func publicApp(publicURL: URL? = nil) -> some ApplicationProtocol {
        Application(router: buildRouter(store: store, exposure: .publicInternet,
                                        certificateSHA256: "identity-pin", publicURL: publicURL))
    }

    private func bearer(_ token: String) -> HTTPFields { [.authorization: "Bearer \(token)"] }

    private func badPair(_ code: String = "000000") throws -> ByteBuffer {
        ByteBuffer(data: try SupersEmuJSON.encoder().encode(PairRequest(code: code, deviceName: "Test", platform: "iOS")))
    }

    private func requestBody() throws -> ByteBuffer {
        let digest = SHA256.hash(data: Data(repeating: 0x11, count: 32)).map { String(format: "%02x", $0) }.joined()
        return ByteBuffer(data: try SupersEmuJSON.encoder().encode(
            PairRequestCreate(deviceName: "Friend's phone", platform: "iOS", claimHash: digest)))
    }

    func testPublicRouterOmitsAdminRoutesButLocalRouterKeepsThem() async throws {
        let allScopes = try store.createAPIToken(ownerUserID: admin.id, name: "admin-bot", scopes: Scope.allCases).token
        let routes: [(HTTPRequest.Method, String, ByteBuffer?)] = [
            (.get, "/v1/admin/status", nil), (.get, "/v1/admin/users", nil),
            (.get, "/v1/admin/backups/config", nil), (.post, "/v1/admin/pairing-codes", ByteBuffer(string: "{}")),
        ]
        try await publicApp().test(.router) { client in
            for (method, uri, body) in routes {
                for token in [self.adminDevice!, allScopes] {
                    try await client.execute(uri: uri, method: method, headers: self.bearer(token), body: body) {
                        XCTAssertEqual($0.status, .notFound, "\(method) \(uri)")
                    }
                }
            }
            try await client.execute(uri: "/v1/library", method: .get, headers: self.bearer(allScopes)) {
                XCTAssertEqual($0.status, .unauthorized)
                XCTAssertTrue(String(buffer: $0.body).contains("Use a paired device"))
            }
            try await client.execute(uri: "/v1/library", method: .get, headers: self.bearer(self.adminDevice!)) {
                XCTAssertEqual($0.status, .ok)
            }
        }
        try await buildApplication(store: store, configuration: .init()).test(.router) { client in
            for (method, uri, body) in routes {
                try await client.execute(uri: uri, method: method, headers: self.bearer(self.adminDevice!), body: body) {
                    XCTAssertTrue([HTTPResponse.Status.ok, .created].contains($0.status), "\(method) \(uri)")
                }
            }
        }
    }

    func testPublicHealthReturnsIdentityPinAndPublicURL() async throws {
        let url = URL(string: "https://games.example.com")!
        PairingEnvironment.current = PairingEnvironment(
            urls: [URL(string: "https://100.101.1.2:8487")!], certificateSHA256: "identity-pin")
        try await publicApp(publicURL: url).test(.router) { client in
            try await client.execute(uri: "/v1/health", method: .get) { response in
                XCTAssertEqual(response.status, .ok)
                let health = try SupersEmuJSON.decoder().decode(HealthResponse.self, from: Data(buffer: response.body))
                XCTAssertEqual(health.certificateSHA256, "identity-pin")
                XCTAssertEqual(health.publicURL, url)
                XCTAssertNil(health.urls)
            }
        }
    }

    func testLocalHealthReturnsCurrentPairingURLs() async throws {
        let urls = [URL(string: "https://mini.local:8487")!, URL(string: "https://100.101.1.2:8487")!]
        PairingEnvironment.current = PairingEnvironment(urls: urls, certificateSHA256: "identity-pin")
        try await buildApplication(store: store, configuration: .init()).test(.router) { client in
            try await client.execute(uri: "/v1/health", method: .get) { response in
                XCTAssertEqual(response.status, .ok)
                let health = try SupersEmuJSON.decoder().decode(HealthResponse.self, from: Data(buffer: response.body))
                XCTAssertEqual(health.urls, urls)
            }
        }
    }

    func testPublicRequestToConnectIsApprovedLocallyAndClaimedPublicly() async throws {
        let services = PairingServices(store: store)
        let publicApplication = Application(router: buildRouter(
            store: store, exposure: .publicInternet, certificateSHA256: "identity-pin", pairing: services))
        let localApplication = Application(router: buildRouter(store: store, pairing: services))
        let secret = String(repeating: "11", count: 32)
        var created: PairRequestCreated?

        try await publicApplication.test(.router) { client in
            try await client.execute(uri: "/v1/pair/requests", method: .post,
                                     headers: [.contentType: "application/json", .init("X-Forwarded-For")!: "203.0.113.9"],
                                     body: try self.requestBody()) { response in
                XCTAssertEqual(response.status, .created)
                created = try SupersEmuJSON.decoder().decode(PairRequestCreated.self, from: Data(buffer: response.body))
            }
        }
        let request = try XCTUnwrap(created)

        try await localApplication.test(.router) { client in
            let pending = try await client.execute(uri: "/v1/admin/pair-requests", method: .get,
                                                   headers: self.bearer(self.adminDevice!)) { response in
                XCTAssertEqual(response.status, .ok)
                return try SupersEmuJSON.decoder().decode([PendingPairRequest].self, from: Data(buffer: response.body))
            }
            XCTAssertTrue(pending.contains { $0.id == request.requestID && $0.remoteAddress == "203.0.113.9" })
            try await client.execute(uri: "/v1/admin/pair-requests/\(request.requestID)/approve", method: .post,
                                     headers: [.authorization: "Bearer \(self.adminDevice!)", .contentType: "application/json"],
                                     body: ByteBuffer(string: "{}")) {
                XCTAssertEqual($0.status, .ok)
            }
        }

        try await publicApplication.test(.router) { client in
            try await client.execute(uri: "/v1/pair/requests/\(request.requestID)/claim", method: .post,
                                     headers: [.contentType: "application/json"],
                                     body: ByteBuffer(data: try SupersEmuJSON.encoder().encode(PairRequestClaim(claimSecret: secret)))) { response in
                XCTAssertEqual(response.status, .ok)
                let paired = try SupersEmuJSON.decoder().decode(PairResponse.self, from: Data(buffer: response.body))
                XCTAssertNotNil(try self.store.authenticate(token: paired.token))
            }
        }
    }

    func testPublicBudgetsDoNotExhaustLocalPairingOrPendingRequests() async throws {
        let limiter = PairingRateLimiter(maxFailures: 100, maxGlobalFailures: 2)
        let pairing = PairingService(store: store, limiter: limiter)
        let requests = PairRequestService(store: store, pairing: pairing, maximumPendingGlobally: 1)
        let services = PairingServices(pairing: pairing, requests: requests)
        let publicApplication = Application(router: buildRouter(
            store: store, exposure: .publicInternet, pairing: services))
        let localApplication = Application(router: buildRouter(store: store, pairing: services))

        try await publicApplication.test(.router) { client in
            for address in ["203.0.113.1", "203.0.113.2"] {
                try await client.execute(uri: "/v1/pair", method: .post,
                                         headers: [.contentType: "application/json", .init("X-Forwarded-For")!: address],
                                         body: try self.badPair("999999")) {
                    XCTAssertEqual($0.status, .unauthorized)
                }
            }
            try await client.execute(uri: "/v1/pair", method: .post,
                                     headers: [.contentType: "application/json", .init("X-Forwarded-For")!: "203.0.113.3"],
                                     body: try self.badPair("999999")) {
                XCTAssertEqual($0.status, .tooManyRequests)
            }
        }

        let auth = try XCTUnwrap(store.authenticate(token: adminDevice))
        let code = try pairing.createCode(for: nil, caller: auth)
        try await localApplication.test(.router) { client in
            try await client.execute(uri: "/v1/pair", method: .post, headers: [.contentType: "application/json"],
                                     body: ByteBuffer(data: try SupersEmuJSON.encoder().encode(
                                        PairRequest(code: code.code, deviceName: "LAN device", platform: "iOS")))) {
                XCTAssertEqual($0.status, .ok)
            }
        }

        var publicRequest: PairRequestCreated?
        try await publicApplication.test(.router) { client in
            try await client.execute(uri: "/v1/pair/requests", method: .post,
                                     headers: [.contentType: "application/json", .init("X-Forwarded-For")!: "203.0.113.4"],
                                     body: try self.requestBody()) {
                XCTAssertEqual($0.status, .created)
                publicRequest = try SupersEmuJSON.decoder().decode(PairRequestCreated.self, from: Data(buffer: $0.body))
            }
            try await client.execute(uri: "/v1/pair/requests", method: .post,
                                     headers: [.contentType: "application/json", .init("X-Forwarded-For")!: "203.0.113.5"],
                                     body: try self.requestBody()) {
                XCTAssertEqual($0.status, .tooManyRequests)
            }
        }
        XCTAssertNotNil(publicRequest)
        try await localApplication.test(.router) { client in
            try await client.execute(uri: "/v1/pair/requests", method: .post,
                                     headers: [.contentType: "application/json"], body: try self.requestBody()) {
                XCTAssertEqual($0.status, .created)
            }
        }
    }

    func testExpiredAndReusedPairingCodesFailOnPublicRouter() async throws {
        let clock = TestClock(Date(timeIntervalSince1970: 1_800_000_000))
        let pairing = PairingService(store: store, now: { clock.now })
        let services = PairingServices(pairing: pairing, requests: PairRequestService(store: store, pairing: pairing))
        let application = Application(router: buildRouter(store: store, exposure: .publicInternet, pairing: services))
        let auth = try XCTUnwrap(store.authenticate(token: adminDevice))
        let expired = try pairing.createCode(for: nil, caller: auth)
        clock.now = clock.now.addingTimeInterval(PairingService.codeLifetime + 1)
        let reusable = try pairing.createCode(for: nil, caller: auth)

        try await application.test(.router) { client in
            try await client.execute(uri: "/v1/pair", method: .post, headers: [.contentType: "application/json"],
                                     body: ByteBuffer(data: try SupersEmuJSON.encoder().encode(
                                        PairRequest(code: expired.code, deviceName: "Expired device", platform: "iOS")))) {
                XCTAssertEqual($0.status, .unauthorized)
            }
            try await client.execute(uri: "/v1/pair", method: .post, headers: [.contentType: "application/json"],
                                     body: ByteBuffer(data: try SupersEmuJSON.encoder().encode(
                                        PairRequest(code: reusable.code, deviceName: "Public device", platform: "iOS")))) {
                XCTAssertEqual($0.status, .ok)
            }
            try await client.execute(uri: "/v1/pair", method: .post, headers: [.contentType: "application/json"],
                                     body: ByteBuffer(data: try SupersEmuJSON.encoder().encode(
                                        PairRequest(code: reusable.code, deviceName: "Public device", platform: "iOS")))) {
                XCTAssertEqual($0.status, .unauthorized)
            }
        }
    }

    func testPublicPairingRateLimitUsesRightmostValidatedForwardedAddress() async throws {
        let fields: (String) -> HTTPFields = { address in
            [.contentType: "application/json", .init("X-Forwarded-For")!: "1.2.3.4, \(address)"]
        }
        try await publicApp().test(.router) { client in
            for _ in 0..<5 {
                try await client.execute(uri: "/v1/pair", method: .post, headers: fields("203.0.113.5"),
                                         body: try badPair()) { XCTAssertEqual($0.status, .unauthorized) }
            }
            try await client.execute(uri: "/v1/pair", method: .post, headers: fields("203.0.113.5"),
                                     body: try badPair()) { XCTAssertEqual($0.status, .tooManyRequests) }
            try await client.execute(uri: "/v1/pair", method: .post, headers: fields("203.0.113.6"),
                                     body: try badPair()) { XCTAssertEqual($0.status, .unauthorized) }
        }
    }

    func testPublicJSONBodyLimitIs64KiBAndLocalIgnoresForwardedAddress() async throws {
        let oversize = ByteBuffer(string: #"{"deviceName":"\#(String(repeating: "x", count: 200 * 1024))","platform":"iOS","claimHash":"x"}"#)
        try await publicApp().test(.router) { client in
            try await client.execute(uri: "/v1/pair/requests", method: .post,
                                     headers: [.contentType: "application/json"], body: oversize) {
                XCTAssertEqual($0.status, .contentTooLarge)
            }
        }
        try await buildApplication(store: store, configuration: .init()).test(.router) { client in
            for index in 0..<6 {
                let headers: HTTPFields = [.contentType: "application/json",
                    .init("X-Forwarded-For")!: "203.0.113.\(index + 1)"]
                try await client.execute(uri: "/v1/pair", method: .post, headers: headers,
                                         body: try badPair()) {
                    XCTAssertEqual($0.status, index == 5 ? .tooManyRequests : .unauthorized)
                }
            }
        }
    }

    func testPublicAccessConfigurationDefaultsOffAndValidates() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        XCTAssertNil(try PublicAccessConfiguration.load(root: root))
        let config = try PublicAccessConfiguration(enabled: true, publicURL: URL(string: "https://games.example.com")!, listenPort: 8489)
        try JSONEncoder().encode(config).write(to: root.appendingPathComponent("public-access.json"))
        XCTAssertEqual(try PublicAccessConfiguration.load(root: root), config)
        let override = try PublicAccessConfiguration.load(root: root, publicURL: URL(string: "https://new.example.com")!, listenPort: 8490)
        XCTAssertEqual(override?.publicURL.host, "new.example.com")
        XCTAssertEqual(override?.listenPort, 8490)
        XCTAssertNil(try ServerLauncher.makeApplication(store: store, options: ServerRunOptions()).publicApplication)
        var enabled = ServerRunOptions()
        enabled.publicAccess = config
        let result = try ServerLauncher.makeApplication(store: store, options: enabled)
        XCTAssertNotNil(result.publicApplication)
        XCTAssertEqual(ServerLauncher.publicListenHost, "127.0.0.1")
    }

    func testInvalidPublicAccessFileDisablesURLAndPortOverrides() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("{".utf8).write(to: root.appendingPathComponent("public-access.json"))

        var options = ServerRunOptions()
        options.publicURL = URL(string: "https://games.example.com")
        options.publicPort = 8490
        let resolved = ServerLauncher.resolvePublicAccess(root: root, options: options, logger: Logger(label: "test"))
        XCTAssertNil(resolved.publicAccess)
        XCTAssertNil(resolved.publicURL)
        XCTAssertNil(resolved.publicPort)

        let result = try ServerLauncher.makeApplication(store: store, options: resolved)
        XCTAssertNil(result.publicApplication)
        XCTAssertNil(result.environment.publicURL)
    }
}

final class TestBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value
    init(_ value: Value) { stored = value }
    var value: Value { lock.withLock { stored } }
    func update(_ body: (inout Value) -> Void) { lock.withLock { body(&stored) } }
}

extension NetworkTests {
    func testPublicWebPKIUsesSystemTrustOnlyForConfiguredHostAndPort() throws {
        let endpoints = WebPKIEndpoint.keys(for: URL(string: "https://games.example.com")!)
        let authMethod = NSURLAuthenticationMethodServerTrust
        XCTAssertEqual(PinnedCertificateDelegate.decision(authenticationMethod: authMethod, trust: nil,
                                                          pin: "wrong-pin", host: "GAMES.EXAMPLE.COM",
                                                          port: 443, webPKIEndpoints: endpoints), .defaultHandling)
        XCTAssertEqual(PinnedCertificateDelegate.decision(authenticationMethod: authMethod, trust: nil,
                                                          pin: "wrong-pin", host: "games.example.com",
                                                          port: 8487, webPKIEndpoints: endpoints), .reject)
        XCTAssertEqual(PinnedCertificateDelegate.decision(authenticationMethod: authMethod, trust: nil,
                                                          pin: "wrong-pin", host: "other.example.com",
                                                          port: 443, webPKIEndpoints: endpoints), .reject)
    }

    func testPublicProfileTrustAndCandidateOrder() {
        let lan = URL(string: "https://mini.local:8487")!
        let internet = URL(string: "https://games.example.com")!
        let profile = ServerProfile(serverName: "Mini", urls: [lan], certificateSHA256: nil, publicURL: internet)
        XCTAssertTrue(profile.isTrustedTransport(internet))
        XCTAssertFalse(profile.isTrustedTransport(URL(string: "https://games.example.com:8487")!))
        XCTAssertFalse(profile.isTrustedTransport(URL(string: "https://other.example.com")!))
        XCTAssertEqual(ServerConnection.candidateOrder(urls: [lan], lastGood: nil, publicURL: internet), [lan, internet])
        XCTAssertEqual(ServerConnection.candidateOrder(urls: [lan], lastGood: internet, publicURL: internet), [internet, lan])
        XCTAssertEqual(PairingLinkParser.publicURLCandidate(fromAddress: "games.example.com"), internet)
        XCTAssertNil(PairingLinkParser.publicURLCandidate(fromAddress: "192.0.2.4"))
        XCTAssertNil(PairingLinkParser.publicURLCandidate(fromAddress: "mini.local"))
        XCTAssertNil(PairingLinkParser.publicURLCandidate(fromAddress: "games.example.com:8487"))
    }

    func testOldPairingPayloadWithoutPublicURLStillDecodes() throws {
        let json = #"{"serverName":"Mini","urls":["https://mini.local:8487"],"certificateSHA256":"ab","code":"123456"}"#
        let payload = try SupersEmuJSON.decoder().decode(PairingPayload.self, from: Data(json.utf8))
        XCTAssertNil(payload.publicURL)
    }

    func testTokensOnlyTravelOverPinnedHTTPS() {
        let pinned = ServerProfile(serverName: "Mini", urls: [], certificateSHA256: String(repeating: "a", count: 64))
        XCTAssertTrue(pinned.isTrustedTransport(URL(string: "https://mini.local:8487")!))
        XCTAssertFalse(pinned.isTrustedTransport(URL(string: "http://mini.local:8487")!))
        let unpinned = ServerProfile(serverName: "Mini", urls: [], certificateSHA256: nil)
        XCTAssertFalse(unpinned.isTrustedTransport(URL(string: "https://mini.local:8487")!))
        XCTAssertTrue(ServerProfile(serverName: "Mini", urls: [], certificateSHA256: nil, allowsInsecureTransport: true)
            .isTrustedTransport(URL(string: "http://127.0.0.1:8487")!))
    }

    func testTokenAccountSurvivesRename() {
        var profile = ServerProfile(serverName: "Old Mini", urls: [], certificateSHA256: nil)
        let account = profile.tokenAccount
        profile.serverName = "New Mini"
        XCTAssertEqual(profile.tokenAccount, account)
    }

    func testBonjourResolveTimesOut() async throws {
        let server = DiscoveredServer(name: "nobody-\(UUID().uuidString.prefix(8))", txt: [:],
                                      endpoint: .service(name: "nobody", type: SupersEmuBonjour.serviceType, domain: "local.", interface: nil))
        let start = Date()
        do {
            _ = try await ServerBrowser.resolve(server, timeout: 1)
            XCTFail("resolved a service that doesn't exist")
        } catch {}
        XCTAssertLessThan(Date().timeIntervalSince(start), 5)
    }

    func testBonjourResolveOutcomeWaitsForReadyAndRejectsLinkLocalIPv6() throws {
        let waitingError = NWError.posix(.ENETUNREACH)
        if case .keepWaiting(let error) = ResolveOutcome.next(
            state: .waiting(waitingError), remoteEndpoint: nil, scheme: "https"
        ) {
            XCTAssertEqual(error, waitingError)
        } else {
            XCTFail("waiting must keep resolving")
        }

        let failedError = NWError.posix(.ECONNREFUSED)
        if case .failed(let error) = ResolveOutcome.next(
            state: .failed(failedError), remoteEndpoint: nil, scheme: "https"
        ) {
            XCTAssertEqual(error as? NWError, failedError)
        } else {
            XCTFail("failed must be final")
        }

        let linkLocal = NWEndpoint.hostPort(
            host: .ipv6(IPv6Address("fe80::1")!),
            port: NWEndpoint.Port(rawValue: 8487)!
        )
        if case .failed(let error) = ResolveOutcome.next(state: .ready, remoteEndpoint: linkLocal, scheme: "https") {
            XCTAssertEqual((error as? URLError)?.code, .cannotFindHost)
        } else {
            XCTFail("link-local IPv6 must not be returned without its interface scope")
        }
    }

    func testBonjourResolveFallsBackToDualStackUnlessWaitingForLocalNetworkPermission() {
        let refused = NWError.posix(.ECONNREFUSED)
        let unreachable = NWError.posix(.ENETUNREACH)
        let denied = NWError.dns(-65_570)

        XCTAssertTrue(ResolveOutcome.shouldFallBack(after: .connection(refused, waitingError: nil)))
        XCTAssertTrue(ResolveOutcome.shouldFallBack(after: .timedOut(nil)))
        XCTAssertTrue(ResolveOutcome.shouldFallBack(after: .timedOut(unreachable)))
        XCTAssertFalse(ResolveOutcome.shouldFallBack(after: .connection(denied, waitingError: nil)))
        XCTAssertFalse(ResolveOutcome.shouldFallBack(after: .timedOut(denied)))
    }
}

extension NetworkTests {
    func testTrustedResolveSkipsPlainHTTP() async throws {
        let http = URL(string: "http://mini.local:8487")!, https = URL(string: "https://mini.local:8488")!
        let connection = ServerConnection(profile: ServerProfile(serverName: "Mini", urls: [http, https],
                                                                 certificateSHA256: String(repeating: "a", count: 64)),
                                          tokenStore: InMemoryTokenStore())
        let resolved = try await connection.resolveURL(trustedOnly: true, probe: { _ in })
        XCTAssertEqual(resolved, https)
        let lastGood = await connection.profile.lastGoodURL
        XCTAssertEqual(lastGood, https)
    }

    func testLegacyProfileDecodes() throws {
        let json = #"{"serverName":"Mini","urls":["https://mini.local:8487"],"certificateSHA256":"AB:CD"}"#
        let profile = try SupersEmuJSON.decoder().decode(ServerProfile.self, from: Data(json.utf8))
        XCTAssertEqual(profile.tokenAccount, "abcd")
        XCTAssertFalse(profile.allowsInsecureTransport)
        XCTAssertNil(profile.publicURL)
        let roundTrip = try SupersEmuJSON.decoder().decode(ServerProfile.self, from: SupersEmuJSON.encoder().encode(profile))
        XCTAssertEqual(roundTrip, profile)
    }

    func testOldHealthResponseWithoutPublicAccessFieldsDecodes() throws {
        let json = #"{"status":"ok","serverName":"Mini","serverVersion":"0.1.0","apiVersion":"v1","libraryRevision":null}"#
        let health = try SupersEmuJSON.decoder().decode(HealthResponse.self, from: Data(json.utf8))
        XCTAssertNil(health.certificateSHA256)
        XCTAssertNil(health.publicURL)
        XCTAssertNil(health.urls)
    }

    func testPairingMatchCodeUsesIdentityPinFromHealth() throws {
        let identity = try TLSIdentity.generate(commonName: "Mini", dnsNames: ["localhost"])
        let health = HealthResponse(status: "ok", serverName: "Mini", serverVersion: "0.1.0",
                                    certificateSHA256: identity.sha256)
        let requestID = UUID()
        let claimHash = String(repeating: "ab", count: 32)
        XCTAssertEqual(
            PairingMatchCode.compute(certificateSHA256: try XCTUnwrap(health.certificateSHA256),
                                     requestID: requestID, claimHash: claimHash),
            PairingMatchCode.compute(certificateSHA256: identity.sha256,
                                     requestID: requestID, claimHash: claimHash))
    }
}

extension NetworkTests {
    func testPinnedDelegateRefusesRedirects() {
        let delegate = PinnedCertificateDelegate(certificateSHA256: nil)
        let url = URL(string: "https://mini.local:8487/v1/me")!
        let task = URLSession.shared.dataTask(with: url)
        let response = HTTPURLResponse(url: url, statusCode: 302, httpVersion: nil, headerFields: ["Location": "http://evil/"])!
        let followed = LockedBox<URLRequest?>(URLRequest(url: url))
        delegate.urlSession(URLSession.shared, task: task, willPerformHTTPRedirection: response,
                            newRequest: URLRequest(url: URL(string: "http://evil/")!)) { followed.value = $0 }
        XCTAssertNil(followed.value)
    }

    func testTrustOnFirstUseLocksToFirstCertificate() {
        let delegate = PinnedCertificateDelegate(certificateSHA256: nil, trustOnFirstUse: true, expectedHost: "mini.local")
        XCTAssertTrue(delegate.acceptFirstUse("aa"))
        XCTAssertTrue(delegate.acceptFirstUse("aa"))
        XCTAssertFalse(delegate.acceptFirstUse("bb"))
        XCTAssertEqual(delegate.observedSHA256, "aa")
    }

    func testTrustOnFirstUseNeedsTypedHostAndNoPin() {
        XCTAssertTrue(PinnedCertificateDelegate(certificateSHA256: nil, trustOnFirstUse: true, expectedHost: "Mini.local").trustOnFirstUse)
        XCTAssertFalse(PinnedCertificateDelegate(certificateSHA256: nil, trustOnFirstUse: true).trustOnFirstUse)
        XCTAssertFalse(PinnedCertificateDelegate(certificateSHA256: "ab", trustOnFirstUse: true, expectedHost: "mini").trustOnFirstUse)
    }
}

private final class LockedBox<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: T
    init(_ value: T) { stored = value }
    var value: T { get { lock.withLock { stored } } set { lock.withLock { stored = newValue } } }
}
