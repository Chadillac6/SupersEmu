import Foundation
import SupersEmuKit

/// High-res hero (backdrop) and logo art from SteamGridDB. Needs an API key (`MetadataKeys`); without one the provider
/// is disabled and the libretro box, title and snap art is used instead.
public actor SteamGridDBMetadataProvider: MetadataProvider {
    public nonisolated let id = "steamgriddb"
    public nonisolated let version = "1"
    let key: @Sendable () -> String?
    let http: RateLimitedFetcher

    static let api = "https://www.steamgriddb.com/api/v2/"
    static let images: [(ArtworkKind, String, String)] = [(.backdrop, "heroes", "image/png,image/jpeg"), (.logo, "logos", "image/png")]

    /// Only SteamGridDB's own hosts, so a bad API response can't point the server at other (e.g. private) hosts.
    static func isCDN(_ url: URL) -> Bool {
        guard url.scheme == "https", let host = url.host?.lowercased() else { return false }
        return host == "steamgriddb.com" || host.hasSuffix(".steamgriddb.com")
    }

    public init(key: @escaping @Sendable () -> String?, http: RateLimitedFetcher) {
        self.key = key
        self.http = http
    }

    public nonisolated var isEnabled: Bool { key() != nil }

    public func lookup(_ game: MetadataLookup) async throws -> MetadataLookupResult {
        guard let key = key() else { return .unavailable }
        let title = CanonicalName.title(game.title)
        guard let searchURL = Self.searchURL(title), let data = try await get(searchURL, key: key) else { return .unmatched }
        guard let match = try JSONDecoder().decode(Response<[SearchResult]>.self, from: data).data?
            .first(where: { TitleMatch.same($0.name, title) }) else { return .unmatched }
        var urls: [ArtworkKind: URL] = [:]
        for (kind, path, mimes) in Self.images {
            guard let data = try await get(Self.imagesURL(path, gameID: match.id, mimes: mimes), key: key),
                  let image = try? JSONDecoder().decode(Response<[Image]>.self, from: data).data?.first(where: { Self.isCDN($0.url) })
            else { continue }
            urls[kind] = image.url
        }
        return .matched(MetadataRecord(
            provider: id, providerRef: String(match.id),
            source: MetadataSource(provider: id, name: "SteamGridDB", url: "https://www.steamgriddb.com/game/\(match.id)"),
            artworkURLs: urls.isEmpty ? nil : urls))
    }

    /// Image files come from SteamGridDB's public CDN, fetched without the key.
    public nonisolated func artwork(for record: MetadataRecord, system: SystemID) -> [ArtworkCandidate] {
        Self.images.compactMap { kind, _, _ in
            record.artworkURLs?[kind].map { ArtworkCandidate(kind: kind, position: 0, urls: [$0]) }
        }
    }

    func get(_ url: URL, key: String) async throws -> Data? {
        var request = URLRequest(url: url)
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        return try await http.send(request)
    }

    static func searchURL(_ title: String) -> URL? {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        guard let encodedTitle = title.addingPercentEncoding(withAllowedCharacters: allowed) else { return nil }
        return URL(string: api + "search/autocomplete/" + encodedTitle)
    }

    static func imagesURL(_ path: String, gameID: Int, mimes: String) -> URL {
        var components = URLComponents(string: api + "\(path)/game/\(gameID)")!
        components.queryItems = [.init(name: "types", value: "static"), .init(name: "mimes", value: mimes),
                                 .init(name: "nsfw", value: "false"), .init(name: "humor", value: "false")]
        return components.url!
    }

    struct Response<T: Decodable>: Decodable {
        var data: T?
    }

    struct SearchResult: Decodable {
        var id: Int
        var name: String
    }

    struct Image: Decodable {
        var url: URL
    }
}
