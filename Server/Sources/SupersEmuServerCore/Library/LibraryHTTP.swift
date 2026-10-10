import Foundation
import HTTPTypes
import Hummingbird
import NIOCore
import SupersEmuKit

enum LibraryHTTP {
    /// JSON response without adding global `ResponseEncodable` conformances (avoids clashes between tracks).
    static func json(_ value: some Encodable, status: HTTPResponse.Status = .ok) throws -> Response {
        let data = try SupersEmuJSON.encoder().encode(value)
        return Response(status: status, headers: [.contentType: "application/json; charset=utf-8"], body: .init(byteBuffer: ByteBuffer(bytes: data)))
    }
}

/// Single-range `Range: bytes=...` handling (RFC 9110). Multi-range and malformed headers are ignored (full body).
enum ByteRange: Equatable {
    case full
    case partial(ClosedRange<Int>)
    case unsatisfiable

    static func parse(_ header: String?, size: Int) -> ByteRange {
        guard let header = header?.trimmingCharacters(in: .whitespaces), header.lowercased().hasPrefix("bytes=") else { return .full }
        let spec = header.dropFirst("bytes=".count).trimmingCharacters(in: .whitespaces)
        guard !spec.contains(","), let dash = spec.firstIndex(of: "-") else { return .full }
        let startText = spec[..<dash].trimmingCharacters(in: .whitespaces)
        let endText = spec[spec.index(after: dash)...].trimmingCharacters(in: .whitespaces)
        if startText.isEmpty {
            guard let suffix = Int(endText), suffix >= 0 else { return .full }
            guard suffix > 0, size > 0 else { return .unsatisfiable }
            return .partial(max(0, size - suffix)...(size - 1))
        }
        guard let start = Int(startText), start >= 0 else { return .full }
        let end: Int
        if endText.isEmpty {
            end = size - 1
        } else {
            guard let parsed = Int(endText), parsed >= start else { return .full }
            end = min(parsed, size - 1)
        }
        guard start < size else { return .unsatisfiable }
        return .partial(start...end)
    }
}
