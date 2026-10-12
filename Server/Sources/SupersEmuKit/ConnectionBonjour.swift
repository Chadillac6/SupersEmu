import Foundation
import Network

/// `_supersemu._tcp` Bonjour service: the server advertises it, apps browse for it on the LAN.
public enum SupersEmuBonjour {
    public static let serviceType = "_supersemu._tcp"
    public static let domain = "local."

    /// TXT keys: `v` (protocol), `scheme` (`https`/`http`), `fp` (certificate SHA-256), `name` (server name).
    public static func txtRecord(scheme: String, certificateSHA256: String?, serverName: String) -> [String: String] {
        var txt = ["v": "1", "scheme": scheme, "name": serverName]
        if let certificateSHA256 { txt["fp"] = CertificatePin.normalize(certificateSHA256) }
        return txt
    }

    /// DNS-SD TXT wire format: length-prefixed `key=value` strings.
    public static func encodeTXT(_ txt: [String: String]) -> Data {
        var data = Data()
        for (key, value) in txt.sorted(by: { $0.key < $1.key }) {
            let entry = Array("\(key)=\(value)".utf8.prefix(255))
            data.append(UInt8(entry.count))
            data.append(contentsOf: entry)
        }
        return data
    }

    public static func decodeTXT(_ data: Data) -> [String: String] {
        var txt: [String: String] = [:]
        var index = data.startIndex
        while index < data.endIndex {
            let length = Int(data[index])
            index = data.index(after: index)
            guard let end = data.index(index, offsetBy: length, limitedBy: data.endIndex) else { break }
            if let entry = String(data: data[index..<end], encoding: .utf8), !entry.isEmpty {
                let parts = entry.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                txt[String(parts[0]).lowercased()] = parts.count > 1 ? String(parts[1]) : ""
            }
            index = end
        }
        return txt
    }

    /// `https://host:port` with IPv6 bracketed and the interface scope dropped.
    public static func url(scheme: String, host: String, port: Int) -> URL? {
        var host = host.trimmingCharacters(in: .whitespacesAndNewlines)
        if host.hasPrefix("[") && host.hasSuffix("]") {
            host = String(host.dropFirst().dropLast())
        }
        if let percent = host.firstIndex(of: "%") { host = String(host[..<percent]) }
        if host.contains(":") { host = "[\(host)]" }
        return URL(string: "\(scheme)://\(host):\(port)")
    }
}

public struct DiscoveredServer: Sendable, Hashable, Identifiable {
    public var name: String
    public var txt: [String: String]
    public var endpoint: NWEndpoint
    public var id: String { name }

    public init(name: String, txt: [String: String], endpoint: NWEndpoint) {
        self.name = name; self.txt = txt; self.endpoint = endpoint
    }
    public var serverName: String { txt["name"] ?? name }
    public var certificateSHA256: String? { txt["fp"] }
    public var scheme: String { txt["scheme"] ?? "https" }

    public func pairingPayload(at address: URL, code: String) -> PairingPayload {
        PairingPayload(serverName: serverName, urls: [address], certificateSHA256: nil, code: code)
    }

    /// True when this advertisement is the server pinned in `profile`.
    public func matches(_ profile: ServerProfile) -> Bool {
        guard let pin = profile.certificateSHA256, let fp = certificateSHA256 else { return false }
        return CertificatePin.normalize(pin) == fp
    }
}

/// Browses the LAN for SupersEmu servers. Needs `NSLocalNetworkUsageDescription` and `NSBonjourServices` on iOS.
public final class ServerBrowser: @unchecked Sendable {
    private let browser: NWBrowser
    private let queue = DispatchQueue(label: "com.chadillac6.supersemu.bonjour-browser")

    public init() {
        browser = NWBrowser(for: .bonjourWithTXTRecord(type: SupersEmuBonjour.serviceType, domain: nil), using: .tcp)
    }

    /// Emits the full set of servers each time it changes. Cancel the consuming task to stop browsing.
    public func servers() -> AsyncStream<[DiscoveredServer]> {
        AsyncStream { continuation in
            browser.browseResultsChangedHandler = { results, _ in
                continuation.yield(results.compactMap(Self.server(from:)))
            }
            browser.stateUpdateHandler = { state in
                if case .failed = state { continuation.finish() }
                if case .cancelled = state { continuation.finish() }
            }
            continuation.onTermination = { [browser] _ in browser.cancel() }
            browser.start(queue: queue)
        }
    }

    public func cancel() { browser.cancel() }

    static func server(from result: NWBrowser.Result) -> DiscoveredServer? {
        guard case .service(let name, _, _, _) = result.endpoint else { return nil }
        var txt: [String: String] = [:]
        if case .bonjour(let record) = result.metadata {
            for (key, entry) in record {
                if case .string(let value) = entry { txt[key.lowercased()] = value }
            }
        }
        return DiscoveredServer(name: name, txt: txt, endpoint: result.endpoint)
    }

    /// Resolves the service to a connectable `scheme://host:port` URL.
    public static func resolve(_ server: DiscoveredServer, timeout: TimeInterval = 15) async throws -> URL {
        let parameters = NWParameters.tcp
        guard let ipOptions = parameters.defaultProtocolStack.internetProtocol as? NWProtocolIP.Options else {
            throw URLError(.cannotFindHost)
        }
        ipOptions.version = .v4
        let connection = NWConnection(to: server.endpoint, using: parameters)
        let queue = DispatchQueue(label: "com.chadillac6.supersemu.bonjour-resolve")
        let waitingErrors = LatestWaitingError()
        defer { connection.cancel() }
        return try await withThrowingTaskGroup(of: URL.self) { group in
            group.addTask {
                try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<URL, Error>) in
                    let resumed = ResumeOnce()
                    connection.stateUpdateHandler = { state in
                        switch ResolveOutcome.next(
                            state: state,
                            remoteEndpoint: connection.currentPath?.remoteEndpoint,
                            scheme: server.scheme
                        ) {
                        case .keepWaiting(let error):
                            waitingErrors.store(error)
                        case .resolved(let url):
                            resumed.run { continuation.resume(returning: url) }
                        case .failed(let error):
                            resumed.run { continuation.resume(throwing: error) }
                        case .cancelled:
                            resumed.run { continuation.resume(throwing: CancellationError()) }
                        case .ignore:
                            break
                        }
                    }
                    connection.start(queue: queue)
                }
                } onCancel: {
                    connection.cancel()
                }
            }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                if let error = waitingErrors.latest { throw error }
                throw URLError(.timedOut)
            }
            let url = try await group.next()!
            group.cancelAll()
            return url
        }
    }
}

enum ResolveOutcome {
    case keepWaiting(NWError)
    case resolved(URL)
    case failed(Error)
    case cancelled
    case ignore

    static func next(state: NWConnection.State, remoteEndpoint: NWEndpoint?, scheme: String) -> Self {
        switch state {
        case .waiting(let error):
            return .keepWaiting(error)
        case .failed(let error):
            return .failed(error)
        case .ready:
            guard case .hostPort(let host, let port)? = remoteEndpoint else {
                return .failed(URLError(.cannotFindHost))
            }
            let address = String(describing: host)
                .trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
            let unscopedAddress = address.split(separator: "%", maxSplits: 1).first.map(String.init) ?? address
            if case .ipv6 = host, unscopedAddress.lowercased().hasPrefix("fe80:") {
                return .failed(URLError(.cannotFindHost))
            }
            guard let url = SupersEmuBonjour.url(scheme: scheme, host: address, port: Int(port.rawValue)) else {
                return .failed(URLError(.cannotFindHost))
            }
            return .resolved(url)
        case .cancelled:
            return .cancelled
        default:
            return .ignore
        }
    }
}

private final class LatestWaitingError: @unchecked Sendable {
    private let lock = NSLock()
    private var error: NWError?

    var latest: NWError? {
        lock.lock()
        defer { lock.unlock() }
        return error
    }

    func store(_ error: NWError) {
        lock.lock()
        defer { lock.unlock() }
        self.error = error
    }
}

private final class ResumeOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    func run(_ body: () -> Void) {
        lock.lock(); defer { lock.unlock() }
        guard !done else { return }
        done = true
        body()
    }
}
