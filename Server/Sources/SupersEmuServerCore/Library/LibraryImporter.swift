import CryptoKit
import Foundation
import GRDB
import SupersEmuKit

/// Imports game files into content-addressed storage at `games/<gameID>/<filename>`, and BIOS files into
/// `bios/<sha256>/<filename>`. Disc games (cue + tracks, multi-disc sets) are grouped per docs/specs/disc-games.md.
/// Source files are only ever read; `scanIncoming` moves a source out of `Incoming` only after it fully imported.
public final class LibraryImporter: @unchecked Sendable {
    /// Unknown files larger than this are reported as unsupported instead of being copied into the review queue.
    public static let maxReviewFileSize: Int64 = 256 * 1024 * 1024

    let store: ServerStore
    let knownBIOS: [KnownBIOS]
    private static let queue = DispatchQueue(label: "supersemu.library.import")

    public init(store: ServerStore, knownBIOS: [KnownBIOS] = KnownBIOS.all) {
        self.store = store
        self.knownBIOS = knownBIOS
    }

    public var importedDirectory: URL { store.paths.imported }
    var stagingDirectory: URL { store.paths.games.appendingPathComponent(".staging", isDirectory: true) }

    enum Outcome {
        case imported(GameSummary)
        case duplicate
        case review(ReviewItem, LibraryIssue.Kind)
        case unsupported(String, LibraryIssue.Kind)
        case ignored
        case bios(BIOSFileInfo)

        /// The source can leave `Incoming`: its content is in the library.
        var isSettled: Bool {
            switch self {
            case .imported, .duplicate, .ignored, .bios: return true
            case .review, .unsupported: return false
            }
        }
    }

    // MARK: Public API (serialised on one queue so concurrent imports can't race on the same hash)

    public func importPaths(_ paths: [String], auth: AuthContext?) async throws -> ImportReport {
        let report = try await run { importer in
            let batch = Batch()
            defer { batch.cleanUp() }
            for path in paths {
                let expanded = (path as NSString).expandingTildeInPath
                guard expanded.hasPrefix("/") else {
                    batch.record(.unsupported("\(path): path must be absolute (it is read on the server)", .other), origins: [])
                    continue
                }
                importer.gather(URL(fileURLWithPath: expanded).standardizedFileURL, label: path, into: batch)
            }
            try importer.process(batch)
            return Self.report(batch.outcomes)
        }
        try store.audit(auth, action: "library.import", detail: Self.auditDetail(report, paths: paths))
        return report
    }

    /// Imports everything in `Incoming`. Each source file (or whole .zip) that imported or was already in the
    /// library moves to `Imported/<yyyy-MM-dd>/<relative path>`; a disc moves only when its whole game imported.
    /// Anything queued for review, unsupported or failed stays in `Incoming` untouched so nothing is lost.
    public func scanIncoming(auth: AuthContext?) async throws -> ImportReport {
        let incoming = store.paths.incoming
        let report = try await run { importer in
            try FileManager.default.createDirectory(at: incoming, withIntermediateDirectories: true)
            let items = try FileManager.default.contentsOfDirectory(at: incoming, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
                .sorted { $0.lastPathComponent < $1.lastPathComponent }
            let batch = Batch()
            defer { batch.cleanUp() }
            for item in items { importer.gather(item, label: item.lastPathComponent, into: batch) }
            try importer.process(batch)
            let day = Self.dayFormatter.string(from: Date())
            for origin in batch.originOrder where batch.isSettled(origin) {
                try importer.settle(origin, incoming: incoming, day: day)
            }
            try importer.recordIssues(batch, incoming: incoming)
            importer.pruneEmptyUploads(incoming)
            return Self.report(batch.outcomes)
        }
        try store.audit(auth, action: "library.scan", detail: Self.auditDetail(report, paths: ["Incoming"]))
        return report
    }

    public func reviewQueue() throws -> [ReviewItem] {
        try store.db.read { db in
            try Row.fetchAll(db, sql: """
                SELECT g.id, g.review_reason, f.filename FROM games g JOIN game_files f ON f.game_id = g.id
                WHERE g.needs_review = 1 ORDER BY g.created_at, f.filename
                """).map { ReviewItem(id: $0["id"], filename: $0["filename"], reason: $0["review_reason"] ?? "Needs review") }
        }
    }

    func run<T>(_ body: @escaping (LibraryImporter) throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            Self.queue.async { continuation.resume(with: Result { try body(self) }) }
        }
    }

    // MARK: Gathering

    /// One file found in an import source: a loose file, or an entry inside a .zip.
    struct Candidate {
        enum Source {
            case file(URL)
            case zip(ZipArchive, ZipArchive.Entry)
        }

        var filename: String
        /// Folder the file sits in (an absolute path, or `<zip path>!/<dir>` for zip entries). Cue references resolve against it.
        var container: String
        var label: String
        /// What leaves `Incoming` once this file is settled: the file itself or its .zip.
        var origin: URL
        var source: Source
        var ext: String { (filename as NSString).pathExtension.lowercased() }
        var key: String { Self.key(container, filename) }

        /// Case-insensitive path key with `\`, `.` and `..` resolved, for matching cue/m3u references.
        static func key(_ container: String, _ relative: String) -> String {
            var parts: [Substring] = []
            for part in (container + "/" + relative.replacingOccurrences(of: "\\", with: "/")).split(separator: "/") {
                if part == "." { continue }
                if part == ".." { _ = parts.popLast(); continue }
                parts.append(part)
            }
            return parts.joined(separator: "/").lowercased()
        }
    }

    /// Everything one import call found and decided. `origins` track which sources may leave `Incoming`.
    final class Batch {
        var candidates: [Candidate] = []
        var outcomes: [Outcome] = []
        private(set) var originOrder: [URL] = []
        private var originOutcomes: [URL: [Outcome]] = [:]
        var staged: [URL] = []
        var examined: [String: ExaminedFile] = [:]

        func record(_ outcome: Outcome, origins: [URL]) {
            outcomes.append(outcome)
            for origin in Set(origins) {
                if originOutcomes[origin] == nil { originOrder.append(origin) }
                originOutcomes[origin, default: []].append(outcome)
            }
        }

        /// Settled when everything from the source landed and at least one thing wasn't skipped junk.
        func isSettled(_ origin: URL) -> Bool {
            guard let outcomes = originOutcomes[origin] else { return false }
            return outcomes.allSatisfy(\.isSettled) && outcomes.contains { if case .ignored = $0 { return false } else { return true } }
        }

        var unsettled: [(origin: URL, outcomes: [Outcome])] {
            originOrder.filter { !isSettled($0) }.map { ($0, originOutcomes[$0] ?? []) }
        }

        func cleanUp() { for url in staged { try? FileManager.default.removeItem(at: url) } }
    }

    func gather(_ url: URL, label: String, into batch: Batch) {
        let fm = FileManager.default
        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            batch.record(.unsupported("\(label): not found", .other), origins: [url])
            return
        }
        guard isDirectory.boolValue else { return addFile(url, into: batch) }
        let enumerator = fm.enumerator(at: url, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles, .skipsPackageDescendants])
        var files: [URL] = []
        while let next = enumerator?.nextObject() as? URL {
            if (try? next.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true { files.append(next) }
        }
        for file in files.sorted(by: { $0.path < $1.path }) { addFile(file, into: batch) }
    }

    private func addFile(_ url: URL, into batch: Batch) {
        let filename = url.lastPathComponent
        if SystemDetector.isIgnorable(filename) { return batch.record(.ignored, origins: [url]) }
        guard url.pathExtension.lowercased() == "zip" else {
            batch.candidates.append(Candidate(filename: filename, container: url.deletingLastPathComponent().path, label: filename, origin: url, source: .file(url)))
            return
        }
        let archive: ZipArchive
        do { archive = try ZipArchive(url: url) } catch { return batch.record(.unsupported("\(filename): \(error)", .readFailure(error)), origins: [url]) }
        let entries = archive.entries.filter { !$0.isDirectory }
        guard !entries.isEmpty else { return batch.record(.unsupported("\(filename): empty archive", .other), origins: [url]) }
        for entry in entries {
            if entry.path.hasPrefix("__MACOSX/") || SystemDetector.isIgnorable(entry.filename) {
                batch.record(.ignored, origins: [url])
                continue
            }
            let folder = (entry.path as NSString).deletingLastPathComponent
            batch.candidates.append(Candidate(
                filename: entry.filename, container: url.path + "!" + (folder.isEmpty ? "" : "/" + folder),
                label: "\(filename)/\(entry.path)", origin: url, source: .zip(archive, entry)))
        }
    }

    // MARK: Processing

    /// `Game.bin`, `Game01.bin`, `Game (Track 1).bin` may belong to `Game.cue`; `Gameplay.bin` doesn't.
    static func isTrackName(_ filename: String, of stem: String) -> Bool {
        let name = (filename as NSString).deletingPathExtension.lowercased()
        guard name.hasPrefix(stem) else { return false }
        guard let next = name.dropFirst(stem.count).first else { return true }
        return !next.isLetter
    }

    func process(_ batch: Batch) throws {
        let byKey = Dictionary(batch.candidates.map { ($0.key, $0) }, uniquingKeysWith: { first, _ in first })
        var consumed = Set<String>()
        var units: [DiscUnit] = []
        var playlists: [(Candidate, [String])] = []

        for cue in batch.candidates where cue.ext == "cue" {
            consumed.insert(cue.key)
            guard let data = try? readSmall(cue), let sheet = CueSheet(data: data) else {
                batch.record(.unsupported("\(cue.label): not a readable cue sheet", .other), origins: [cue.origin])
                continue
            }
            var tracks: [Candidate] = [], missing: [String] = [], seen = Set<String>()
            for file in sheet.files {
                let key = Candidate.key(cue.container, file.name)
                if let track = byKey[key], track.ext != "cue" {
                    if seen.insert(key).inserted { tracks.append(track) }
                    consumed.insert(key)
                } else {
                    missing.append(file.name)
                }
            }
            units.append(DiscUnit(primary: cue, cue: sheet, cueData: data, tracks: tracks, missing: missing))
        }
        // Files named like a track of an unreadable cue stay with it (unsettled), unless their own header
        // identifies a cartridge. Disc data tracks are checked for a disc header first.
        for cue in batch.candidates where cue.ext == "cue" && !units.contains(where: { $0.primary.key == cue.key }) {
            let stem = (cue.filename as NSString).deletingPathExtension.lowercased()
            for track in batch.candidates where track.container == cue.container && ["bin", "img"].contains(track.ext)
                && !consumed.contains(track.key) && Self.isTrackName(track.filename, of: stem) {
                if let (header, size) = try? headerAndSize(track), SystemDetector.detectDisc(header: header) == nil,
                   case .system = SystemDetector.detect(filename: track.filename, header: header, size: size) {
                    continue
                }
                consumed.insert(track.key)
                batch.record(.unsupported("\(track.label): track of unreadable cue sheet \(cue.filename)", .other), origins: [track.origin])
            }
        }
        for disc in batch.candidates where ["chd", "iso"].contains(disc.ext) && !consumed.contains(disc.key) {
            consumed.insert(disc.key)
            units.append(DiscUnit(primary: disc, cue: nil, cueData: nil, tracks: [], missing: []))
        }
        for m3u in batch.candidates where m3u.ext == "m3u" {
            consumed.insert(m3u.key)
            guard let data = try? readSmall(m3u) else {
                batch.record(.unsupported("\(m3u.label): not a readable playlist", .other), origins: [m3u.origin])
                continue
            }
            let lines = String(decoding: data, as: UTF8.self).components(separatedBy: .newlines)
                .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty && !$0.hasPrefix("#") }
            playlists.append((m3u, lines))
        }

        for candidate in batch.candidates where !consumed.contains(candidate.key) {
            batch.record(try importSingle(candidate, batch: batch), origins: [candidate.origin])
        }

        var discs: [String: Disc] = [:]
        for unit in units { discs[unit.primary.key] = try examine(unit, batch: batch) }
        try commitDiscs(discs, units: units, playlists: playlists, batch: batch)
    }

    /// Header bytes for detection without copying or extracting the whole file.
    private func headerAndSize(_ candidate: Candidate) throws -> (Data, Int64) {
        switch candidate.source {
        case .file(let url):
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            let size = Int64((try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value ?? 0)
            return (try handle.read(upToCount: SystemDetector.headerLength) ?? Data(), size)
        case .zip(let archive, let entry):
            return (try archive.prefix(of: entry, count: SystemDetector.headerLength), Int64(entry.uncompressedSize))
        }
    }

    private func readSmall(_ candidate: Candidate) throws -> Data {
        switch candidate.source {
        case .file(let url):
            let size = (try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.intValue ?? 0
            guard size <= CueSheet.maxSize else { throw ZipArchive.ZipError.entryTooLarge(candidate.filename) }
            return try Data(contentsOf: url)
        case .zip(let archive, let entry):
            guard entry.uncompressedSize <= CueSheet.maxSize else { throw ZipArchive.ZipError.entryTooLarge(candidate.filename) }
            return try archive.data(for: entry)
        }
    }

    /// Stages a private copy of a single file and ingests it.
    private func importSingle(_ candidate: Candidate, batch: Batch) throws -> Outcome {
        try FileManager.default.createDirectory(at: stagingDirectory, withIntermediateDirectories: true)
        let staged = stagingDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: staged) }
        do {
            switch candidate.source {
            case .file(let url): try FileManager.default.copyItem(at: url, to: staged)
            case .zip(let archive, let entry): try archive.extract(entry, to: staged)
            }
        } catch let error as ZipArchive.ZipError {
            return .unsupported("\(candidate.label): \(error)", .readFailure(error))
        } catch {
            return .unsupported("\(candidate.label): could not read (\(error.localizedDescription))", .other)
        }
        return try ingest(staged: staged, filename: candidate.filename, label: candidate.label)
    }

    /// Hashes and classifies a staged private copy, then moves it into `games/<sha256>/<filename>` (or `bios/`).
    func ingest(staged: URL, filename: String, label: String) throws -> Outcome {
        let size = Int64((try FileManager.default.attributesOfItem(atPath: staged.path)[.size] as? NSNumber)?.int64Value ?? 0)
        let (sha, header) = try Self.sha256AndHeader(of: staged)
        if let bios = try matchBIOS(filename: filename, size: size, url: staged) {
            return try fileBIOS(bios, staged: staged, sha: sha, size: size, originalFilename: filename, label: label)
        }
        let detection = SystemDetector.detect(filename: filename, header: header, size: size)

        let system: SystemID?, review: ImportReason?
        switch detection {
        case .ignored: return .ignored
        case .unsupported(let reason): return .unsupported("\(label): \(reason.message)", reason.kind)
        case .system(let id): (system, review) = (id, nil)
        case .needsReview(let reason):
            guard size <= Self.maxReviewFileSize else {
                return .unsupported("\(label): \(reason.message); too large to queue for review", reason.kind)
            }
            (system, review) = (nil, reason)
        }

        if let existing = try store.db.read({ db in
            try Row.fetchOne(db, sql: """
                SELECT g.needs_review, g.review_reason, g.review_kind, f.filename, f.stored_path FROM games g
                JOIN game_files f ON f.game_id = g.id WHERE g.id = ? LIMIT 1
                """, arguments: [sha])
        }) {
            if (existing["needs_review"] as Int) == 1 {
                if let system { return try promoteFromReview(sha: sha, system: system, staged: staged, filename: filename, size: size, oldStoredPath: existing["stored_path"]) }
                let reason: String = existing["review_reason"] ?? "Needs review"
                return .review(ReviewItem(id: sha, filename: existing["filename"], reason: reason),
                               Self.storedIssueKind(existing["review_kind"], reason: reason))
            }
            return .duplicate
        }

        let storedName = Self.safeFilename(filename)
        let destination = store.paths.games.appendingPathComponent(sha, isDirectory: true).appendingPathComponent(storedName)
        let title = TitleNormalizer.title(fromFilename: storedName)
        let now = Date()
        try place(staged, at: destination) {
            try store.db.write { db in
                try db.execute(sql: """
                    INSERT INTO games (id, title, system, needs_review, review_reason, review_kind, created_at, updated_at)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                    """, arguments: [sha, title, system?.rawValue ?? "unknown", review == nil ? 0 : 1, review?.message, review?.kind.rawValue,
                                     now, now])
                try db.execute(sql: """
                    INSERT INTO game_files (id, game_id, filename, role, size, stored_path) VALUES (?, ?, ?, ?, ?, ?)
                    """, arguments: [sha, sha, storedName, GameFileRole.rom.rawValue, size, Self.storedPath(gameID: sha, name: storedName)])
            }
        }
        if let review { return .review(ReviewItem(id: sha, filename: storedName, reason: review.message), review.kind) }
        return .imported(GameSummary(id: sha, title: title, system: system!, year: nil, genre: nil, coverPath: nil, totalSize: size))
    }

    /// Same bytes seen again under a name that detects cleanly: take the queued game out of review and store it under the new name.
    func promoteFromReview(sha: String, system: SystemID, staged: URL, filename: String, size: Int64, oldStoredPath: String) throws -> Outcome {
        let storedName = Self.safeFilename(filename)
        let newStoredPath = Self.storedPath(gameID: sha, name: storedName)
        let moved = newStoredPath != oldStoredPath
        let title = TitleNormalizer.title(fromFilename: storedName)
        let record = {
            try self.store.db.write { db in
                try db.execute(sql: "UPDATE games SET title = ?, system = ?, needs_review = 0, review_reason = NULL, review_kind = NULL, updated_at = ? WHERE id = ?",
                               arguments: [title, system.rawValue, Date(), sha])
                try db.execute(sql: "UPDATE game_files SET filename = ?, stored_path = ? WHERE game_id = ?",
                               arguments: [storedName, newStoredPath, sha])
            }
        }
        if moved {
            try place(staged, at: store.paths.libraryFile(newStoredPath), record: record)
        } else {
            try record()
        }
        if moved, !oldStoredPath.split(separator: "/").contains("..") {
            try? FileManager.default.removeItem(at: store.paths.libraryFile(oldStoredPath))
        }
        return .imported(GameSummary(id: sha, title: title, system: system, year: nil, genre: nil, coverPath: nil, totalSize: size))
    }

    /// Where a game file is stored, relative to the library root (`game_files.stored_path`).
    static func storedPath(gameID: String, name: String) -> String { "games/\(gameID)/\(name)" }

    /// Moves (or copies) `source` to `destination` (a file or a whole game directory), then runs `record` to write its rows.
    /// Anything already at `destination` is set aside and only deleted once `record` succeeds. If placing or `record`
    /// fails, the placed item is removed and the previous one restored, so storage always matches the rows.
    func place(_ source: URL, at destination: URL, copying: Bool = false, record: () throws -> Void) throws {
        let fm = FileManager.default
        let parent = destination.deletingLastPathComponent()
        try fm.createDirectory(at: parent, withIntermediateDirectories: true)
        var previous: URL?
        if fm.fileExists(atPath: destination.path) {
            let aside = parent.appendingPathComponent(".\(destination.lastPathComponent).replaced-\(UUID().uuidString)")
            try fm.moveItem(at: destination, to: aside)
            previous = aside
        }
        do {
            if copying { try fm.copyItem(at: source, to: destination) } else { try fm.moveItem(at: source, to: destination) }
            try record()
        } catch {
            try? fm.removeItem(at: destination)
            if let previous { try? fm.moveItem(at: previous, to: destination) }
            throw error
        }
        if let previous { try? fm.removeItem(at: previous) }
    }

    func moveToImported(_ source: URL, incoming: URL, day: String) throws {
        let incomingPath = incoming.resolvingSymlinksInPath().path
        let sourcePath = source.resolvingSymlinksInPath().path
        guard FileManager.default.fileExists(atPath: sourcePath) else { return }
        let relative = sourcePath.hasPrefix(incomingPath + "/") ? String(sourcePath.dropFirst(incomingPath.count + 1)) : source.lastPathComponent
        var destination = importedDirectory.appendingPathComponent(day, isDirectory: true).appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        var n = 2
        let base = destination.deletingPathExtension().lastPathComponent, ext = destination.pathExtension
        while FileManager.default.fileExists(atPath: destination.path) {
            destination = destination.deletingLastPathComponent().appendingPathComponent(ext.isEmpty ? "\(base) \(n)" : "\(base) \(n).\(ext)")
            n += 1
        }
        try FileManager.default.moveItem(at: source, to: destination)
    }

    // MARK: Helpers

    static func report(_ outcomes: [Outcome]) -> ImportReport {
        var report = ImportReport(imported: [], duplicates: 0, needsReview: [], unsupported: [])
        var bios: [BIOSFileInfo] = []
        for outcome in outcomes {
            switch outcome {
            case .imported(let game): report.imported.append(game)
            case .duplicate: report.duplicates += 1
            case .review(let item, _): if !report.needsReview.contains(item) { report.needsReview.append(item) }
            case .unsupported(let reason, _): report.unsupported.append(reason)
            case .ignored: break
            case .bios(let file): bios.append(file)
            }
        }
        if !bios.isEmpty { report.bios = bios }
        return report
    }

    static func auditDetail(_ report: ImportReport, paths: [String]) -> String {
        "paths=\(paths.count) imported=\(report.imported.count) duplicates=\(report.duplicates) review=\(report.needsReview.count) unsupported=\(report.unsupported.count) bios=\(report.bios?.count ?? 0)"
    }

    static func sha256AndHeader(of url: URL) throws -> (String, Data) {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        var header = Data()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            if header.count < SystemDetector.headerLength { header.append(chunk.prefix(SystemDetector.headerLength - header.count)) }
            hasher.update(data: chunk)
        }
        return (hasher.finalize().hex, header)
    }

    /// Keeps the original name but never lets it escape `games/<id>/`.
    static func safeFilename(_ name: String) -> String {
        var cleaned = (name as NSString).lastPathComponent
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: ":", with: "_")
        while cleaned.hasPrefix(".") { cleaned.removeFirst() }
        return cleaned.isEmpty ? "game" : String(cleaned.prefix(200))
    }

    static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()
}

extension Sequence where Element == UInt8 {
    var hex: String { map { String(format: "%02x", $0) }.joined() }
}
