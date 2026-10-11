import Foundation

public enum ServerPollingCadence {
    public static let statusRefreshInterval: TimeInterval = 10
    public static let pairRequestRefreshInterval: TimeInterval = 3

    public static func shouldRefreshStatus(lastRefreshAt: Date?, now: Date) -> Bool {
        guard let lastRefreshAt else { return true }
        return now.timeIntervalSince(lastRefreshAt) >= statusRefreshInterval
    }
}

public struct PairRequestSourceEntry: Equatable, Sendable, Identifiable {
    public let source: String
    public let request: PendingPairRequest
    public var id: String { "\(source):\(request.id.uuidString)" }

    public init(source: String, request: PendingPairRequest) {
        self.source = source
        self.request = request
    }
}

public enum PairRequestSourceGrouping {
    public static func requests(
        for source: String,
        in requestsBySource: [String: [PendingPairRequest]]
    ) -> [PendingPairRequest] {
        requestsBySource[source] ?? []
    }

    public static func entries(
        from requestsBySource: [String: [PendingPairRequest]]
    ) -> [PairRequestSourceEntry] {
        requestsBySource.keys.sorted().flatMap { source in
            requests(for: source, in: requestsBySource).map { PairRequestSourceEntry(source: source, request: $0) }
        }
    }

    public static func hasMultipleSourcesWithRequests(in requestsBySource: [String: [PendingPairRequest]]) -> Bool {
        requestsBySource.values.filter { !$0.isEmpty }.count > 1
    }
}

public enum PairingApprovalDisposition: Equatable, Sendable {
    case saveCredential
    case revokeDevice

    public static func forCurrentOwner(
        flowIdentity: PairingFlowIdentity,
        currentIdentity: PairingFlowIdentity?
    ) -> Self {
        flowIdentity.matches(current: currentIdentity) ? .saveCredential : .revokeDevice
    }
}
