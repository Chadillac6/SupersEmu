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

/// Thin async client for the SupersEmu Server `/v1` API. Shared by the apps and the `supersemu` CLI.
public struct APIClient: Sendable {
    public var baseURL: URL
    public var token: String?
    public var session: URLSession

    public init(baseURL: URL, token: String?, session: URLSession = .shared) {
        self.baseURL = baseURL
        self.token = token
        self.session = session
    }

    public func health() async throws -> HealthResponse { try await get("/v1/health") }
    public func me() async throws -> MeResponse { try await get("/v1/me") }
    public func library() async throws -> LibraryResponse { try await get("/v1/library") }

    public func get<T: Decodable>(_ path: String) async throws -> T {
        try await send("GET", path, body: Optional<Empty>.none)
    }

    public func send<Body: Encodable, T: Decodable>(_ method: String, _ path: String, body: Body?) async throws -> T {
        let data = try await raw(method, path, body: body.map { try SupersEmuJSON.encoder().encode($0) })
        return try SupersEmuJSON.decoder().decode(T.self, from: data)
    }

    public func raw(_ method: String, _ path: String, body: Data? = nil, contentType: String = "application/json") async throws -> Data {
        var request = URLRequest(url: baseURL.appending(path: path))
        request.httpMethod = method
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        if let body {
            request.httpBody = body
            request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw APIClientError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else {
            let message = (try? SupersEmuJSON.decoder().decode(APIErrorBody.self, from: data))?.error
            throw APIClientError.http(status: http.statusCode, message: message)
        }
        return data
    }

    private struct Empty: Encodable {}
}
