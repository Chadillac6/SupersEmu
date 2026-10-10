import Foundation
import Hummingbird
import NIOCore
import Security
import SupersEmuKit
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
        let (portStream, portContinuation) = AsyncStream.makeStream(of: Int.self)
        let (application, environment) = try ServerLauncher.makeApplication(store: store, options: options) { channel in
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
        let tailscale = URL(string: "https://mac-mini.tail1234.ts.net:8487")!
        let changes = TestBox<[URL?]>([])
        let connection = ServerConnection(profile: ServerProfile(serverName: "Mini", urls: [lan, tailscale], certificateSHA256: nil),
                                          tokenStore: InMemoryTokenStore(),
                                          onProfileChange: { profile in changes.update { $0.append(profile.lastGoodURL) } })
        let tried = TestBox<[URL]>([])
        let url = try await connection.resolveURL { url in
            tried.update { $0.append(url) }
            if url == lan { throw URLError(.cannotFindHost) }
        }
        XCTAssertEqual(url, tailscale)
        XCTAssertEqual(tried.value, [lan, tailscale])
        XCTAssertEqual(changes.value, [tailscale])
        let candidates = await connection.candidates
        XCTAssertEqual(candidates, [tailscale, lan])

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

    // MARK: LAN / Tailscale URLs and Bonjour

    func testAdvertisedURLsPutLANBeforeTailscale() {
        let urls = LocalNetwork.advertisedURLs(
            scheme: "https", port: 8487, tailscaleHost: "mini.tail1234.ts.net", hostName: "Chads-Mac-mini",
            addresses: [.init(interface: "utun4", address: "100.101.1.2"), .init(interface: "en0", address: "192.168.1.20"),
                        .init(interface: "en1", address: "169.254.3.4"), .init(interface: "en0", address: "192.168.1.20")])
        XCTAssertEqual(urls.map(\.absoluteString), [
            "https://Chads-Mac-mini.local:8487", "https://192.168.1.20:8487",
            "https://mini.tail1234.ts.net:8487", "https://100.101.1.2:8487",
        ])
        XCTAssertTrue(LocalNetwork.isTailscale("100.64.0.1"))
        XCTAssertTrue(LocalNetwork.isTailscale("100.127.255.255"))
        XCTAssertFalse(LocalNetwork.isTailscale("100.128.0.1"))
        XCTAssertFalse(LocalNetwork.isTailscale("10.0.0.1"))
    }

    func testBonjourTXTRoundTripAndURLs() {
        let txt = SupersEmuBonjour.txtRecord(scheme: "https", certificateSHA256: "AB:CD", serverName: "Mac mini")
        XCTAssertEqual(SupersEmuBonjour.decodeTXT(SupersEmuBonjour.encodeTXT(txt)), txt)
        XCTAssertEqual(txt["fp"], "abcd")
        XCTAssertEqual(SupersEmuBonjour.url(scheme: "https", host: "fe80::1%en0", port: 8487)?.absoluteString, "https://[fe80::1]:8487")
        XCTAssertEqual(SupersEmuBonjour.url(scheme: "https", host: "192.168.1.2", port: 8487)?.absoluteString, "https://192.168.1.2:8487")

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

final class TestBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value
    init(_ value: Value) { stored = value }
    var value: Value { lock.withLock { stored } }
    func update(_ body: (inout Value) -> Void) { lock.withLock { body(&stored) } }
}
