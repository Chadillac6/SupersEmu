import Foundation

/// How a paired client currently reaches its server.
public enum ConnectionRoute: String, Codable, Sendable, Equatable {
    case home
    case tailscale

    /// Tailscale addresses: MagicDNS (`*.ts.net`), the CGNAT range 100.64.0.0/10 and the `fd7a:115c:a1e0::/48` ULA.
    public static func of(_ url: URL) -> ConnectionRoute {
        guard let host = url.host?.lowercased() else { return .home }
        if host.hasSuffix(".ts.net") || host.hasPrefix("fd7a:115c:a1e0:") { return .tailscale }
        let octets = host.split(separator: ".").compactMap { UInt8($0) }
        if octets.count == 4, octets[0] == 100, (64...127).contains(octets[1]) { return .tailscale }
        return .home
    }
}

public enum ConnectionState: Equatable, Sendable {
    public enum SignedOutReason: Equatable, Sendable {
        /// Never paired, or signed out on this device.
        case notPaired
        /// The server rejected this device's token (revoked, or the server was reset).
        case revoked
    }

    case signedOut(SignedOutReason)
    case connecting
    case connected(ConnectionRoute)
    case unreachable
    case certificateMismatch

    public var isConnected: Bool { if case .connected = self { true } else { false } }
    public var route: ConnectionRoute? { if case .connected(let route) = self { route } else { nil } }
    /// Worth sending a request: connected, or still finding out.
    public var mayReachServer: Bool { isConnected || self == .connecting }

    public struct Message: Equatable, Sendable {
        public var title: String
        public var detail: String
        public var symbol: String
        public var canRetry: Bool
    }

    /// Banner copy; nil when there's nothing to say (connected, or never paired).
    public func message(serverName: String) -> Message? {
        switch self {
        case .connected, .signedOut(.notPaired), .connecting:
            return nil
        case .unreachable:
            return Message(title: "Can't reach \(serverName). Check that it's on, or turn on Tailscale when you're away.",
                           detail: "Downloaded games still play, and saves sync when you're back. Retrying automatically.",
                           symbol: "wifi.slash", canRetry: true)
        case .certificateMismatch:
            return Message(title: "\(serverName) presented a different security certificate.",
                           detail: "If you reinstalled or restored the server, pair this device again. Otherwise, don't trust this network.",
                           symbol: "lock.trianglebadge.exclamationmark", canRetry: true)
        case .signedOut(.revoked):
            return Message(title: "This device was signed out by \(serverName).",
                           detail: "Pair it again from Settings to see your library. Downloaded games still play.",
                           symbol: "person.crop.circle.badge.xmark", canRetry: false)
        }
    }
}

public enum ConnectionFailure: Equatable, Sendable {
    case unreachable
    case certificateMismatch
    case signedOut

    /// `certificateRejected` is true when the pinning delegate refused the server's certificate during the request.
    public static func classify(_ error: Error, certificateRejected: Bool) -> ConnectionFailure {
        if certificateRejected { return .certificateMismatch }
        if case APIClientError.http(status: 401, _) = error { return .signedOut }
        if let error = error as? URLError {
            switch error.code {
            case .serverCertificateUntrusted, .serverCertificateHasUnknownRoot, .serverCertificateHasBadDate, .serverCertificateNotYetValid:
                return .certificateMismatch
            default:
                break
            }
        }
        return .unreachable
    }
}

/// Connection state machine for a paired client, with exponential retry backoff. Pure, so it's unit tested.
public struct ConnectionMonitor: Equatable, Sendable {
    public private(set) var state: ConnectionState
    public private(set) var consecutiveFailures = 0

    public static let maxRetryDelay: TimeInterval = 60
    public static let maxCertificateRetryDelay: TimeInterval = 300

    public init(paired: Bool) { state = paired ? .connecting : .signedOut(.notPaired) }

    public mutating func paired() {
        state = .connecting
        consecutiveFailures = 0
    }

    public mutating func signedOut() {
        state = .signedOut(.notPaired)
        consecutiveFailures = 0
    }

    public mutating func succeeded(via url: URL) {
        state = .connected(ConnectionRoute.of(url))
        consecutiveFailures = 0
    }

    public mutating func failed(_ failure: ConnectionFailure) {
        guard state != .signedOut(.notPaired) else { return }
        switch failure {
        case .unreachable: state = .unreachable
        case .certificateMismatch: state = .certificateMismatch
        case .signedOut: state = .signedOut(.revoked)
        }
        consecutiveFailures += 1
    }

    /// Wi-Fi joined, Tailscale toggled, etc.: retry right away instead of waiting out the backoff.
    public mutating func networkChanged() { consecutiveFailures = 0 }

    /// Delay before the next automatic retry; nil when there's nothing to retry.
    public var retryDelay: TimeInterval? {
        switch state {
        case .unreachable: return Self.backoff(consecutiveFailures, cap: Self.maxRetryDelay)
        case .certificateMismatch: return Self.backoff(consecutiveFailures, cap: Self.maxCertificateRetryDelay)
        case .connected, .connecting, .signedOut: return nil
        }
    }

    /// 2, 4, 8, 16, 32, 60, 60… seconds.
    public static func backoff(_ failures: Int, cap: TimeInterval) -> TimeInterval {
        min(cap, 2 * pow(2, Double(max(0, failures - 1))))
    }
}
