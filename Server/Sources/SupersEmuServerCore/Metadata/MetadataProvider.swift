import Foundation
import SupersEmuKit

/// HTTP GET for datasets and artwork. Returns nil on 404; throws on network errors so the work is retried later.
public protocol MetadataFetching: Sendable {
    func get(_ url: URL) async throws -> Data?
}

public struct URLSessionMetadataFetcher: MetadataFetching {
    public init() {}

    public func get(_ url: URL) async throws -> Data? {
        var request = URLRequest(url: url, timeoutInterval: 60)
        request.setValue("SupersEmu-Server/\(ServerInfo.version)", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status == 404 { return nil }
        guard status == 200 else { throw URLError(.badServerResponse) }
        return data
    }
}

/// Spaces requests at least `minimumInterval` apart; shared by every provider.
public actor RateLimitedFetcher {
    let fetcher: any MetadataFetching
    let minimumInterval: Duration
    private var last: ContinuousClock.Instant?

    public init(_ fetcher: any MetadataFetching, minimumInterval: Duration) {
        self.fetcher = fetcher
        self.minimumInterval = minimumInterval
    }

    public func get(_ url: URL) async throws -> Data? {
        if let last {
            let wait = last + minimumInterval - ContinuousClock.now
            if wait > .zero { try? await Task.sleep(for: wait) }
        }
        last = ContinuousClock.now
        return try await fetcher.get(url)
    }
}

/// An imported game as a provider sees it.
public struct MetadataLookup: Sendable {
    public var gameID: String
    public var system: SystemID
    public var title: String
    /// ROM, or the data tracks of the first disc, resolved under the store root.
    public var files: [URL]
}

/// One artwork slot and the URLs to try for it, in order.
public struct ArtworkCandidate: Sendable, Equatable {
    public var kind: ArtworkKind
    public var position: Int
    public var urls: [URL]
}

public enum MetadataLookupResult: Sendable {
    case matched(MetadataRecord)
    case unmatched
    /// The provider couldn't answer right now (dataset download failed, offline); retried on the next pass.
    case unavailable
}

/// A metadata source. Providers are keyless today (libretro); ones needing credentials would be configured by the admin.
public protocol MetadataProvider: Sendable {
    var id: String { get }
    /// Bump to rematch every game (e.g. a new pinned dataset).
    var version: String { get }
    func lookup(_ game: MetadataLookup) async throws -> MetadataLookupResult
    func artwork(for record: MetadataRecord, system: SystemID) -> [ArtworkCandidate]
}
