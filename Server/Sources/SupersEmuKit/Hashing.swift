import CryptoKit
import Foundation

public extension Sequence where Element == UInt8 {
    /// Lowercase hex, two digits per byte. Every content ID, save revision, BIOS ID and certificate pin uses this form.
    var hexString: String { map { String(format: "%02x", $0) }.joined() }
}

public enum Hashing {
    /// Lowercase hex SHA-256 of `data`.
    public static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).hexString
    }

    /// Lowercase hex SHA-256 of a file, streamed in 1 MiB chunks so the whole file is never in memory.
    public static func sha256Hex(ofFileAt url: URL) throws -> String {
        var hasher = SHA256()
        try update(&hasher, withContentsOf: url)
        return hasher.finalize().hexString
    }

    /// Feeds a file into `hasher` in 1 MiB chunks and returns the number of bytes read.
    @discardableResult
    public static func update<Hasher: HashFunction>(_ hasher: inout Hasher, withContentsOf url: URL) throws -> Int64 {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var count: Int64 = 0
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
            count += Int64(chunk.count)
        }
        return count
    }
}
