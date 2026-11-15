import Foundation
import SupersEmuKit
import zlib

/// 2048-byte user-data sectors of a disc image, whatever the container.
protocol DiscSectors {
    func read(lba: Int, count: Int) throws -> Data
}

/// Reads disc structures that sit beyond the header bytes: the ISO 9660 `SYSTEM.CNF` that tells PS2 from PS1,
/// CHD metadata tags (GD-ROM, DVD) and compressed `.cso` images. Every read is bounded, and anything malformed is nil.
enum DiscProbe {
    /// PS2 when `SYSTEM.CNF` has a `BOOT2` line, PS1 when it has `BOOT`. Nil when there's no readable ISO 9660 `SYSTEM.CNF`.
    static func playStationSystem(of url: URL, compressed: Bool = false) -> SystemID? {
        guard let sectors: DiscSectors = compressed ? (try? CSOImage(url: url)) : (try? FlatImage(url: url)),
              let cnf = ISO9660.systemCNF(sectors) else { return nil }
        return playStationSystem(systemCNF: cnf)
    }

    static func playStationSystem(systemCNF: String) -> SystemID? {
        var keys = Set<String>()
        for line in systemCNF.components(separatedBy: .newlines) {
            guard let eq = line.firstIndex(of: "=") else { continue }
            keys.insert(line[..<eq].trimmingCharacters(in: .whitespaces).uppercased())
        }
        if keys.contains("BOOT2") { return .ps2 }
        if keys.contains("BOOT") { return .psx }
        return nil
    }
}

/// A plain image: 2048-byte sectors (`.iso`), or raw 2352-byte sectors (MODE1 user data at 16, MODE2 form 1 at 24).
/// The layout is whichever has the ISO 9660 volume descriptor (`CD001`) at sector 16.
struct FlatImage: DiscSectors {
    let handle: FileHandle
    let sectorSize: Int
    let dataOffset: Int

    init(url: URL) throws {
        handle = try FileHandle(forReadingFrom: url)
        for (size, offset) in [(2048, 0), (2352, 16), (2352, 24)] {
            try handle.seek(toOffset: UInt64(16 * size + offset))
            let pvd = try handle.read(upToCount: 6) ?? Data()
            if pvd.count == 6, pvd[pvd.startIndex] == 1, pvd.dropFirst().elementsEqual("CD001".utf8) {
                sectorSize = size; dataOffset = offset
                return
            }
        }
        try? handle.close()
        throw CocoaError(.fileReadCorruptFile)
    }

    func read(lba: Int, count: Int) throws -> Data {
        var out = Data()
        for sector in lba..<lba + count {
            try handle.seek(toOffset: UInt64(sector * sectorSize + dataOffset))
            guard let data = try handle.read(upToCount: 2048), data.count == 2048 else { throw CocoaError(.fileReadCorruptFile) }
            out += data
        }
        return out
    }
}

/// CISO (`.cso`) v0/v1: 24-byte header, a block index, then raw-deflate blocks (high index bit = stored as-is).
struct CSOImage: DiscSectors {
    let handle: FileHandle
    let totalBytes: UInt64
    let blockSize: Int
    let align: UInt64
    let index: [UInt32]

    static let maxBlocks = 1 << 24

    init(url: URL) throws {
        handle = try FileHandle(forReadingFrom: url)
        let header = [UInt8](try handle.read(upToCount: 24) ?? Data())
        func le(_ offset: Int, _ count: Int) -> UInt64 {
            (0..<count).reduce(0) { $0 | UInt64(header[offset + $1]) << (8 * UInt64($1)) }
        }
        guard header.count == 24, header[0..<4].elementsEqual("CISO".utf8), header[20] <= 1 else {
            try? handle.close(); throw CocoaError(.fileReadCorruptFile)
        }
        totalBytes = le(8, 8)
        blockSize = Int(le(16, 4))
        align = UInt64(header[21])
        guard blockSize >= 2048, blockSize <= 1 << 20, blockSize % 2048 == 0 else { try? handle.close(); throw CocoaError(.fileReadCorruptFile) }
        let blockCount64 = totalBytes / UInt64(blockSize) + (totalBytes % UInt64(blockSize) == 0 ? 0 : 1)
        guard blockCount64 > 0, blockCount64 < UInt64(Self.maxBlocks) else { try? handle.close(); throw CocoaError(.fileReadCorruptFile) }
        let blocks = Int(blockCount64)
        guard let raw = try handle.read(upToCount: (blocks + 1) * 4), raw.count == (blocks + 1) * 4 else {
            try? handle.close(); throw CocoaError(.fileReadCorruptFile)
        }
        let bytes = [UInt8](raw)
        var table = [UInt32](repeating: 0, count: blocks + 1)
        for i in 0...blocks {
            let base = i * 4
            let b0 = UInt32(bytes[base]), b1 = UInt32(bytes[base + 1]) << 8
            let b2 = UInt32(bytes[base + 2]) << 16, b3 = UInt32(bytes[base + 3]) << 24
            table[i] = b0 | b1 | b2 | b3
        }
        index = table
    }

    var blockCount: Int { index.count - 1 }

    func block(_ number: Int) throws -> Data {
        guard number >= 0, number < blockCount else { throw CocoaError(.fileReadCorruptFile) }
        let start = UInt64(index[number] & 0x7FFF_FFFF) << align
        let end = UInt64(index[number + 1] & 0x7FFF_FFFF) << align
        guard end >= start, end - start <= UInt64(blockSize) * 2 + 1024 else { throw CocoaError(.fileReadCorruptFile) }
        try handle.seek(toOffset: start)
        let stored = try handle.read(upToCount: Int(end - start)) ?? Data()
        let expected = min(blockSize, Int(totalBytes - UInt64(number * blockSize)))
        if index[number] & 0x8000_0000 != 0 { return stored.prefix(expected) }
        return try Self.inflateRaw(stored, expected: blockSize).prefix(expected)
    }

    func read(lba: Int, count: Int) throws -> Data {
        var out = Data()
        let perBlock = blockSize / 2048
        var sector = lba
        while sector < lba + count {
            let data = try block(sector / perBlock)
            let offset = (sector % perBlock) * 2048
            guard data.count >= offset + 2048 else { throw CocoaError(.fileReadCorruptFile) }
            out += data[data.startIndex + offset..<data.startIndex + offset + 2048]
            sector += 1
        }
        return out
    }

    static func inflateRaw(_ input: Data, expected: Int) throws -> Data {
        var stream = z_stream()
        guard inflateInit2_(&stream, -15, zlibVersion(), Int32(MemoryLayout<z_stream>.size)) == Z_OK else { throw CocoaError(.fileReadCorruptFile) }
        defer { inflateEnd(&stream) }
        var output = Data(count: expected)
        var input = input
        let status: Int32 = input.withUnsafeMutableBytes { (inRaw: UnsafeMutableRawBufferPointer) in
            output.withUnsafeMutableBytes { (outRaw: UnsafeMutableRawBufferPointer) in
                stream.next_in = inRaw.bindMemory(to: Bytef.self).baseAddress
                stream.avail_in = uInt(inRaw.count)
                stream.next_out = outRaw.bindMemory(to: Bytef.self).baseAddress
                stream.avail_out = uInt(outRaw.count)
                return inflate(&stream, Z_FINISH)
            }
        }
        guard status == Z_STREAM_END || status == Z_BUF_ERROR || status == Z_OK else { throw CocoaError(.fileReadCorruptFile) }
        return output.prefix(Int(stream.total_out))
    }
}

enum ISO9660 {
    static let maxDirectoryBytes = 64 * 1024
    static let maxSystemCNFBytes = 4096

    /// The root directory's `SYSTEM.CNF`, decoded as Latin-1.
    static func systemCNF(_ sectors: DiscSectors) -> String? {
        guard let pvd = try? [UInt8](sectors.read(lba: 16, count: 1)), pvd[0] == 1, pvd[1..<6].elementsEqual("CD001".utf8) else { return nil }
        let root = Array(pvd[156..<190])
        let (rootLBA, rootSize) = (le32(root, 2), le32(root, 10))
        guard rootSize > 0, let directory = try? [UInt8](sectors.read(lba: rootLBA, count: (min(rootSize, maxDirectoryBytes) + 2047) / 2048)) else {
            return nil
        }
        var i = 0
        while i + 33 < directory.count {
            let length = Int(directory[i])
            if length == 0 { i = (i / 2048 + 1) * 2048; continue }
            guard length >= 34, i + length <= directory.count else { return nil }
            let nameLength = Int(directory[i + 32])
            if i + 33 + nameLength <= i + length {
                let name = String(decoding: directory[(i + 33)..<(i + 33 + nameLength)], as: UTF8.self).uppercased()
                if name == "SYSTEM.CNF;1" || name == "SYSTEM.CNF" {
                    let (lba, size) = (le32(directory, i + 2), min(le32(directory, i + 10), maxSystemCNFBytes))
                    guard size > 0, let data = try? sectors.read(lba: lba, count: (size + 2047) / 2048) else { return nil }
                    return String(decoding: data.prefix(size), as: UTF8.self)
                }
            }
            i += length
        }
        return nil
    }

    static func le32(_ bytes: [UInt8], _ offset: Int) -> Int {
        Int(bytes[offset]) | Int(bytes[offset + 1]) << 8 | Int(bytes[offset + 2]) << 16 | Int(bytes[offset + 3]) << 24
    }
}

/// MAME CHD v3-v5 header fields that identify a disc without decompressing it.
struct CHDInfo {
    /// Metadata tags in chain order, e.g. `CHGD` (GD-ROM track), `CHT2` (CD track), `DVD ` (DVD).
    var tags: [String]
    /// SHA-1 of the uncompressed data (v4/v5). For a DVD CHD it's the SHA-1 of the `.iso` Redump lists.
    var rawSHA1: String?
    var logicalBytes: UInt64

    static let gdromTags: Set<String> = ["CHGD", "CHGT"]

    /// Dreamcast for a GD-ROM, PS2 for a DVD (the only DVD system SupersEmu runs). CD CHDs can't be told apart this way.
    var system: SystemID? {
        if tags.contains(where: Self.gdromTags.contains) { return .dreamcast }
        if tags.contains("DVD ") { return .ps2 }
        return nil
    }

    init?(url: URL) {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let head = try? [UInt8](handle.read(upToCount: 124) ?? Data()), head.count >= 64,
              head[0..<8].elementsEqual("MComprHD".utf8) else { return nil }
        func be(_ bytes: [UInt8], _ offset: Int, _ count: Int) -> UInt64 {
            (0..<count).reduce(0) { $0 << 8 | UInt64(bytes[offset + $1]) }
        }
        let version = be(head, 12, 4)
        let metaOffset: UInt64
        switch version {
        case 3, 4:
            logicalBytes = be(head, 28, 8); metaOffset = be(head, 36, 8)
            rawSHA1 = version == 4 && head.count >= 108 ? Self.hex(head[88..<108]) : nil
        case 5 where head.count >= 104:
            logicalBytes = be(head, 32, 8); metaOffset = be(head, 48, 8)
            rawSHA1 = Self.hex(head[64..<84])
        default:
            return nil
        }
        let fileSize = (try? handle.seekToEnd()) ?? 0
        tags = []
        var offset = metaOffset
        var seen = Set<UInt64>()
        while offset != 0, offset + 16 <= fileSize, seen.insert(offset).inserted, tags.count < 256 {
            guard (try? handle.seek(toOffset: offset)) != nil, let entry = try? [UInt8](handle.read(upToCount: 16) ?? Data()), entry.count == 16 else { break }
            tags.append(String(decoding: entry[0..<4], as: UTF8.self))
            offset = be(entry, 8, 8)
        }
    }

    static func hex(_ bytes: ArraySlice<UInt8>) -> String? {
        bytes.allSatisfy({ $0 == 0 }) ? nil : bytes.map { String(format: "%02X", $0) }.joined()
    }
}
