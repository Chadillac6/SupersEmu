import Foundation

public enum APIClientError: Error, Equatable, CustomStringConvertible {
    case http(status: Int, message: String?)
    case invalidResponse

    public var description: String {
        switch self {
        case .http(let status, let message): return "HTTP \(status)\(message.map { ": \($0)" } ?? "")"
        case .invalidResponse: return "Invalid response from server"
        }
    }
}

public enum SupersEmuJSON {
    public static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }

    public static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

/// Owns a long-lived `URLSession` and invalidates it only once the last holder (including every `APIClient` made
/// from it) is gone. Sending on an invalidated session raises an Objective-C exception that Swift can't catch, so
/// owners drop their lease instead of calling `finishTasksAndInvalidate()` while clients may still be in flight.
public final class URLSessionLease: Sendable {
    public let session: URLSession

    public init(_ session: URLSession) { self.session = session }

    deinit { session.finishTasksAndInvalidate() }
}

/// Thin async client for the SupersEmu Server `/v1` API. Shared by the apps and the `supersemu` CLI.
public struct APIClient: Sendable {
    public var baseURL: URL
    public var token: String?
    public var session: URLSession
    /// Keeps a leased session valid for as long as this client (or a copy) exists.
    private let lease: URLSessionLease?

    public init(baseURL: URL, token: String?, session: URLSession = .shared) {
        self.baseURL = baseURL
        self.token = token
        self.session = session
        lease = nil
    }

    public init(baseURL: URL, token: String?, lease: URLSessionLease) {
        self.baseURL = baseURL
        self.token = token
        session = lease.session
        self.lease = lease
    }

    public func health() async throws -> HealthResponse { try await get("/v1/health") }
    public func me() async throws -> MeResponse { try await get("/v1/me") }
    public func library() async throws -> LibraryResponse { try await get("/v1/library") }
    public func rematchMetadata(gameIDs: [String]?) async throws -> MetadataRematchResponse {
        try await send("POST", "/v1/admin/metadata/rematch", body: MetadataRematchRequest(gameIDs: gameIDs))
    }

    // MARK: Cheats

    public func cheatChanges(since revision: Int) async throws -> CheatListResponse {
        try await get("/v1/cheats?since=\(revision)")
    }

    public func putCheat(_ cheat: CheatRecord) async throws -> CheatRecord {
        let body = try SupersEmuJSON.encoder().encode(cheat)
        let data = try await raw("PUT", "/v1/cheats/\(cheat.gameID)/\(cheat.id.uuidString)", body: body)
        return try SupersEmuJSON.decoder().decode(CheatRecord.self, from: data)
    }

    public func get<T: Decodable>(_ path: String) async throws -> T {
        try await send("GET", path, body: Optional<Empty>.none)
    }

    public func send<Body: Encodable, T: Decodable>(_ method: String, _ path: String, body: Body?) async throws -> T {
        let data = try await raw(method, path, body: body.map { try SupersEmuJSON.encoder().encode($0) })
        return try SupersEmuJSON.decoder().decode(T.self, from: data)
    }

    public func raw(_ method: String, _ path: String, body: Data? = nil, contentType: String = "application/json") async throws -> Data {
        // `appending(path:)` percent-encodes "?", so split off any query first.
        let parts = path.split(separator: "?", maxSplits: 1)
        var url = baseURL.appending(path: String(parts[0]))
        if parts.count == 2, var components = URLComponents(url: url, resolvingAgainstBaseURL: false) {
            components.percentEncodedQuery = String(parts[1])
            url = components.url ?? url
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        if let body {
            request.httpBody = body
            request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        }
        let (data, response) = try await session.data(for: request)
        try Self.check(data, response)
        return data
    }

    static func check(_ data: Data, _ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else { throw APIClientError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else {
            let message = (try? SupersEmuJSON.decoder().decode(APIErrorBody.self, from: data))?.error
                ?? (try? SupersEmuJSON.decoder().decode(HummingbirdErrorBody.self, from: data))?.error.message
            throw APIClientError.http(status: http.statusCode, message: message)
        }
    }

    private struct Empty: Encodable {}
    /// Hummingbird's `HTTPError` body: `{"error":{"message":"..."}}`.
    private struct HummingbirdErrorBody: Decodable { struct Inner: Decodable { var message: String }; var error: Inner }
}
