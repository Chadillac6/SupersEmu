import CryptoKit
import Foundation
import SupersEmuKit
import zlib

public struct ROMHashes: Sendable, Equatable {
    /// Upper-case hex, as in the DATs.
    public var crc: String
    public var md5: String
    public var sha1: String
    public var size: Int64
}

/// CRC32 / MD5 / SHA-1 of a stored ROM, in the forms No-Intro hashes: headerless SNES, de-interleaved .smd,
/// big-endian (.z64) N64. The first variant is the file as stored.
enum ROMHasher {
    static func variants(of url: URL, system: SystemID) throws -> [ROMHashes] {
        let size = Int64((try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value ?? 0)
        var results = [try hash(url, transform: nil)]
        let head = try FileHandle(forReadingFrom: url).readPrefix(4)
        switch system {
        case .snes where size % 1024 == 512:
            results.append(try hash(url, skip: 512, transform: nil))
        case .genesis where size % 0x4000 == 512 && size > 512, .sega32x where size % 0x4000 == 512 && size > 512:
            let data = try Data(contentsOf: url, options: .mappedIfSafe)
            if let plain = deinterleaveSMD(data) { results.append(hash(plain)) }
        case .n64 where head == [0x37, 0x80, 0x40, 0x12]:
            results.append(try hash(url, transform: { swap($0, groupSize: 2) }))
        case .n64 where head == [0x40, 0x12, 0x37, 0x80]:
            results.append(try hash(url, transform: { swap($0, groupSize: 4) }))
        default:
            break
        }
        return results
    }

    static func hash(_ data: Data) -> ROMHashes {
        var state = State()
        state.update(data)
        return state.finish()
    }

    private static func hash(_ url: URL, skip: UInt64 = 0, transform: ((Data) -> Data)?) throws -> ROMHashes {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        if skip > 0 { try handle.seek(toOffset: skip) }
        var state = State()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            state.update(transform?(chunk) ?? chunk)
        }
        return state.finish()
    }

    private struct State {
        var crc: uLong = 0
        var md5 = Insecure.MD5()
        var sha1 = Insecure.SHA1()
        var size: Int64 = 0

        mutating func update(_ data: Data) {
            data.withUnsafeBytes { raw in
                crc = zlib.crc32(crc, raw.bindMemory(to: Bytef.self).baseAddress, uInt(raw.count))
            }
            md5.update(data: data)
            sha1.update(data: data)
            size += Int64(data.count)
        }

        func finish() -> ROMHashes {
            ROMHashes(crc: String(format: "%08X", UInt32(truncatingIfNeeded: crc)), md5: md5.finalize().hexString.uppercased(),
                      sha1: sha1.finalize().hexString.uppercased(), size: size)
        }
    }

    /// Reverses byte order within each group (2 for .v64, 4 for .n64). Chunks are 1 MiB, so groups never straddle.
    static func swap(_ data: Data, groupSize: Int) -> Data {
        var bytes = [UInt8](data)
        var i = 0
        while i + groupSize <= bytes.count {
            bytes[i..<i + groupSize].reverse()
            i += groupSize
        }
        return Data(bytes)
    }

    static func deinterleaveSMD(_ data: Data) -> Data? {
        let bytes = [UInt8](data)
        guard bytes.count > 512, (bytes.count - 512) % 0x4000 == 0 else { return nil }
        var out = [UInt8](repeating: 0, count: bytes.count - 512)
        for block in stride(from: 512, to: bytes.count, by: 0x4000) {
            let base = block - 512
            for i in 0..<0x2000 {
                out[base + i * 2 + 1] = bytes[block + i]
                out[base + i * 2] = bytes[block + 0x2000 + i]
            }
        }
        return Data(out)
    }
}

private extension FileHandle {
    func readPrefix(_ count: Int) throws -> [UInt8] {
        defer { try? close() }
        return [UInt8](try read(upToCount: count) ?? Data())
    }
}
