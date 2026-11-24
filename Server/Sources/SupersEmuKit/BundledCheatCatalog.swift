import Foundation

public struct BundledCheatCatalog: Decodable, Sendable {
    public struct Match: Equatable, Sendable {
        public enum Quality: Equatable, Sendable { case exactROM, verifiedOnROM }

        public let label: String
        public let codes: [String]
        public let quality: Quality
    }

    private struct Entry: Decodable, Sendable {
        let label: String
        let codes: [String]

        init(from decoder: Decoder) throws {
            var row = try decoder.unkeyedContainer()
            label = try row.decode(String.self)
            var codes = [String]()
            while !row.isAtEnd { codes.append(try row.decode(String.self)) }
            guard !label.isEmpty, !codes.isEmpty else {
                throw DecodingError.dataCorruptedError(in: row, debugDescription: "Missing cheat label or code")
            }
            self.codes = codes
        }
    }

    private struct Revision: Decodable, Sendable {
        let family: String?
        let cheats: [Entry]?
    }

    private struct System: Decodable, Sendable {
        let revisions: [String: Revision]
        let families: [String: [String]]
    }

    private let systems: [String: System]

    private enum CodingKeys: CodingKey { case version, systems }

    public init(from decoder: Decoder) throws {
        let payload = try decoder.container(keyedBy: CodingKeys.self)
        guard try payload.decode(Int.self, forKey: .version) == 1 else {
            throw DecodingError.dataCorruptedError(forKey: .version, in: payload, debugDescription: "Unknown cheat catalog version")
        }
        systems = try payload.decode([String: System].self, forKey: .systems)
    }

    public static func supports(_ system: SystemID) -> Bool {
        switch system {
        case .snes, .genesis, .sega32x, .gb, .gbc: true
        default: false
        }
    }

    public func resolve(system: SystemID, rom: Data, sha1: (Data) -> String) -> [Match] {
        let catalogSystems: [SystemID]
        switch system {
        case .gb: catalogSystems = [.gb, .gbc]
        case .gbc: catalogSystems = [.gbc, .gb]
        default: catalogSystems = [system]
        }
        let catalogs = catalogSystems.compactMap { systems[$0.rawValue] }
        guard !catalogs.isEmpty else { return [] }
        var hash = sha1(rom).uppercased()
        if !catalogs.contains(where: { $0.revisions[hash] != nil }),
           let normalized = normalizedCopy(rom, system: system) {
            hash = sha1(normalized).uppercased()
        }
        if let entries = catalogs.lazy.compactMap({ $0.revisions[hash]?.cheats }).first {
            return entries.map { Match(label: $0.label, codes: $0.codes, quality: .exactROM) }
        }
        guard system == .gb || system == .gbc else { return [] }
        var matches = [Match]()
        var effects = Set<String>()
        var groups = Set<[String]>()
        for catalog in catalogs {
            guard let family = catalog.revisions[hash]?.family,
                  let candidates = catalog.families[family] else { continue }
            for candidate in candidates where candidate != hash {
                for entry in catalog.revisions[candidate]?.cheats ?? [] {
                    let effect = entry.label.lowercased()
                    guard !effects.contains(effect), !groups.contains(entry.codes),
                          GameBoyGeniePatch.verifies(entry.codes, in: rom) else { continue }
                    effects.insert(effect)
                    groups.insert(entry.codes)
                    matches.append(Match(label: entry.label, codes: entry.codes, quality: .verifiedOnROM))
                }
            }
        }
        return matches
    }

    private func normalizedCopy(_ rom: Data, system: SystemID) -> Data? {
        if system == .snes, rom.count % 1024 == 512 { return Data(rom.dropFirst(512)) }
        guard system == .genesis || system == .sega32x, rom.count > 512, rom.count % 0x4000 == 512 else { return nil }
        return rom.withUnsafeBytes { (source: UnsafeRawBufferPointer) in
            var data = Data(count: rom.count - 512)
            data.withUnsafeMutableBytes { (target: UnsafeMutableRawBufferPointer) in
                for block in stride(from: 512, to: rom.count, by: 0x4000) {
                    for i in 0..<0x2000 {
                        target[block - 512 + i * 2] = source[block + 0x2000 + i]
                        target[block - 512 + i * 2 + 1] = source[block + i]
                    }
                }
            }
            return data
        }
    }
}

public enum CheatApplicationOutcome: Equatable {
    case applied, sent, rejected

    public static func replace(_ groups: [[String]], send: ([String]) -> [Self]) -> [Self] {
        var remaining = groups.indices.filter { !groups[$0].isEmpty }
        var outcomes = Array(repeating: Self.rejected, count: groups.count)
        while true {
            let result = send(remaining.flatMap { groups[$0] })
            var offset = 0
            var rejectedGroups = Set<Int>()
            for index in remaining {
                let end = offset + groups[index].count
                let group = result[offset..<min(end, result.count)]
                if group.count != groups[index].count || group.contains(.rejected) {
                    outcomes[index] = .rejected
                    if groups[index].count > 1 { rejectedGroups.insert(index) }
                } else {
                    outcomes[index] = group.contains(.sent) ? .sent : .applied
                }
                offset = min(end, result.count)
            }
            if rejectedGroups.isEmpty { return outcomes }
            remaining.removeAll(where: rejectedGroups.contains)
        }
    }
}

struct GameBoyGeniePatch: Equatable {
    let address: Int
    let value: UInt8
    let compare: UInt8?

    init?(_ code: String) {
        guard let digits = CheatCodec.gameBoyGameGenieBody(code) else { return nil }
        let nibbles = digits.map { $0.hexDigitValue! }
        value = UInt8((nibbles[0] << 4) | nibbles[1])
        address = ((nibbles[2] << 8) | (nibbles[3] << 4) | nibbles[4] | ((nibbles[5] ^ 0xF) << 12)) & 0x7FFF
        if nibbles.count == 9 {
            let encoded = UInt8((nibbles[6] << 4) | nibbles[8]) ^ 0xFF
            compare = ((encoded >> 2) | (encoded << 6)) ^ 0x45
        } else {
            compare = nil
        }
    }

    static func verifies(_ codes: [String], in rom: Data) -> Bool {
        guard !codes.isEmpty, rom.count >= 0x8000, rom.count.isMultiple(of: 0x4000) else { return false }
        return rom.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) in
            let bankCount = bytes.count / 0x4000
            switch bytes[0x147] {
            case 0x00: guard bankCount == 2 else { return false }
            case 0x01...0x03, 0x05...0x06, 0x08...0x09, 0x0F...0x13, 0x19...0x1E, 0xEA, 0xFE...0xFF: break
            default: return false
            }
            var written = [Int: UInt8]()
            return codes.allSatisfy { code in
                guard let patch = GameBoyGeniePatch(code), let compare = patch.compare else { return false }
                let banks = patch.address < 0x4000 ? 0..<1 : 1..<bankCount
                var matched = false
                for bank in banks {
                    let offset = bank * 0x4000 + (patch.address & 0x3FFF)
                    if bytes[offset] == compare, (written[offset] ?? bytes[offset]) == compare {
                        written[offset] = patch.value
                        matched = true
                    }
                }
                return matched
            }
        }
    }
}
