import Foundation

/// Minimal cue sheet reader: the `FILE` lines (and whether each file holds a data track), enough to group,
/// identify and launch a disc. See docs/specs/disc-games.md.
struct CueSheet: Equatable {
    struct File: Equatable {
        /// The name exactly as written after `FILE` (may contain a relative path).
        var name: String
        var line: Int
        /// The file has at least one non-AUDIO track.
        var isData: Bool
        var nameRange: Range<String.Index>
    }

    static let maxSize = 1 << 20

    var lines: [String]
    var files: [File]

    init?(data: Data) {
        guard data.count <= Self.maxSize else { return nil }
        var text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) ?? ""
        if text.hasPrefix("\u{FEFF}") { text.removeFirst() }
        text = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        lines = text.components(separatedBy: "\n")
        files = []
        for (index, line) in lines.enumerated() {
            let trimmed = line.drop(while: { $0 == " " || $0 == "\t" })
            let keyword = trimmed.prefix(while: { $0 != " " && $0 != "\t" }).uppercased()
            if keyword == "FILE", let range = Self.nameRange(in: line, after: trimmed.startIndex) {
                files.append(File(name: String(line[range]), line: index, isData: false, nameRange: range))
            } else if keyword == "TRACK", !files.isEmpty, !trimmed.uppercased().hasSuffix("AUDIO") {
                files[files.count - 1].isData = true
            }
        }
        if files.isEmpty { return nil }
    }

    /// The file whose header identifies the disc: the first one holding a data track.
    var firstDataFile: File? { files.first(where: \.isData) ?? files.first }

    /// UTF-8, LF line endings, `FILE` names lowercased: the bytes the game ID hashes.
    var normalized: Data {
        var out = lines
        for file in files { out[file.line].replaceSubrange(file.nameRange, with: file.name.lowercased()) }
        return Data(out.joined(separator: "\n").utf8)
    }

    /// The sheet with `FILE` names replaced (by line), quoted. Used when stored names differ from the originals.
    func rewritten(names: [Int: String]) -> Data {
        var out = lines
        for file in files {
            guard let name = names[file.line], name != file.name else { continue }
            let line = out[file.line]
            var start = file.nameRange.lowerBound, end = file.nameRange.upperBound
            if start > line.startIndex, line[line.index(before: start)] == "\"" { start = line.index(before: start) }
            if end < line.endIndex, line[end] == "\"" { end = line.index(after: end) }
            out[file.line].replaceSubrange(start..<end, with: "\"\(name)\"")
        }
        return Data(out.joined(separator: "\n").utf8)
    }

    /// `FILE "name with spaces.bin" BINARY` or `FILE name.bin BINARY`.
    private static func nameRange(in line: String, after keywordStart: String.Index) -> Range<String.Index>? {
        var i = line.index(keywordStart, offsetBy: 4)
        while i < line.endIndex, line[i] == " " || line[i] == "\t" { i = line.index(after: i) }
        guard i < line.endIndex else { return nil }
        if line[i] == "\"" {
            let start = line.index(after: i)
            guard let close = line[start...].firstIndex(of: "\"") else { return nil }
            return start == close ? nil : start..<close
        }
        let rest = line[i...].trimmingCharacters(in: .whitespaces)
        guard let lastSpace = rest.lastIndex(of: " ") else { return i..<line.index(i, offsetBy: rest.count) }
        let nameLength = rest.distance(from: rest.startIndex, to: lastSpace)
        return nameLength == 0 ? nil : i..<line.index(i, offsetBy: nameLength)
    }
}

/// Title, disc number and grouping tags from a disc filename, e.g. "Final Fantasy VII (USA) (Disc 2).cue".
struct DiscName: Equatable {
    var title: String
    var discNumber: Int?
    var discCount: Int?
    /// Lowercased, sorted parenthesised tags other than the disc marker (region, revision, ...).
    var tags: String
    var groupKey: String { title.lowercased().split(whereSeparator: \.isWhitespace).joined(separator: " ") + "|" + tags }

    private static let marker = try! NSRegularExpression(
        pattern: #"[\(\[]\s*(?:disc|disk|cd)\s*(\d+)(?:\s*of\s*(\d+))?\s*[\)\]]|\b(?:disc|disk|cd)\s*(\d+)\s*of\s*(\d+)\b"#,
        options: [.caseInsensitive])
    private static let tag = try! NSRegularExpression(pattern: #"\(([^\)]*)\)"#)

    init(filename: String, folder: String? = nil) {
        var base = (filename as NSString).deletingPathExtension
        if let (range, number, count) = Self.match(base) {
            base = (base as NSString).replacingCharacters(in: NSRange(range), with: "")
            discNumber = number; discCount = count
        } else if let folder, let (_, number, count) = Self.match(folder) {
            discNumber = number; discCount = count
        }
        let ns = base as NSString
        tags = Self.tag.matches(in: base, range: NSRange(location: 0, length: ns.length))
            .map { ns.substring(with: $0.range(at: 1)).lowercased().trimmingCharacters(in: .whitespaces) }
            .sorted().joined(separator: "|")
        var cleaned = TitleNormalizer.title(fromFilename: base + ".x")
        while let last = cleaned.last, last == "-" || last == " " || last == "," { cleaned.removeLast() }
        title = cleaned.isEmpty ? (filename as NSString).deletingPathExtension : cleaned
    }

    private static func match(_ text: String) -> (Range<Int>, Int, Int?)? {
        let ns = text as NSString
        guard let m = marker.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)) else { return nil }
        func int(_ i: Int) -> Int? { m.range(at: i).location == NSNotFound ? nil : Int(ns.substring(with: m.range(at: i))) }
        guard let number = int(1) ?? int(3) else { return nil }
        return (m.range.location..<(m.range.location + m.range.length), number, int(2) ?? int(4))
    }
}
