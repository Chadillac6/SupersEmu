import Foundation
import SupersEmuKit
@testable import SupersEmuServerCore
import XCTest

final class ConnectionStateTests: XCTestCase {
    let lan = URL(string: "https://192.168.1.20:8487")!
    let tailnet = URL(string: "https://mac-mini.tail1234.ts.net:8487")!

    func testRouteClassification() {
        XCTAssertEqual(ConnectionRoute.of(lan), .home)
        XCTAssertEqual(ConnectionRoute.of(URL(string: "https://mac-mini.local:8487")!), .home)
        XCTAssertEqual(ConnectionRoute.of(tailnet), .tailscale)
        XCTAssertEqual(ConnectionRoute.of(URL(string: "https://100.101.102.103:8487")!), .tailscale)
        XCTAssertEqual(ConnectionRoute.of(URL(string: "https://100.12.0.1:8487")!), .home, "outside 100.64.0.0/10")
        XCTAssertEqual(ConnectionRoute.of(URL(string: "https://[fd7a:115c:a1e0::1]:8487")!), .tailscale)
    }

    func testTransitionsAndBackoff() {
        var monitor = ConnectionMonitor(paired: false)
        XCTAssertEqual(monitor.state, .signedOut(.notPaired))
        monitor.failed(.unreachable)
        XCTAssertEqual(monitor.state, .signedOut(.notPaired), "nothing to reach when not paired")
        XCTAssertNil(monitor.retryDelay)

        monitor.paired()
        XCTAssertEqual(monitor.state, .connecting)
        monitor.succeeded(via: lan)
        XCTAssertEqual(monitor.state, .connected(.home))
        XCTAssertNil(monitor.retryDelay)

        var delays: [TimeInterval] = []
        for _ in 0..<7 {
            monitor.failed(.unreachable)
            delays.append(monitor.retryDelay!)
        }
        XCTAssertEqual(monitor.state, .unreachable)
        XCTAssertEqual(delays, [2, 4, 8, 16, 32, 60, 60])

        monitor.networkChanged()
        monitor.failed(.unreachable)
        XCTAssertEqual(monitor.retryDelay, 2, "a network change restarts the backoff")

        monitor.succeeded(via: tailnet)
        XCTAssertEqual(monitor.state, .connected(.tailscale))
        XCTAssertEqual(monitor.consecutiveFailures, 0)

        monitor.failed(.certificateMismatch)
        XCTAssertEqual(monitor.state, .certificateMismatch)
        XCTAssertEqual(monitor.retryDelay, 2)

        monitor.failed(.signedOut)
        XCTAssertEqual(monitor.state, .signedOut(.revoked))
        XCTAssertNil(monitor.retryDelay, "a revoked device needs pairing, not retries")

        monitor.signedOut()
        XCTAssertEqual(monitor.state, .signedOut(.notPaired))
    }

    func testFailureClassification() {
        XCTAssertEqual(ConnectionFailure.classify(APIClientError.http(status: 401, message: nil), certificateRejected: false), .signedOut)
        XCTAssertEqual(ConnectionFailure.classify(APIClientError.http(status: 500, message: nil), certificateRejected: false), .unreachable)
        XCTAssertEqual(ConnectionFailure.classify(URLError(.cannotConnectToHost), certificateRejected: false), .unreachable)
        XCTAssertEqual(ConnectionFailure.classify(URLError(.timedOut), certificateRejected: false), .unreachable)
        // A refused pin surfaces as a cancelled request; the delegate's rejection count tells it apart.
        XCTAssertEqual(ConnectionFailure.classify(URLError(.cancelled), certificateRejected: true), .certificateMismatch)
        XCTAssertEqual(ConnectionFailure.classify(URLError(.serverCertificateUntrusted), certificateRejected: false), .certificateMismatch)
    }

    func testMessagesAreActionable() {
        XCTAssertNil(ConnectionState.connected(.home).message(serverName: "Mac mini"))
        XCTAssertNil(ConnectionState.signedOut(.notPaired).message(serverName: "Mac mini"))
        let unreachable = ConnectionState.unreachable.message(serverName: "Chad's Mac mini")!
        XCTAssertEqual(unreachable.title, "Can't reach Chad's Mac mini. Check that it's on, or turn on Tailscale when you're away.")
        XCTAssertTrue(unreachable.canRetry)
        XCTAssertTrue(ConnectionState.certificateMismatch.message(serverName: "Mac mini")!.detail.contains("pair this device again"))
        XCTAssertFalse(ConnectionState.signedOut(.revoked).message(serverName: "Mac mini")!.canRetry)
    }

    /// A real pinned HTTPS server presenting a different certificate is reported as a mismatch, not as offline.
    func testPinnedSessionCountsRejections() async throws {
        let delegate = PinnedCertificateDelegate(certificateSHA256: String(repeating: "0", count: 64))
        XCTAssertEqual(delegate.rejectionCount, 0)
        let store = try ServerStore.inMemory()
        var options = ServerRunOptions()
        options.hostname = "127.0.0.1"
        options.port = Int.random(in: 40_000..<50_000)
        options.bonjour = false
        let launched = store
        let server = Task { try await ServerLauncher.run(store: launched, options: options) }
        defer { server.cancel() }
        let session = URLSession(configuration: .ephemeral, delegate: delegate, delegateQueue: nil)
        let client = APIClient(baseURL: URL(string: "https://127.0.0.1:\(options.port)")!, token: nil, session: session)
        var failure: ConnectionFailure?
        for _ in 0..<50 {
            let before = delegate.rejectionCount
            do {
                _ = try await client.health()
                return XCTFail("a wrong pin must not connect")
            } catch {
                let classified = ConnectionFailure.classify(error, certificateRejected: delegate.rejectionCount != before)
                if classified == .certificateMismatch { failure = classified; break }
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTAssertEqual(failure, .certificateMismatch)
    }
}
