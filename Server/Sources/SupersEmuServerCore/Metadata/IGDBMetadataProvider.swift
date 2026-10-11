import Foundation
import SupersEmuKit

/// Critic score from IGDB plus an IGN review link. Needs a Twitch client ID and secret (`MetadataKeys`); without them
/// the provider is disabled and games simply have no score.
public actor IGDBMetadataProvider: MetadataProvider {
    public nonisolated let id = "igdb"
    public nonisolated let version = "1"
    let credentials: @Sendable () -> (clientID: String, secret: String)?
    let http: RateLimitedFetcher
    let now: @Sendable () -> Date
    private var token: (value: String, clientID: String, expires: Date)?

    static let tokenURL = URL(string: "https://id.twitch.tv/oauth2/token")!
    static let gamesURL = URL(string: "https://api.igdb.com/v4/games")!
    static let platforms: [SystemID: Int] = [.snes: 19, .gb: 33, .gbc: 22, .gba: 24, .genesis: 29, .segacd: 78, .sega32x: 30,
                                             .psx: 7, .n64: 4]

    public init(credentials: @escaping @Sendable () -> (clientID: String, secret: String)?, http: RateLimitedFetcher,
                now: @escaping @Sendable () -> Date = Date.init) {
        self.credentials = credentials
        self.http = http
        self.now = now
    }

    public nonisolated var isEnabled: Bool { credentials() != nil }

    public func lookup(_ game: MetadataLookup) async throws -> MetadataLookupResult {
        guard let credentials = credentials() else { return .unavailable }
        guard let platform = Self.platforms[game.system] else { return .unmatched }
        let title = CanonicalName.title(game.title)
        var request = URLRequest(url: Self.gamesURL)
        request.httpMethod = "POST"
        request.setValue(credentials.clientID, forHTTPHeaderField: "Client-ID")
        request.setValue("Bearer \(try await accessToken(credentials))", forHTTPHeaderField: "Authorization")
        request.setValue("text/plain", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(Self.query(title: title, platform: platform).utf8)
        let data: Data?
        do {
            data = try await http.send(request)
        } catch {
            token = nil
            throw error
        }
        guard let data else { return .unmatched }
        guard let match = try JSONDecoder().decode([Game].self, from: data).first(where: { TitleMatch.same($0.name, title) }) else {
            return .unmatched
        }
        let score: CriticScore? = if let rating = match.aggregated_rating {
            CriticScore(score: Int(rating.rounded()), source: "Critics via IGDB", url: match.url)
        } else if let rating = match.total_rating {
            CriticScore(score: Int(rating.rounded()), source: "IGDB", url: match.url)
        } else {
            nil
        }
        let ign = match.websites?.compactMap(\.url).first { URL(string: $0)?.host?.hasSuffix("ign.com") == true }
        return .matched(MetadataRecord(
            provider: id, providerRef: String(match.id), criticScore: score,
            source: MetadataSource(provider: id, name: "IGDB", url: match.url),
            reviewLink: ReviewLink(name: "IGN", url: ign ?? Self.ignSearchURL(title).absoluteString)))
    }

    public nonisolated func artwork(for record: MetadataRecord, system: SystemID) -> [ArtworkCandidate] { [] }

    /// Twitch app access token (client credentials), reused until a minute before it expires.
    func accessToken(_ credentials: (clientID: String, secret: String)) async throws -> String {
        if let token, token.clientID == credentials.clientID, token.expires > now().addingTimeInterval(60) { return token.value }
        var form = URLComponents()
        form.queryItems = [.init(name: "client_id", value: credentials.clientID),
                           .init(name: "client_secret", value: credentials.secret),
                           .init(name: "grant_type", value: "client_credentials")]
        var request = URLRequest(url: Self.tokenURL)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data((form.percentEncodedQuery ?? "").replacingOccurrences(of: "+", with: "%2B").utf8)
        guard let data = try await http.send(request) else { throw URLError(.userAuthenticationRequired) }
        let response = try JSONDecoder().decode(TokenResponse.self, from: data)
        token = (response.access_token, credentials.clientID, now().addingTimeInterval(TimeInterval(response.expires_in)))
        return response.access_token
    }

    static func query(title: String, platform: Int) -> String {
        let escaped = title.replacingOccurrences(of: "\\", with: "").replacingOccurrences(of: "\"", with: "\\\"")
        return "search \"\(escaped)\"; fields name,url,aggregated_rating,total_rating,websites.url; "
            + "where platforms = (\(platform)); limit 10;"
    }

    static func ignSearchURL(_ title: String) -> URL {
        var components = URLComponents(string: "https://www.ign.com/search")!
        components.queryItems = [.init(name: "q", value: title)]
        return components.url!
    }

    struct TokenResponse: Decodable {
        var access_token: String
        var expires_in: Int
    }

    struct Game: Decodable {
        struct Website: Decodable { var url: String? }
        var id: Int
        var name: String
        var url: String?
        var aggregated_rating: Double?
        var total_rating: Double?
        var websites: [Website]?
    }
}
