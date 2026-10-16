import Foundation

// Track: cheats. Game Genie codes saved per game (ROM SHA-256), kept on each device and synced per user.

public enum CheatFormat: String, Codable, Sendable, CaseIterable {
    case snesGameGenie, genesisGameGenie, proActionReplay, unknown

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = CheatFormat(rawValue: raw) ?? .unknown
    }

    public var displayName: String {
        switch self {
        case .snesGameGenie: "SNES Game Genie"
        case .genesisGameGenie: "Genesis Game Genie"
        case .proActionReplay: "Pro Action Replay"
        case .unknown: "Unknown"
        }
    }
}

public struct CheatRecord: Codable, Sendable, Identifiable, Equatable, Hashable {
    public var id: UUID
    public var gameID: String
    public var label: String
    public var code: String
    public var format: CheatFormat
    public var enabled: Bool
    public var createdAt: Date
    public var labelUpdatedAt: Date
    public var codeUpdatedAt: Date
    public var enabledUpdatedAt: Date
    public var deleted: Bool
    public var deletedAt: Date?
    /// Assigned by the server; 0 until the record has been uploaded.
    public var revision: Int

    public init(id: UUID = UUID(), gameID: String, label: String, code: String, format: CheatFormat,
                enabled: Bool = true, now: Date = CheatRecord.now()) {
        self.id = id
        self.gameID = gameID
        self.label = label
        self.code = code
        self.format = format
        self.enabled = enabled
        createdAt = now
        labelUpdatedAt = now
        codeUpdatedAt = now
        enabledUpdatedAt = now
        deleted = false
        deletedAt = nil
        revision = 0
    }

    /// Whole seconds: the JSON date format drops fractions, so every device and the server compare the same values.
    public static func now(_ date: Date = Date()) -> Date { Date(timeIntervalSince1970: date.timeIntervalSince1970.rounded(.down)) }

    // Timestamps are whole seconds, so each local change is stamped strictly after the one it follows:
    // an edit right after a delete revives the cheat, and a delete right after an edit sticks.
    public mutating func setLabel(_ value: String, at date: Date = CheatRecord.now()) {
        label = value; labelUpdatedAt = stamp(date, after: labelUpdatedAt)
    }
    public mutating func setCode(_ value: String, format: CheatFormat, at date: Date = CheatRecord.now()) {
        code = value; self.format = format; codeUpdatedAt = stamp(date, after: codeUpdatedAt)
    }
    public mutating func setEnabled(_ value: Bool, at date: Date = CheatRecord.now()) {
        enabled = value; enabledUpdatedAt = stamp(date, after: enabledUpdatedAt)
    }
    public mutating func markDeleted(at date: Date = CheatRecord.now()) {
        let lastEdit = [labelUpdatedAt, codeUpdatedAt, enabledUpdatedAt].max()!
        deleted = true
        deletedAt = max(date, lastEdit.addingTimeInterval(1), deletedAt ?? .distantPast)
    }

    private func stamp(_ date: Date, after previous: Date) -> Date {
        guard let deletedAt else { return max(date, previous) }
        return max(date, previous, deletedAt.addingTimeInterval(1))
    }

    public var updatedAt: Date { [labelUpdatedAt, codeUpdatedAt, enabledUpdatedAt, deletedAt ?? .distantPast].max()! }

    enum CodingKeys: String, CodingKey {
        case id, gameID, label, code, format, enabled, createdAt, labelUpdatedAt, codeUpdatedAt, enabledUpdatedAt
        case deleted, deletedAt, revision
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        gameID = try c.decode(String.self, forKey: .gameID)
        label = try c.decodeIfPresent(String.self, forKey: .label) ?? ""
        code = try c.decode(String.self, forKey: .code)
        format = try c.decodeIfPresent(CheatFormat.self, forKey: .format) ?? .unknown
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date(timeIntervalSince1970: 0)
        labelUpdatedAt = try c.decodeIfPresent(Date.self, forKey: .labelUpdatedAt) ?? createdAt
        codeUpdatedAt = try c.decodeIfPresent(Date.self, forKey: .codeUpdatedAt) ?? createdAt
        enabledUpdatedAt = try c.decodeIfPresent(Date.self, forKey: .enabledUpdatedAt) ?? createdAt
        deleted = try c.decodeIfPresent(Bool.self, forKey: .deleted) ?? false
        deletedAt = try c.decodeIfPresent(Date.self, forKey: .deletedAt)
        revision = try c.decodeIfPresent(Int.self, forKey: .revision) ?? 0
    }
}

public struct CheatListResponse: Codable, Sendable, Equatable {
    public var cheats: [CheatRecord]
    /// Highest revision the server has handed out for this user; pass it back as `since`.
    public var revision: Int
    public init(cheats: [CheatRecord], revision: Int) { self.cheats = cheats; self.revision = revision }
}

// MARK: - Merge

public enum CheatMerge {
    /// Field-level merge: name, code and on/off each keep their newest edit. A delete wins over edits made
    /// before it; an edit made after the delete brings the cheat back. On equal times `incoming` wins.
    public static func merge(_ current: CheatRecord, _ incoming: CheatRecord) -> CheatRecord {
        var out = current
        if incoming.labelUpdatedAt >= current.labelUpdatedAt { out.label = incoming.label; out.labelUpdatedAt = incoming.labelUpdatedAt }
        if incoming.codeUpdatedAt >= current.codeUpdatedAt {
            out.code = incoming.code; out.format = incoming.format; out.codeUpdatedAt = incoming.codeUpdatedAt
        }
        if incoming.enabledUpdatedAt >= current.enabledUpdatedAt {
            out.enabled = incoming.enabled; out.enabledUpdatedAt = incoming.enabledUpdatedAt
        }
        out.createdAt = min(current.createdAt, incoming.createdAt)
        let deletedAt = [current.deletedAt, incoming.deletedAt].compactMap { $0 }.max()
        out.deletedAt = deletedAt
        let lastEdit = [out.labelUpdatedAt, out.codeUpdatedAt, out.enabledUpdatedAt].max()!
        out.deleted = deletedAt.map { $0 >= lastEdit } ?? false
        out.revision = max(current.revision, incoming.revision)
        return out
    }
}

// MARK: - Codec

public enum CheatParseResult: Equatable, Sendable {
    case valid(format: CheatFormat, normalized: String, address: UInt32, value: UInt16)
    case invalid(reason: String)
    case unsupported(detected: CheatFormat, normalized: String, reason: String)

    public var isValid: Bool { if case .valid = self { return true }; return false }
    public var normalized: String? {
        switch self {
        case .valid(_, let code, _, _), .unsupported(_, let code, _): code
        case .invalid: nil
        }
    }
    public var format: CheatFormat {
        switch self {
        case .valid(let format, _, _, _): format
        case .unsupported(let format, _, _): format
        case .invalid: .unknown
        }
    }
}

public struct CheatBatchEntry: Equatable, Sendable, Identifiable {
    public var id: Int
    public var label: String
    public var input: String
    public var result: CheatParseResult
    public var include: Bool
}

public enum CheatCodec {
    /// Systems with cheat support in SupersEmu, and the Game Genie format each one takes.
    public static func gameGenieFormat(for system: SystemID) -> CheatFormat? {
        switch system {
        case .snes: .snesGameGenie
        case .genesis: .genesisGameGenie
        default: nil
        }
    }

    public static func supportsCheats(_ system: SystemID) -> Bool { gameGenieFormat(for: system) != nil }

    static let snesGenieHex = Array("DF4709156BC8A23E")
    static let genesisAlphabet = Array("ABCDEFGHJKLMNPRSTVWXYZ0123456789")
    static let hexDigits = Set("0123456789ABCDEF")

    /// Uppercases, drops spaces and inserts the dash in 8-character Game Genie codes.
    public static func normalize(_ input: String) -> String {
        let compact = input.uppercased().filter { !$0.isWhitespace }
        if compact.count == 8, !compact.contains("-"), !compact.contains(":") {
            return String(compact.prefix(4)) + "-" + String(compact.suffix(4))
        }
        return compact
    }

    public static func parse(_ input: String, system: SystemID) -> CheatParseResult {
        let code = normalize(input)
        guard let expected = gameGenieFormat(for: system) else {
            return .invalid(reason: "Cheats aren't supported for this system yet.")
        }
        if code.isEmpty { return .invalid(reason: "Enter a code.") }
        let snes = decodeSNES(code), genesis = decodeGenesis(code)
        switch expected {
        case .snesGameGenie:
            if let (address, value) = snes { return .valid(format: .snesGameGenie, normalized: code, address: address, value: UInt16(value)) }
            if genesis != nil {
                return .unsupported(detected: .genesisGameGenie, normalized: code,
                                    reason: "This looks like a Genesis Game Genie code, so it won't work in an SNES game.")
            }
        case .genesisGameGenie:
            // Every SNES Game Genie character is also in the Genesis alphabet, so an SNES code can't be told apart here.
            if let (address, value) = genesis { return .valid(format: .genesisGameGenie, normalized: code, address: address, value: value) }
        default: break
        }
        if isProActionReplay(code, system: system) {
            return .unsupported(detected: .proActionReplay, normalized: code,
                                reason: "Pro Action Replay codes aren't supported yet. Only Game Genie codes are.")
        }
        return .invalid(reason: invalidReason(code, expected: expected))
    }

    static func invalidReason(_ code: String, expected: CheatFormat) -> String {
        let shape = expected == .snesGameGenie ? "SNES Game Genie codes use 0–9 and A–F, as XXXX-XXXX."
                                               : "Genesis Game Genie codes look like XXXX-XXXX (no I, O, Q or U)."
        let body = code.replacingOccurrences(of: "-", with: "")
        if body.count != 8 || (code.contains("-") && code.firstIndex(of: "-") != code.index(code.startIndex, offsetBy: 4)) {
            return "Wrong length: \(body.count) characters. " + shape
        }
        let allowed: Set<Character> = expected == .snesGameGenie ? hexDigits : Set(genesisAlphabet)
        if let bad = body.first(where: { !allowed.contains($0) }) { return "\"\(bad)\" isn't allowed here. " + shape }
        return shape
    }

    static func gameGenieBody(_ code: String) -> [Character]? {
        let chars = Array(code)
        guard chars.count == 9, chars[4] == "-" else { return nil }
        return Array(chars[0..<4] + chars[5..<9])
    }

    /// Matches Snes9x's S9xGameGenieToRaw.
    static func decodeSNES(_ code: String) -> (UInt32, UInt8)? {
        guard let body = gameGenieBody(code), body.allSatisfy({ hexDigits.contains($0) }) else { return nil }
        var data: UInt32 = 0
        for c in body {
            let index = snesGenieHex.firstIndex(of: c)!
            data = data << 4 | UInt32(index)
        }
        let byte = UInt8(data >> 24)
        let a = data & 0xFFFFFF
        let address = ((a & 0x003C00) << 10) + ((a & 0x00003C) << 14) + ((a & 0xF00000) >> 8) + ((a & 0x000003) << 10)
            + ((a & 0x00C000) >> 6) + ((a & 0x0F0000) >> 12) + ((a & 0x0003C0) >> 6)
        return (address, byte)
    }

    /// Matches Genesis Plus GX's decode_cheat (Game Genie branch).
    static func decodeGenesis(_ code: String) -> (UInt32, UInt16)? {
        guard let body = gameGenieBody(code) else { return nil }
        var address: UInt32 = 0, data: UInt32 = 0
        for (i, c) in body.enumerated() {
            guard let index = genesisAlphabet.firstIndex(of: c) else { return nil }
            let n = UInt32(index)
            switch i {
            case 0: data |= n << 3
            case 1: data |= n >> 2; address |= (n & 3) << 14
            case 2: address |= n << 9
            case 3: address |= (n & 0xF) << 20 | (n >> 4) << 8
            case 4: data |= (n & 1) << 12; address |= (n >> 1) << 16
            case 5: data |= (n & 1) << 15 | (n >> 1) << 8
            case 6: data |= (n >> 3) << 13; address |= (n & 7) << 5
            default: address |= n
            }
        }
        return (address, UInt16(truncatingIfNeeded: data))
    }

    static func isProActionReplay(_ code: String, system: SystemID) -> Bool {
        // 8 bare hex digits are read as a Game Genie code missing its dash, so only the colon forms count here.
        let digits = code.replacingOccurrences(of: ":", with: "")
        guard code.contains(":"), digits.allSatisfy({ hexDigits.contains($0) }) else { return false }
        switch system {
        case .snes: return digits.count == 8
        case .genesis: return digits.count == 10
        default: return false
        }
    }

    /// One code per line (or `+`-joined). Text around the code on the line becomes the name.
    public static func parseBatch(_ text: String, system: SystemID, existingCount: Int = 0) -> [CheatBatchEntry] {
        var entries: [CheatBatchEntry] = []
        for line in text.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }
            let (code, label) = splitLine(trimmed, system: system)
            for part in code.split(separator: "+") {
                let result = parse(String(part), system: system)
                let n = existingCount + entries.count + 1
                entries.append(CheatBatchEntry(id: entries.count, label: label.isEmpty ? "Cheat \(n)" : label,
                                               input: String(part), result: result, include: result.isValid))
            }
        }
        return entries
    }

    static func splitLine(_ line: String, system: SystemID) -> (code: String, label: String) {
        let words = line.split(separator: " ").map(String.init)
        if let index = words.firstIndex(where: { looksLikeCode($0, system: system) }) {
            var rest = words
            let code = rest.remove(at: index)
            return (code, rest.joined(separator: " ").trimmingCharacters(in: CharacterSet(charactersIn: " -–:\t")))
        }
        return (words.first ?? line, words.dropFirst().joined(separator: " "))
    }

    static func looksLikeCode(_ word: String, system: SystemID) -> Bool {
        let w = word.uppercased()
        if w.count == 9, Array(w)[4] == "-" { return true }
        if w.count == 8, w.allSatisfy({ hexDigits.contains($0) }) { return true }
        if system == .genesis, w.count == 8, w.allSatisfy({ genesisUndashed.contains($0) }) { return true }
        if w.contains("+") { return true }
        return w.count == 11 && w.contains(":")
    }

    private static let genesisUndashed = Set("ABCDEFGHJKLMNPRSTVWXYZ0123456789")

    public static func defaultLabel(index: Int) -> String { "Cheat \(index)" }
}
