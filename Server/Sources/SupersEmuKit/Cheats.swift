import Foundation

// Track cheats per game (ROM SHA-256), kept on each device and synced per user.

public enum CheatFormat: String, Codable, Sendable, CaseIterable {
    case snesGameGenie, genesisGameGenie, proActionReplay
    case gbGameGenie, gbGameShark, gbaCode, gbaCodeBreaker, psxGameShark, n64GameShark
    case unknown

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = CheatFormat(rawValue: raw) ?? .unknown
    }

    public var displayName: String {
        switch self {
        case .snesGameGenie: "SNES Game Genie"
        case .genesisGameGenie: "Genesis Game Genie"
        case .proActionReplay: "Pro Action Replay"
        case .gbGameGenie: "Game Boy Game Genie"
        case .gbGameShark: "Game Boy GameShark"
        case .gbaCode: "GBA GameShark / Action Replay"
        case .gbaCodeBreaker: "GBA CodeBreaker"
        case .psxGameShark: "PS1 GameShark"
        case .n64GameShark: "N64 GameShark"
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
    // an edit right after a delete this device knows about revives the cheat. Deletes win ties.
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
        // A tie with the last edit already counts as deleted in `CheatMerge`, so no artificial bump is needed.
        deletedAt = max(date, lastEdit, deletedAt ?? .distantPast)
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
            out.code = incoming.code
            if incoming.format != .unknown || incoming.code != current.code { out.format = incoming.format }
            out.codeUpdatedAt = incoming.codeUpdatedAt
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
    public static let maxCodeLength = 240

    public static func formats(for system: SystemID) -> [CheatFormat] {
        switch system {
        case .snes: [.snesGameGenie, .proActionReplay]
        case .genesis, .sega32x: [.genesisGameGenie, .proActionReplay]
        case .segacd: [.proActionReplay]
        case .gb, .gbc: [.gbGameGenie, .gbGameShark]
        case .gba: [.gbaCode, .gbaCodeBreaker]
        case .psx: [.psxGameShark]
        case .n64: [.n64GameShark]
        }
    }

    public static func supportsCheats(_ system: SystemID) -> Bool { !formats(for: system).isEmpty }

    static let snesGenieHex = Array("DF4709156BC8A23E")
    static let genesisAlphabet = Array("ABCDEFGHJKLMNPRSTVWXYZ0123456789")
    static let hexDigits = Set("0123456789ABCDEF")
    private static let psxGameSharkTypes: Set<UInt8> = [
        0x10, 0x11, 0x20, 0x21, 0x30, 0x50, 0x80, 0xC2,
        0xD0, 0xD1, 0xD2, 0xD3, 0xE0, 0xE1, 0xE2, 0xE3,
    ]

    public static func normalize(_ input: String, system: SystemID) -> String {
        if isLineBased(system) {
            let separators = CharacterSet.newlines.union(CharacterSet(charactersIn: ";,"))
            return input.components(separatedBy: separators)
                .map(normalizeLine)
                .filter { !$0.isEmpty }
                .joined(separator: "\n")
        }
        let compact = input.uppercased().filter { !$0.isWhitespace }
        if system == .gb || system == .gbc {
            if (compact.count == 6 || compact.count == 9), compact.allSatisfy({ hexDigits.contains($0) }) {
                return compact.count == 6
                    ? String(compact.prefix(3)) + "-" + String(compact.suffix(3))
                    : String(compact.prefix(3)) + "-" + String(compact.dropFirst(3).prefix(3)) + "-" + String(compact.suffix(3))
            }
            return compact
        }
        if compact.count == 8, !compact.contains("-"), !compact.contains(":") {
            return String(compact.prefix(4)) + "-" + String(compact.suffix(4))
        }
        return compact
    }

    public static func coreCode(_ normalized: String) -> String {
        normalized.replacingOccurrences(of: "\n", with: " ")
    }

    public static func parse(_ input: String, system: SystemID) -> CheatParseResult {
        let code = normalize(input, system: system)
        guard !formats(for: system).isEmpty else {
            return .invalid(reason: "Cheats aren't supported for this system yet.")
        }
        if code.isEmpty { return .invalid(reason: "Enter a code.") }
        if coreCode(code).utf8.count > maxCodeLength {
            return .invalid(reason: "Codes may not exceed 240 characters when sent to the core.")
        }

        switch system {
        case .snes:
            if let (address, value) = decodeSNES(code) {
                return .valid(format: .snesGameGenie, normalized: code, address: address, value: UInt16(value))
            }
            if decodeGenesis(code) != nil {
                return .unsupported(detected: .genesisGameGenie, normalized: code,
                                    reason: "This looks like a Genesis Game Genie code, so it won't work in an SNES game.")
            }
            if let (address, value) = decodeProActionReplay(code, system: system) {
                return .valid(format: .proActionReplay, normalized: code, address: address, value: value)
            }
        case .genesis, .sega32x:
            // Every SNES Game Genie character is also in the Genesis alphabet, so an SNES code can't be told apart here.
            if let (address, value) = decodeGenesis(code) {
                return .valid(format: .genesisGameGenie, normalized: code, address: address, value: value)
            }
            if let (address, value) = decodeProActionReplay(code, system: system) {
                return .valid(format: .proActionReplay, normalized: code, address: address, value: value)
            }
        case .segacd:
            if let (address, value) = decodeProActionReplay(code, system: system) {
                return .valid(format: .proActionReplay, normalized: code, address: address, value: value)
            }
            if decodeGenesis(code) != nil {
                return .unsupported(
                    detected: .genesisGameGenie,
                    normalized: code,
                    reason: "Game Genie codes patch a cartridge, and Sega CD games run from a disc. Use Pro Action Replay codes (XXXXXX:XXXX)."
                )
            }
        case .gb, .gbc:
            if let result = parseGameBoy(code) { return result }
        case .gba:
            if let result = parseLineCodes(code, system: system) { return result }
        case .psx:
            if let result = parseLineCodes(code, system: system) { return result }
        case .n64:
            if let result = parseLineCodes(code, system: system) { return result }
        }
        return .invalid(reason: invalidReason(code, system: system))
    }

    static func invalidReason(_ code: String, system: SystemID) -> String {
        if code.contains(":") {
            switch system {
            case .snes: return "SNES Pro Action Replay codes use AAAAAA:VV (6 address hex digits and 2 value hex digits)."
            case .genesis, .sega32x: return "Pro Action Replay codes use AAAAAA:VVVV (6 address hex digits and 4 value hex digits)."
            case .segacd: return "Sega CD Pro Action Replay codes use AAAAAA:VVVV."
            default: break
            }
        }
        switch system {
        case .snes:
            let shape = "SNES Game Genie codes use 0–9 and A–F, as XXXX-XXXX."
            return invalidGameGenieReason(code, expected: .snesGameGenie, shape: shape)
        case .genesis, .sega32x:
            let shape = "Genesis Game Genie codes look like XXXX-XXXX (no I, O, Q or U)."
            return invalidGameGenieReason(code, expected: .genesisGameGenie, shape: shape)
        case .segacd:
            return "Sega CD supports Pro Action Replay codes in AAAAAA:VVVV form."
        case .gb, .gbc:
            if code.contains("-") || code.count == 6 || code.count == 9 {
                return "Game Boy Game Genie codes use XXX-XXX or XXX-XXX-XXX with hex digits."
            }
            return "Game Boy GameShark codes use 01VVAAAA (8 hex digits)."
        case .gba:
            return "GBA codes use one or more lines of XXXXXXXX XXXXXXXX or XXXXXXXX XXXX."
        case .psx:
            return "PS1 GameShark codes use lines of XXXXXXXX XXXX with a supported code type."
        case .n64:
            return "N64 GameShark codes use one or more lines of XXXXXXXX XXXX."
        }
    }

    static func invalidGameGenieReason(_ code: String, expected: CheatFormat, shape: String) -> String {
        let body = code.replacingOccurrences(of: "-", with: "")
        if body.count != 8 || (code.contains("-") && code.firstIndex(of: "-") != code.index(code.startIndex, offsetBy: 4)) {
            return "Wrong length: \(body.count) characters. " + shape
        }
        let allowed: Set<Character> = expected == .snesGameGenie ? hexDigits : Set(genesisAlphabet)
        if let bad = body.first(where: { !allowed.contains($0) }) { return "\"\(bad)\" isn't allowed here. " + shape }
        return shape
    }

    static func normalizeLine(_ raw: String) -> String {
        raw.split(separator: "+", omittingEmptySubsequences: false)
            .map { part in
                let upper = part.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
                let words = upper.split(whereSeparator: \.isWhitespace).map(String.init)
                guard !words.isEmpty else { return "" }
                let compact = words.joined()
                if (compact.count == 12 || compact.count == 16), compact.allSatisfy({ hexDigits.contains($0) }) {
                    return String(compact.prefix(8)) + " " + String(compact.dropFirst(8))
                }
                return words.joined(separator: " ")
            }
            .joined(separator: "+")
    }

    static func isLineBased(_ system: SystemID) -> Bool {
        system == .gba || system == .psx || system == .n64
    }

    static func parseGameBoy(_ code: String) -> CheatParseResult? {
        if code.count == 8, code.allSatisfy({ hexDigits.contains($0) }) {
            if code.hasPrefix("01") {
                let chars = Array(code)
                let value = UInt16(String(chars[2..<4]), radix: 16)!
                let address = UInt32(String(chars[4..<8]), radix: 16)!
                return .valid(format: .gbGameShark, normalized: code, address: address, value: value)
            }
            return .unsupported(
                detected: .gbGameShark,
                normalized: code,
                reason: "Only GameShark codes starting with 01 work for Game Boy."
            )
        }
        guard let chars = gameBoyGameGenieBody(code) else { return nil }
        let value = UInt8((hexValue(chars[0])! << 4) | hexValue(chars[1])!)
        let address = ((hexValue(chars[2])! << 8)
            | (hexValue(chars[4])! << 4)
            | hexValue(chars[5])!
            | ((hexValue(chars[6])! ^ 0xF) << 12)) & 0x7FFF
        return .valid(format: .gbGameGenie, normalized: code, address: address, value: UInt16(value))
    }

    static func gameBoyGameGenieBody(_ code: String) -> [Character]? {
        let chars = Array(code)
        guard (chars.count == 7 || chars.count == 11), chars[3] == "-" else { return nil }
        if chars.count == 11, chars[7] != "-" { return nil }
        let body = chars.filter { $0 != "-" }
        guard body.count == (chars.count == 7 ? 6 : 9), body.allSatisfy({ hexDigits.contains($0) }) else { return nil }
        return chars
    }

    static func hexValue(_ character: Character) -> UInt32? {
        guard hexDigits.contains(character) else { return nil }
        return UInt32(String(character), radix: 16)
    }

    static func parseLineCodes(_ code: String, system: SystemID) -> CheatParseResult? {
        let lines = code.split(separator: "\n").map(String.init)
        guard !lines.isEmpty else { return nil }
        let parsedLines = lines.map { $0.split(whereSeparator: \.isWhitespace).map(String.init) }

        if system == .gba {
            guard parsedLines.allSatisfy({ parts in
                parts.count == 2 && parts[0].count == 8 && [4, 8].contains(parts[1].count)
                    && parts.joined().allSatisfy({ hexDigits.contains($0) })
            }) else { return nil }
            let first = parsedLines[0]
            let format: CheatFormat = first[1].count == 8 ? .gbaCode : .gbaCodeBreaker
            let address = UInt32(first[0], radix: 16)!
            let value = UInt16(String(first[1].suffix(4)), radix: 16)!
            return .valid(format: format, normalized: code, address: address, value: value)
        }

        guard parsedLines.allSatisfy({ parts in
            parts.count == 2 && parts[0].count == 8 && parts[1].count == 4
                && parts.joined().allSatisfy({ hexDigits.contains($0) })
        }) else { return nil }

        let first = parsedLines[0]
        let address = UInt32(first[0], radix: 16)!
        let value = UInt16(first[1], radix: 16)!
        if system == .psx {
            for parts in parsedLines {
                let type = UInt8(parts[0].prefix(2), radix: 16)!
                guard psxGameSharkTypes.contains(type) else {
                    return .unsupported(
                        detected: .psxGameShark,
                        normalized: code,
                        reason: String(format: "PS1 GameShark code type 0x%02X is not supported.", type)
                    )
                }
            }
            return .valid(format: .psxGameShark, normalized: code, address: address, value: value)
        }
        return .valid(format: .n64GameShark, normalized: code, address: address, value: value)
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

    static func decodeProActionReplay(_ code: String, system: SystemID) -> (UInt32, UInt16)? {
        let parts = code.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2, parts.allSatisfy({ $0.allSatisfy({ hexDigits.contains($0) }) }) else { return nil }
        let valueLength = system == .snes ? 2 : 4
        guard parts[0].count == 6, parts[1].count == valueLength,
              let address = UInt32(parts[0], radix: 16), let value = UInt16(parts[1], radix: 16) else { return nil }
        return (address, value)
    }

    static func isProActionReplayShape(_ code: String, system: SystemID) -> Bool {
        let parts = code.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2 else { return false }
        switch system {
        case .snes: return parts[0].count == 6 && parts[1].count == 2
        case .genesis, .sega32x, .segacd: return parts[0].count == 6 && parts[1].count == 4
        default: return false
        }
    }

    /// One code per line (or `+`-joined). Text around the code on the line becomes the name.
    public static func parseBatch(_ text: String, system: SystemID, existingCount: Int = 0) -> [CheatBatchEntry] {
        var entries: [CheatBatchEntry] = []
        if isLineBased(system) {
            var groupLabel: String?
            var groupCodes: [String] = []
            var groupInput: [String] = []
            var groupHasStandaloneLabel = false
            var groupNeedsCompanion = false
            func flushGroup() {
                guard !groupCodes.isEmpty else {
                    groupLabel = nil
                    groupCodes = []
                    groupInput = []
                    groupHasStandaloneLabel = false
                    groupNeedsCompanion = false
                    return
                }
                let label = groupLabel ?? "Cheat \(existingCount + entries.count + 1)"
                let code = groupCodes.joined(separator: "\n")
                let result = parse(code, system: system)
                entries.append(CheatBatchEntry(id: entries.count, label: label, input: groupInput.joined(separator: "\n"),
                                               result: result, include: result.isValid))
                groupLabel = nil
                groupCodes = []
                groupInput = []
                groupHasStandaloneLabel = false
                groupNeedsCompanion = false
            }
            func append(_ code: String, label: String, input: String) {
                for part in code.split(separator: "+") {
                    let result = parse(String(part), system: system)
                    let n = existingCount + entries.count + 1
                    entries.append(CheatBatchEntry(id: entries.count, label: label.isEmpty ? "Cheat \(n)" : label,
                                                   input: input, result: result, include: result.isValid))
                }
            }
            func beginCodeGroup(_ code: String, label: String, input: String) {
                groupLabel = label.isEmpty ? nil : label
                groupCodes = [code]
                groupInput = [input]
                groupHasStandaloneLabel = false
                groupNeedsCompanion = joinsNextLine(code, system: system)
                if !groupNeedsCompanion { flushGroup() }
            }
            let lines = text.replacingOccurrences(of: "\r\n", with: "\n")
                .replacingOccurrences(of: ";", with: "\n")
                .replacingOccurrences(of: ",", with: "\n")
            for line in lines.components(separatedBy: .newlines) {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard !trimmed.isEmpty else {
                    flushGroup()
                    continue
                }
                let (code, label) = splitLine(trimmed, system: system)
                if code.isEmpty {
                    flushGroup()
                    groupLabel = label.isEmpty ? trimmed : label
                    groupHasStandaloneLabel = true
                    continue
                }
                if code.contains("+") {
                    let pendingLabel = label.isEmpty ? (groupLabel ?? "") : label
                    flushGroup()
                    append(code, label: pendingLabel, input: trimmed)
                } else if !label.isEmpty {
                    flushGroup()
                    beginCodeGroup(code, label: label, input: trimmed)
                } else if groupHasStandaloneLabel {
                    groupCodes.append(code)
                    groupInput.append(trimmed)
                } else if groupNeedsCompanion {
                    groupCodes.append(code)
                    groupInput.append(trimmed)
                    groupNeedsCompanion = joinsNextLine(code, system: system)
                    if !groupNeedsCompanion { flushGroup() }
                } else {
                    beginCodeGroup(code, label: "", input: trimmed)
                }
            }
            flushGroup()
            return entries
        }

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
        let words = line.split(whereSeparator: \.isWhitespace).map(String.init)
        if isLineBased(system) {
            var best: (rank: Int, start: Int, length: Int)?
            for start in words.indices {
                for length in 1...min(2, words.count - start) {
                    let candidate = words[start..<start + length].joined(separator: " ")
                    guard let rank = codeShapeRank(candidate, system: system) else { continue }
                    if best == nil || (rank, start, -length) < (best!.rank, best!.start, -best!.length) {
                        best = (rank, start, length)
                    }
                }
            }
            guard let best else { return ("", line) }
            let code = words[best.start..<best.start + best.length].joined(separator: " ")
            let rest = Array(words.prefix(best.start)) + Array(words.dropFirst(best.start + best.length))
            return (code, rest.joined(separator: " ").trimmingCharacters(in: CharacterSet(charactersIn: " -–:\t")))
        }
        // Prefer the most code-like word: dashed, then hex, then Genesis letters, so a name never wins over the code.
        let ranked = words.indices.compactMap { i in codeShapeRank(words[i], system: system).map { (rank: $0, index: i) } }
        if let index = ranked.min(by: { ($0.rank, $0.index) < ($1.rank, $1.index) })?.index {
            var rest = words
            let code = rest.remove(at: index)
            return (code, rest.joined(separator: " ").trimmingCharacters(in: CharacterSet(charactersIn: " -–:\t")))
        }
        return (words.first ?? line, words.dropFirst().joined(separator: " "))
    }

    static func joinsNextLine(_ normalizedLine: String, system: SystemID) -> Bool {
        guard system == .psx || system == .n64 else { return false }
        let parts = normalizeLine(normalizedLine).split(whereSeparator: \.isWhitespace)
        guard let address = parts.first, address.count == 8,
              address.allSatisfy({ hexDigits.contains($0) }),
              let type = UInt8(String(address.prefix(2)), radix: 16) else { return false }
        switch system {
        case .n64:
            return [0x50, 0xD0, 0xD1, 0xD2, 0xD3].contains(type)
        case .psx:
            return psxGameSharkTypes.contains(type)
                && [0x50, 0xC2, 0xD0, 0xD1, 0xD2, 0xD3, 0xE0, 0xE1, 0xE2, 0xE3].contains(type)
        default:
            return false
        }
    }

    static func looksLikeCode(_ word: String, system: SystemID) -> Bool { codeShapeRank(word, system: system) != nil }

    static func codeShapeRank(_ word: String, system: SystemID) -> Int? {
        let w = word.uppercased()
        if w.contains("+") {
            let parts = w.split(separator: "+", omittingEmptySubsequences: false).map(String.init)
            return parts.count > 1 && parts.allSatisfy({ codeShapeRank($0, system: system) != nil }) ? 0 : nil
        }
        if isLineBased(system) {
            let normalized = normalizeLine(w)
            let parts = normalized.split(whereSeparator: \.isWhitespace).map(String.init)
            if system == .gba {
                if parts.count == 2, parts[0].count == 8, [4, 8].contains(parts[1].count),
                   parts.joined().allSatisfy({ hexDigits.contains($0) }) { return 0 }
            } else if parts.count == 2, parts[0].count == 8, parts[1].count == 4,
                      parts.joined().allSatisfy({ hexDigits.contains($0) }) {
                return 0
            }
            return nil
        }
        if w.count == 9, Array(w)[4] == "-" { return 0 }
        if system == .gb || system == .gbc {
            if gameBoyGameGenieBody(w) != nil { return 0 }
            if [6, 9].contains(w.count), w.allSatisfy({ hexDigits.contains($0) }) { return 0 }
            if w.count == 8, w.allSatisfy({ hexDigits.contains($0) }) { return 1 }
        }
        if isProActionReplayShape(w, system: system),
           w.replacingOccurrences(of: ":", with: "").allSatisfy({ hexDigits.contains($0) }) { return 0 }
        if w.count == 8, w.allSatisfy({ hexDigits.contains($0) }) { return 1 }
        if [.genesis, .sega32x, .segacd].contains(system), w.count == 8,
           w.allSatisfy({ genesisUndashed.contains($0) }) { return 2 }
        return nil
    }


    private static let genesisUndashed = Set("ABCDEFGHJKLMNPRSTVWXYZ0123456789")

    public static func defaultLabel(index: Int) -> String { "Cheat \(index)" }
}
