import Compression
import Foundation

/// Minimal read-only .zip reader (stored + deflate, no zip64, no encryption). Uses the central directory,
/// never trusts entry paths for writing, and enforces size limits so a hostile archive can't exhaust memory or disk.
public struct ZipArchive {
    public struct Entry: Sendable, Equatable {
        public var path: String
        public var method: UInt16
        public var crc32: UInt32
        public var compressedSize: Int
        public var uncompressedSize: Int
        public var localHeaderOffset: Int
        public var isEncrypted: Bool
        public var isDirectory: Bool { path.hasSuffix("/") }
        /// Last path component; the only part of the entry name the importer ever uses.
        public var filename: String { (path as NSString).lastPathComponent }
    }

    public enum ZipError: Error, Equatable, CustomStringConvertible {
        case notAZip, zip64Unsupported, tooManyEntries, entryTooLarge(String), archiveTooLarge
        case encrypted(String), unsupportedMethod(String, UInt16), corrupt(String)

        public var description: String {
            switch self {
            case .notAZip: return "Not a valid zip archive"
            case .zip64Unsupported: return "Zip64 archives are not supported"
            case .tooManyEntries: return "Too many entries in archive"
            case .entryTooLarge(let name): return "\(name) is too large"
            case .archiveTooLarge: return "Archive expands to more than the size limit"
            case .encrypted(let name): return "\(name) is encrypted"
            case .unsupportedMethod(let name, let method): return "\(name) uses unsupported compression (method \(method))"
            case .corrupt(let name): return "\(name) is corrupt (CRC or size mismatch)"
            }
        }
    }

    public static let maxEntries = 10_000
    public static let maxEntrySize = 512 * 1024 * 1024
    public static let maxTotalSize: Int64 = 16 * 1024 * 1024 * 1024

    public let url: URL
    public let entries: [Entry]
    private let handle: FileHandle

    public init(url: URL) throws {
        self.url = url
        handle = try FileHandle(forReadingFrom: url)
        let size = Int(try handle.seekToEnd())
        let tailLength = min(size, 22 + 0xFFFF)
        let tail = [UInt8](try Self.read(handle, offset: size - tailLength, count: tailLength))
        guard tail.count >= 22, let eocd = stride(from: tail.count - 22, through: 0, by: -1).first(where: { Self.u32(tail, $0) == 0x0605_4B50 }) else {
            throw ZipError.notAZip
        }
        let count = Int(Self.u16(tail, eocd + 10))
        let cdSize = Int(Self.u32(tail, eocd + 12))
        let cdOffset = Int(Self.u32(tail, eocd + 16))
        if count == 0xFFFF || cdSize == 0xFFFF_FFFF || cdOffset == 0xFFFF_FFFF { throw ZipError.zip64Unsupported }
        guard count <= Self.maxEntries else { throw ZipError.tooManyEntries }
        guard cdOffset + cdSize <= size else { throw ZipError.notAZip }
        let cd = [UInt8](try Self.read(handle, offset: cdOffset, count: cdSize))

        var entries: [Entry] = []
        var total: Int64 = 0
        var p = 0
        for _ in 0..<count {
            guard p + 46 <= cd.count, Self.u32(cd, p) == 0x0201_4B50 else { throw ZipError.notAZip }
            let flags = Self.u16(cd, p + 8)
            let nameLength = Int(Self.u16(cd, p + 28)), extraLength = Int(Self.u16(cd, p + 30)), commentLength = Int(Self.u16(cd, p + 32))
            guard p + 46 + nameLength <= cd.count else { throw ZipError.notAZip }
            let nameBytes = Data(cd[(p + 46)..<(p + 46 + nameLength)])
            let name = String(data: nameBytes, encoding: flags & 0x800 != 0 ? .utf8 : .isoLatin1) ?? String(decoding: nameBytes, as: UTF8.self)
            let entry = Entry(
                path: name, method: Self.u16(cd, p + 10), crc32: Self.u32(cd, p + 16),
                compressedSize: Int(Self.u32(cd, p + 20)), uncompressedSize: Int(Self.u32(cd, p + 24)),
                localHeaderOffset: Int(Self.u32(cd, p + 42)), isEncrypted: flags & 0x1 != 0)
            if entry.compressedSize == 0xFFFF_FFFF || entry.uncompressedSize == 0xFFFF_FFFF || entry.localHeaderOffset == 0xFFFF_FFFF {
                throw ZipError.zip64Unsupported
            }
            total += Int64(entry.uncompressedSize)
            guard total <= Self.maxTotalSize else { throw ZipError.archiveTooLarge }
            entries.append(entry)
            p += 46 + nameLength + extraLength + commentLength
        }
        self.entries = entries
    }

    /// Decompresses one entry into memory and verifies its size and CRC-32.
    public func data(for entry: Entry) throws -> Data {
        guard !entry.isEncrypted else { throw ZipError.encrypted(entry.filename) }
        guard entry.uncompressedSize <= Self.maxEntrySize else { throw ZipError.entryTooLarge(entry.filename) }
        let local = [UInt8](try Self.read(handle, offset: entry.localHeaderOffset, count: 30))
        guard local.count == 30, Self.u32(local, 0) == 0x0403_4B50 else { throw ZipError.corrupt(entry.filename) }
        let dataOffset = entry.localHeaderOffset + 30 + Int(Self.u16(local, 26)) + Int(Self.u16(local, 28))
        let compressed = try Self.read(handle, offset: dataOffset, count: entry.compressedSize)
        guard compressed.count == entry.compressedSize else { throw ZipError.corrupt(entry.filename) }

        let output: Data
        switch entry.method {
        case 0:
            output = compressed
        case 8:
            guard entry.uncompressedSize > 0 else { output = Data(); break }
            guard !compressed.isEmpty else { throw ZipError.corrupt(entry.filename) }
            var buffer = Data(count: entry.uncompressedSize)
            let written = buffer.withUnsafeMutableBytes { dst -> Int in
                compressed.withUnsafeBytes { src -> Int in
                    guard let dstBase = dst.bindMemory(to: UInt8.self).baseAddress,
                          let srcBase = src.bindMemory(to: UInt8.self).baseAddress else { return -1 }
                    return compression_decode_buffer(dstBase, entry.uncompressedSize, srcBase, compressed.count, nil, COMPRESSION_ZLIB)
                }
            }
            guard written == entry.uncompressedSize else { throw ZipError.corrupt(entry.filename) }
            output = buffer
        default:
            throw ZipError.unsupportedMethod(entry.filename, entry.method)
        }
        guard output.count == entry.uncompressedSize, CRC32.checksum(output) == entry.crc32 else { throw ZipError.corrupt(entry.filename) }
        return output
    }

    /// Streams one entry to `destination` without holding it in memory, so disc tracks larger than
    /// `maxEntrySize` can come out of a zip. Verifies size and CRC.
    public func extract(_ entry: Entry, to destination: URL) throws {
        guard !entry.isEncrypted else { throw ZipError.encrypted(entry.filename) }
        guard entry.method == 0 || entry.method == 8 else { throw ZipError.unsupportedMethod(entry.filename, entry.method) }
        let local = [UInt8](try Self.read(handle, offset: entry.localHeaderOffset, count: 30))
        guard local.count == 30, Self.u32(local, 0) == 0x0403_4B50 else { throw ZipError.corrupt(entry.filename) }
        let dataOffset = entry.localHeaderOffset + 30 + Int(Self.u16(local, 26)) + Int(Self.u16(local, 28))
        guard FileManager.default.createFile(atPath: destination.path, contents: nil) else { throw ZipError.corrupt(entry.filename) }
        let out = try FileHandle(forWritingTo: destination)
        defer { try? out.close() }
        try handle.seek(toOffset: UInt64(dataOffset))
        var crc = CRC32.Running(), written = 0, remaining = entry.compressedSize
        func emit(_ data: Data) throws {
            written += data.count
            guard written <= entry.uncompressedSize else { throw ZipError.corrupt(entry.filename) }
            crc.update(data)
            try out.write(contentsOf: data)
        }
        let chunkSize = 1 << 20
        if entry.method == 0 {
            while remaining > 0 {
                guard let chunk = try handle.read(upToCount: min(chunkSize, remaining)), !chunk.isEmpty else { throw ZipError.corrupt(entry.filename) }
                remaining -= chunk.count
                try emit(chunk)
            }
        } else if entry.uncompressedSize > 0 {
            let stream = UnsafeMutablePointer<compression_stream>.allocate(capacity: 1)
            defer { stream.deallocate() }
            guard compression_stream_init(stream, COMPRESSION_STREAM_DECODE, COMPRESSION_ZLIB) == COMPRESSION_STATUS_OK else {
                throw ZipError.corrupt(entry.filename)
            }
            defer { compression_stream_destroy(stream) }
            let dst = UnsafeMutablePointer<UInt8>.allocate(capacity: chunkSize)
            defer { dst.deallocate() }
            var finished = false
            while !finished {
                let input = remaining > 0 ? (try handle.read(upToCount: min(chunkSize, remaining)) ?? Data()) : Data()
                if remaining > 0, input.isEmpty { throw ZipError.corrupt(entry.filename) }
                remaining -= input.count
                let flags = remaining == 0 ? Int32(COMPRESSION_STREAM_FINALIZE.rawValue) : 0
                try input.withUnsafeBytes { (src: UnsafeRawBufferPointer) in
                    stream.pointee.src_ptr = src.bindMemory(to: UInt8.self).baseAddress ?? UnsafePointer(dst)
                    stream.pointee.src_size = input.count
                    repeat {
                        stream.pointee.dst_ptr = dst
                        stream.pointee.dst_size = chunkSize
                        let status = compression_stream_process(stream, flags)
                        guard status != COMPRESSION_STATUS_ERROR else { throw ZipError.corrupt(entry.filename) }
                        let produced = chunkSize - stream.pointee.dst_size
                        if produced > 0 { try emit(Data(bytes: dst, count: produced)) }
                        if status == COMPRESSION_STATUS_END { finished = true; break }
                        if remaining == 0, produced == 0, stream.pointee.src_size == 0 { throw ZipError.corrupt(entry.filename) }
                    } while stream.pointee.src_size > 0 || stream.pointee.dst_size == 0
                }
            }
        }
        guard written == entry.uncompressedSize, crc.value == entry.crc32 else { throw ZipError.corrupt(entry.filename) }
    }

    private static func read(_ handle: FileHandle, offset: Int, count: Int) throws -> Data {
        try handle.seek(toOffset: UInt64(offset))
        return try handle.read(upToCount: count) ?? Data()
    }

    private static func u16(_ b: [UInt8], _ i: Int) -> UInt16 { UInt16(b[i]) | UInt16(b[i + 1]) << 8 }
    private static func u32(_ b: [UInt8], _ i: Int) -> UInt32 {
        UInt32(b[i]) | UInt32(b[i + 1]) << 8 | UInt32(b[i + 2]) << 16 | UInt32(b[i + 3]) << 24
    }
}

enum CRC32 {
    static let table: [UInt32] = (0..<256).map { n in
        var c = UInt32(n)
        for _ in 0..<8 { c = c & 1 != 0 ? 0xEDB8_8320 ^ (c >> 1) : c >> 1 }
        return c
    }

    struct Running {
        private var crc: UInt32 = 0xFFFF_FFFF
        mutating func update(_ data: Data) {
            data.withUnsafeBytes { raw in
                for byte in raw.bindMemory(to: UInt8.self) { crc = table[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8) }
            }
        }
        var value: UInt32 { crc ^ 0xFFFF_FFFF }
    }

    static func checksum(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        data.withUnsafeBytes { raw in
            for byte in raw.bindMemory(to: UInt8.self) { crc = table[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8) }
        }
        return crc ^ 0xFFFF_FFFF
    }
}
