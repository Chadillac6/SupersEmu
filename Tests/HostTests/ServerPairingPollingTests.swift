import Foundation
import XCTest
import SupersEmuKit

final class ServerPairingPollingTests: XCTestCase {
    func testPollingCadenceAndImmediateInitialRefresh() {
        let start = Date(timeIntervalSince1970: 100)
        XCTAssertTrue(ServerPollingCadence.shouldRefreshStatus(lastRefreshAt: nil, now: start))
        XCTAssertFalse(ServerPollingCadence.shouldRefreshStatus(lastRefreshAt: start, now: start.addingTimeInterval(9.9)))
        XCTAssertTrue(ServerPollingCadence.shouldRefreshStatus(lastRefreshAt: start, now: start.addingTimeInterval(10)))
        XCTAssertEqual(ServerPollingCadence.statusRefreshInterval, 10)
        XCTAssertEqual(ServerPollingCadence.pairRequestRefreshInterval, 3)
    }

    func testPairRequestsStayGroupedBySourceAndEntriesAreDistinct() {
        let duplicateID = UUID()
        let daemonRequest = request(id: duplicateID, name: "Daemon device")
        let sessionRequest = request(id: duplicateID, name: "Session device")
        let grouped = ["daemon": [daemonRequest], "session": [sessionRequest]]

        XCTAssertEqual(PairRequestSourceGrouping.requests(for: "daemon", in: grouped), [daemonRequest])
        XCTAssertEqual(PairRequestSourceGrouping.requests(for: "session", in: grouped), [sessionRequest])
        XCTAssertEqual(
            PairRequestSourceGrouping.entries(from: grouped).map(\.id),
            ["daemon:\(duplicateID.uuidString)", "session:\(duplicateID.uuidString)"]
        )
        XCTAssertTrue(PairRequestSourceGrouping.hasMultipleSourcesWithRequests(in: grouped))
        XCTAssertFalse(PairRequestSourceGrouping.hasMultipleSourcesWithRequests(in: ["daemon": [daemonRequest], "session": []]))
    }

    func testApprovedCredentialDispositionDependsOnFlowOwnership() {
        let identity = PairingFlowIdentity()
        XCTAssertEqual(
            PairingApprovalDisposition.forCurrentOwner(flowIdentity: identity, currentIdentity: identity),
            .saveCredential
        )
        XCTAssertEqual(
            PairingApprovalDisposition.forCurrentOwner(flowIdentity: identity, currentIdentity: PairingFlowIdentity()),
            .revokeDevice
        )
        XCTAssertEqual(
            PairingApprovalDisposition.forCurrentOwner(flowIdentity: identity, currentIdentity: nil),
            .revokeDevice
        )
    }

    private func request(id: UUID, name: String) -> PendingPairRequest {
        PendingPairRequest(
            id: id, deviceName: name, platform: "ios", remoteAddress: "192.0.2.1",
            matchCode: "123 456", createdAt: Date(timeIntervalSince1970: 100),
            expiresAt: Date(timeIntervalSince1970: 400)
        )
    }
}
