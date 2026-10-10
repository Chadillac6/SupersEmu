import Foundation

/// Parser for the clrmamepro DAT text format used by libretro-database (`game ( name "…" rom ( crc … ) )`).
enum DatFile {
    /// A parenthesised block: scalar fields plus nested blocks (e.g. `rom`), in file order.
    struct Block {
        var fields: [String: String] = [:]
        var children: [(String, Block)] = []

        subscript(key: String) -> String? { fields[key] }
        func blocks(_ name: String) -> [Block] { children.filter { $0.0 == name }.map(\.1) }
    }

    /// Top-level `name ( … )` blocks. Malformed input yields whatever parsed cleanly before it.
    static func parse(_ text: String) -> [(String, Block)] {
        var tokens = Tokens(Array(text.utf8))
        var top: [(String, Block)] = []
        while let name = tokens.next() {
            guard tokens.next() == "(" else { break }
            guard let block = parseBlock(&tokens) else { break }
            top.append((name, block))
        }
        return top
    }

    private static func parseBlock(_ tokens: inout Tokens) -> Block? {
        var block = Block()
        while let key = tokens.next() {
            if key == ")" { return block }
            guard let value = tokens.next() else { return nil }
            if value == "(" {
                guard let child = parseBlock(&tokens) else { return nil }
                block.children.append((key, child))
            } else if block.fields[key] == nil {
                block.fields[key] = value
            }
        }
        return nil
    }

    private struct Tokens {
        let bytes: [UInt8]
        var index = 0
        init(_ bytes: [UInt8]) { self.bytes = bytes }

        mutating func next() -> String? {
            while index < bytes.count, bytes[index] <= 0x20 { index += 1 }
            guard index < bytes.count else { return nil }
            let byte = bytes[index]
            if byte == UInt8(ascii: "(") || byte == UInt8(ascii: ")") {
                index += 1
                return String(UnicodeScalar(byte))
            }
            if byte == UInt8(ascii: "\"") {
                let start = index + 1
                index = start
                while index < bytes.count, bytes[index] != UInt8(ascii: "\"") { index += 1 }
                defer { index += 1 }
                return String(decoding: bytes[start..<min(index, bytes.count)], as: UTF8.self)
            }
            let start = index
            while index < bytes.count, bytes[index] > 0x20, bytes[index] != UInt8(ascii: "("), bytes[index] != UInt8(ascii: ")") { index += 1 }
            return String(decoding: bytes[start..<index], as: UTF8.self)
        }
    }
}

/// One No-Intro/Redump entry from a libretro-database `metadat` DAT.
public struct DatEntry: Sendable, Equatable {
    public var name: String
    public var region: String?
    public var serial: String?
    public var crc: String?
    public var size: Int64?
}

/// Hash index over one system's DAT plus its `genre` / `releaseyear` / `publisher` supplements (keyed by CRC).
public struct DatIndex: Sendable {
    struct ROM: Sendable { var entry: Int; var size: Int64?; var crc: String?; var md5: String?; var sha1: String? }

    private(set) var entries: [DatEntry] = []
    private var bySHA1: [String: Int] = [:]
    private var byMD5: [String: Int] = [:]
    private var byCRC: [String: [ROM]] = [:]
    private var supplements: [String: [String: String]] = [:]
    private var supplementsBySerial: [String: [String: String]] = [:]

    public init(dat: String) {
        for (kind, game) in DatFile.parse(dat) where kind == "game" {
            guard let name = game["name"] else { continue }
            let roms = game.blocks("rom")
            let entry = entries.count
            entries.append(DatEntry(name: name, region: game["region"], serial: game["serial"],
                                    crc: roms.first?["crc"]?.uppercased(), size: roms.first?["size"].flatMap { Int64($0) }))
            for rom in roms {
                let record = ROM(entry: entry, size: rom["size"].flatMap { Int64($0) }, crc: rom["crc"]?.uppercased(),
                                 md5: rom["md5"]?.uppercased(), sha1: rom["sha1"]?.uppercased())
                if let sha1 = record.sha1, bySHA1[sha1] == nil { bySHA1[sha1] = entry }
                if let md5 = record.md5, byMD5[md5] == nil { byMD5[md5] = entry }
                if let crc = record.crc { byCRC[crc, default: []].append(record) }
            }
        }
    }

    /// Adds a supplement DAT whose games carry `field` (e.g. `genre`) and `rom ( crc … )`, or a `serial` (PlayStation).
    public mutating func addSupplement(field: String, dat: String) {
        var values: [String: String] = [:], bySerial: [String: String] = [:]
        for (kind, game) in DatFile.parse(dat) where kind == "game" {
            guard let value = game[field], !value.isEmpty else { continue }
            if let serial = game["serial"]?.uppercased(), bySerial[serial] == nil { bySerial[serial] = value }
            for rom in game.blocks("rom") {
                if let crc = rom["crc"]?.uppercased(), values[crc] == nil { values[crc] = value }
                if let serial = rom["serial"]?.uppercased(), bySerial[serial] == nil { bySerial[serial] = value }
            }
        }
        supplements[field] = values
        supplementsBySerial[field] = bySerial
    }

    /// SHA-1 first, then MD5, then CRC32 with a matching size (CRC alone is too weak).
    public func match(_ hashes: ROMHashes) -> DatEntry? {
        if let index = bySHA1[hashes.sha1] ?? byMD5[hashes.md5] { return entries[index] }
        if let rom = byCRC[hashes.crc]?.first(where: { $0.size == nil || $0.size == hashes.size }) { return entries[rom.entry] }
        return nil
    }

    public func supplement(_ field: String, crc: String?, serial: String? = nil) -> String? {
        crc.flatMap { supplements[field]?[$0] } ?? serial.flatMap { supplementsBySerial[field]?[$0.uppercased()] }
    }
}

/// Turns No-Intro/Redump names into what the shelf shows.
public enum CanonicalName {
    /// "Legend of Zelda, The - A Link to the Past (USA) (Rev 1)" -> "The Legend of Zelda - A Link to the Past".
    public static func title(_ name: String) -> String {
        var base = ""
        var depth = 0
        for character in name {
            if character == "(" || character == "[" { depth += 1; continue }
            if character == ")" || character == "]" { depth = max(0, depth - 1); continue }
            if depth == 0 { base.append(character) }
        }
        base = base.split(separator: " ", omittingEmptySubsequences: true).joined(separator: " ")
        var parts = base.components(separatedBy: " - ")
        for article in ["The", "A", "An"] where parts[0].hasSuffix(", \(article)") {
            parts[0] = article + " " + parts[0].dropLast(article.count + 2)
        }
        let title = parts.joined(separator: " - ").trimmingCharacters(in: .whitespaces)
        return title.isEmpty ? name : title
    }

    /// The first parenthesised group, which No-Intro and Redump use for region ("USA", "Japan, USA").
    public static func region(_ name: String) -> String? {
        guard let open = name.firstIndex(of: "("), let close = name[open...].firstIndex(of: ")") else { return nil }
        let value = name[name.index(after: open)..<close].trimmingCharacters(in: .whitespaces)
        return value.isEmpty ? nil : value
    }

    /// libretro-thumbnails file stem: `&*/:\`<>?\|"` become `_`.
    public static func thumbnailName(_ name: String) -> String {
        String(name.map { "&*/:`<>?\\|\"".contains($0) ? "_" : $0 })
    }

    /// "Final Fantasy VII (USA) (Disc 1)" -> "Final Fantasy VII (USA)", for thumbnails named per set.
    public static func withoutDiscNumber(_ name: String) -> String? {
        guard let range = name.range(of: #" \(Disc [0-9]+\)"#, options: .regularExpression) else { return nil }
        return name.replacingCharacters(in: range, with: "")
    }
}
