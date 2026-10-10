import Foundation
import SupersEmuKit

/// The intro (page summary) and a 2-3 sentence excerpt of the Reception section from English Wikipedia. Keyless.
/// The text is CC BY-SA, so the app always shows it with a link back to the article.
public actor WikipediaMetadataProvider: MetadataProvider {
    public nonisolated let id = "wikipedia"
    public nonisolated let version = "1"
    let http: RateLimitedFetcher

    static let api = URL(string: "https://en.wikipedia.org/w/api.php")!
    static let summaryBase = "https://en.wikipedia.org/api/rest_v1/page/summary/"

    public init(http: RateLimitedFetcher) {
        self.http = http
    }

    public func lookup(_ game: MetadataLookup) async throws -> MetadataLookupResult {
        let title = CanonicalName.title(game.title)
        guard let data = try await http.get(Self.searchURL(title: title, system: game.system)) else { return .unmatched }
        let results = try JSONDecoder().decode(SearchResponse.self, from: data).query?.search.map(\.title) ?? []
        for page in Self.candidates(results, title: title).prefix(2) {
            guard let data = try await http.get(Self.summaryURL(page)) else { continue }
            let summary = try JSONDecoder().decode(Summary.self, from: data)
            guard summary.type == "standard", summary.description?.lowercased().contains("game") == true else { continue }
            let pageURL = summary.content_urls?.desktop?.page ?? "https://en.wikipedia.org/wiki/" + Self.encodedTitle(page)
            var reception: ReceptionSummary?
            if let data = try? await http.get(Self.extractURL(page)),
               let extract = try? JSONDecoder().decode(ExtractResponse.self, from: data).query?.pages.first?.extract,
               let text = Self.reception(in: extract) {
                reception = ReceptionSummary(text: text, source: "Wikipedia", url: pageURL + "#Reception")
            }
            return .matched(MetadataRecord(
                provider: id, providerRef: summary.title, year: Self.year(summary.description), description: summary.extract.flatMap { Self.sentences($0, limit: 4) },
                source: MetadataSource(provider: id, name: "Wikipedia", url: pageURL), reception: reception))
        }
        return .unmatched
    }

    public nonisolated func artwork(for record: MetadataRecord, system: SystemID) -> [ArtworkCandidate] { [] }

    /// "1990 video game" -> 1990.
    static func year(_ description: String?) -> Int? {
        guard let description, let match = description.firstMatch(of: #/\b(19[7-9]\d|20\d\d)\b/#) else { return nil }
        return Int(match.1)
    }

    static func searchURL(title: String, system: SystemID) -> URL {
        var components = URLComponents(url: api, resolvingAgainstBaseURL: false)!
        components.queryItems = [.init(name: "action", value: "query"), .init(name: "list", value: "search"),
                                 .init(name: "srsearch", value: "\(title) \(system.searchName) video game"),
                                 .init(name: "srlimit", value: "5"), .init(name: "format", value: "json"),
                                 .init(name: "formatversion", value: "2")]
        return components.url!
    }

    static func summaryURL(_ page: String) -> URL { URL(string: summaryBase + encodedTitle(page))! }

    static func extractURL(_ page: String) -> URL {
        var components = URLComponents(url: api, resolvingAgainstBaseURL: false)!
        components.queryItems = [.init(name: "action", value: "query"), .init(name: "prop", value: "extracts"),
                                 .init(name: "explaintext", value: "1"), .init(name: "redirects", value: "1"),
                                 .init(name: "titles", value: page), .init(name: "format", value: "json"),
                                 .init(name: "formatversion", value: "2")]
        return components.url!
    }

    static func encodedTitle(_ page: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~!'()*,:@_")
        return page.replacingOccurrences(of: " ", with: "_").addingPercentEncoding(withAllowedCharacters: allowed) ?? page
    }

    /// Search results whose title (without a "(… video game)" qualifier) is the game's, video-game pages first.
    static func candidates(_ pages: [String], title: String) -> [String] {
        func split(_ page: String) -> (base: String, qualifier: String?) {
            guard page.hasSuffix(")"), let open = page.range(of: " (", options: .backwards) else { return (page, nil) }
            return (String(page[..<open.lowerBound]), page[open.upperBound...].dropLast().lowercased())
        }
        func rank(_ qualifier: String?) -> Int {
            guard let qualifier else { return 1 }
            if qualifier.contains("video game") { return 0 }
            return qualifier.contains("game") ? 2 : 3
        }
        return pages.filter { TitleMatch.same(split($0).base, title) }
            .enumerated().sorted { (rank(split($0.element).qualifier), $0.offset) < (rank(split($1.element).qualifier), $1.offset) }
            .map(\.element)
    }

    /// The first sentences of the "== Reception ==" (or "Critical reception", "Reception and legacy") section.
    static func reception(in extract: String) -> String? {
        let lines = extract.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
        func isSection(_ line: String) -> Bool { line.hasPrefix("==") && !line.hasPrefix("===") }
        guard let start = lines.firstIndex(where: { isSection($0) && $0.lowercased().contains("reception") }) else { return nil }
        var body: [String] = []
        for line in lines[(start + 1)...] {
            if isSection(line) { break }
            if line.isEmpty || line.hasPrefix("=") { continue }
            body.append(line)
        }
        return sentences(body.joined(separator: " "), limit: 3)
    }

    /// At most `limit` sentences and 600 characters.
    static func sentences(_ text: String, limit: Int) -> String? {
        let characters = Array(text.trimmingCharacters(in: .whitespacesAndNewlines))
        var end = characters.count
        var count = 0
        for index in characters.indices where ".!?".contains(characters[index]) {
            let next = index + 1
            guard next == characters.count || (characters[next] == " " && next + 1 < characters.count
                    && (characters[next + 1].isUppercase || "\"“".contains(characters[next + 1]))) else { continue }
            count += 1
            if count == limit { end = next; break }
        }
        var result = String(characters[..<end])
        if result.count > 600 { result = String(result.prefix(597)).trimmingCharacters(in: .whitespaces) + "…" }
        return result.isEmpty ? nil : result
    }

    struct SearchResponse: Decodable {
        struct Query: Decodable { var search: [Page] }
        struct Page: Decodable { var title: String }
        var query: Query?
    }

    struct Summary: Decodable {
        struct URLs: Decodable { var desktop: Desktop? }
        struct Desktop: Decodable { var page: String? }
        var type: String?
        var title: String
        var description: String?
        var extract: String?
        var content_urls: URLs?
    }

    struct ExtractResponse: Decodable {
        struct Query: Decodable { var pages: [Page] }
        struct Page: Decodable { var extract: String? }
        var query: Query?
    }
}
