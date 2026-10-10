import Foundation

/// `supersemu://pair?d=<base64url(PairingPayload JSON)>`, the link inside the pairing QR code.
public enum PairingLink {
    public static let scheme = "supersemu"
    public static let host = "pair"

    public enum ParseError: Error, Equatable {
        case notAPairingLink
        case missingPayload
        case invalidPayload
    }

    public static func url(for payload: PairingPayload) throws -> URL {
        var components = URLComponents()
        components.scheme = scheme
        components.host = host
        components.queryItems = [URLQueryItem(name: "d", value: Base64URL.encode(try SupersEmuJSON.encoder().encode(payload)))]
        guard let url = components.url else { throw ParseError.invalidPayload }
        return url
    }

    public static func payload(from url: URL) throws -> PairingPayload {
        guard url.scheme?.lowercased() == scheme, url.host?.lowercased() == host,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            throw ParseError.notAPairingLink
        }
        guard let encoded = components.queryItems?.first(where: { $0.name == "d" })?.value, !encoded.isEmpty else {
            throw ParseError.missingPayload
        }
        guard let data = Base64URL.decode(encoded),
              let payload = try? SupersEmuJSON.decoder().decode(PairingPayload.self, from: data) else {
            throw ParseError.invalidPayload
        }
        return payload
    }

    /// Accepts the raw string a QR scanner returns.
    public static func payload(from string: String) throws -> PairingPayload {
        guard let url = URL(string: string.trimmingCharacters(in: .whitespacesAndNewlines)) else { throw ParseError.notAPairingLink }
        return try payload(from: url)
    }
}

extension PairingPayload {
    public func qrURL() throws -> URL { try PairingLink.url(for: self) }
}

public enum Base64URL {
    public static func encode(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    public static func decode(_ string: String) -> Data? {
        var base64 = string.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        base64 = base64.replacingOccurrences(of: "=", with: "")
        let remainder = base64.count % 4
        if remainder == 1 { return nil }
        if remainder > 0 { base64 += String(repeating: "=", count: 4 - remainder) }
        return Data(base64Encoded: base64)
    }
}
