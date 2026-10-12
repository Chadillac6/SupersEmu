import Foundation

public struct PublicAccessConfiguration: Codable, Sendable, Equatable {
    public var enabled: Bool
    public var publicURL: URL
    public var listenPort: Int

    public init(enabled: Bool, publicURL: URL, listenPort: Int = 8489) throws {
        guard Self.isValid(publicURL), (1...65535).contains(listenPort) else {
            throw PublicAccessConfigurationError.invalid
        }
        self.enabled = enabled
        self.publicURL = publicURL
        self.listenPort = listenPort
    }

    public static func load(root: URL, publicURL overrideURL: URL? = nil,
                            listenPort overridePort: Int? = nil) throws -> PublicAccessConfiguration? {
        let file = root.appendingPathComponent("public-access.json")
        var configuration: PublicAccessConfiguration?
        if FileManager.default.fileExists(atPath: file.path) {
            let decoded = try JSONDecoder().decode(PublicAccessConfiguration.self, from: Data(contentsOf: file))
            guard Self.isValid(decoded.publicURL), (1...65535).contains(decoded.listenPort) else {
                throw PublicAccessConfigurationError.invalid
            }
            configuration = decoded
        }
        guard overrideURL != nil || overridePort != nil else { return configuration?.enabled == true ? configuration : nil }
        let url = overrideURL ?? configuration?.publicURL
        guard let url else { throw PublicAccessConfigurationError.invalid }
        let port = overridePort ?? configuration?.listenPort ?? 8489
        return try PublicAccessConfiguration(enabled: true, publicURL: url, listenPort: port)
    }

    public static func isValid(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "https", let host = url.host, !host.isEmpty,
              url.user == nil, url.password == nil, url.query == nil, url.fragment == nil,
              url.path.isEmpty || url.path == "/" else { return false }
        return true
    }
}

public enum PublicAccessConfigurationError: Error {
    case invalid
}
