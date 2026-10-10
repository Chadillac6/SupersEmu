import Foundation
import SupersEmuKit
@testable import SupersEmuServerCore
import XCTest

/// Signed in, but the app knows the server is unreachable (e.g. away from home with Tailscale off).
final class KnownOfflineProvider: SaveSyncServerProvider, @unchecked Sendable {
    private let lock = NSLock()
    private var client: APIClient?
    private var reachable = false
    init(_ client: APIClient?) { self.client = client }
    func setReachable(_ value: Bool) { lock.withLock { reachable = value } }
    func currentClient() async -> APIClient? { lock.withLock { client } }
    func isReachable() async -> Bool { lock.withLock { reachable } }
}

extension SaveSyncEngineTests {
    func testKnownOfflineSavesQueueWithoutWaitingAndSyncWhenBack() async throws {
        try await withServer { server in
            let phone = try self.device("Chad's iPhone", server: server)
            let client = await phone.provider.currentClient()
            let provider = KnownOfflineProvider(client)
            let engine = SaveSyncEngine(directory: phone.engine.directory, provider: provider)

            // Launching a downloaded game offline doesn't wait on network timeouts.
            let started = Date()
            let outcomes = await engine.prepare([phone.file(self.auto)])
            XCTAssertEqual(outcomes[self.auto.key], .localOnly)
            XCTAssertLessThan(Date().timeIntervalSince(started), 1)

            try phone.write(self.auto, "played-offline")
            let queued = await engine.enqueueUpload(phone.file(self.auto))
            XCTAssertTrue(queued, "offline saves are queued")
            let offline = await engine.flush()
            XCTAssertEqual(offline.uploaded, 0)
            XCTAssertEqual(offline.remaining, 1)
            XCTAssertNotNil(offline.offlineError)
            let waiting = await engine.status(of: self.auto)
            XCTAssertEqual(waiting, .waitingToUpload)
            let none = try await client!.saves(gameID: self.game).revisions
            XCTAssertTrue(none.isEmpty)

            // Back online (the app flushes after each successful refresh).
            provider.setReachable(true)
            let report = await engine.flush()
            XCTAssertEqual(report.uploaded, 1)
            XCTAssertEqual(report.remaining, 0)
            let synced = await engine.status(of: self.auto)
            XCTAssertEqual(synced, .synced)
            let revisions = try await client!.saves(gameID: self.game).revisions
            XCTAssertEqual(revisions.map(\.sha256), [SaveSyncEngine.sha256(Data("played-offline".utf8))])
        }
    }
}
