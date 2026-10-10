import CryptoKit
import Foundation
import GRDB
import SupersEmuKit

/// Imports game files into content-addressed storage at `games/<sha256>/<filename>`.
/// Source files are only ever read; `scanIncoming` moves a source out of `Incoming` only after it fully imported.
public final class LibraryImporter: @unchecked Sendable {
    /// Unknown files larger than this are reported as unsupported instead of being copied into the review queue.
    public static let maxReviewFileSize: Int64 = 256 * 1024 * 1024

    let store: ServerStore
    private static let queue = DispatchQueue(label: "supersemu.library.import")

    public init(store: ServerStore) {
        self.store = store
    }

    public var importedDirectory: URL { store.paths.root.appendingPathComponent("Imported", isDirectory: true) }
    private var stagingDirectory: URL { store.paths.games.appendingPathComponent(".staging", isDirectory: true) }

    enum Outcome {
        case imported(GameSummary)
        case duplicate
        case review(ReviewItem)
        case unsupported(String)
        case ignored

        /// The source can leave `Incoming`: its content is in the library.
        var isSettled: Bool {
            switch self {
            case .imported, .duplicate, .ignored: return true
            case .review, .unsupported: return false
            }
        }
    }

    // MARK: Public API (serialised on one queue so concurrent imports can't race on the same hash)

    public func importPaths(_ paths: [String], auth: AuthContext?) async throws -> ImportReport {
        let report = try await run { importer in
            var outcomes: [Outcome] = []
            for path in paths {
                let expanded = (path as NSString).expandingTildeInPath
                guard expanded.hasPrefix("/") else {
                    outcomes.append(.unsupported("\(path): path must be absolute (it is read on the server)"))
                    continue
                }
                outcomes += try importer.importSource(URL(fileURLWithPath: expanded).standardizedFileURL, label: path).flatMap(\.outcomes)
            }
            return Self.report(outcomes)
        }
        try store.audit(auth, action: "library.import", detail: Self.auditDetail(report, paths: paths))
        return report
    }

    /// Imports every top-level item in `Incoming`. Each source file (or whole .zip) that imported or was already
    /// in the library moves to `Imported/<yyyy-MM-dd>/<relative path>`. Anything queued for review, unsupported
    /// or failed stays in `Incoming` untouched so nothing is lost.
    public func scanIncoming(auth: AuthContext?) async throws -> ImportReport {
        let incoming = store.paths.incoming
        let report = try await run { importer in
            try FileManager.default.createDirectory(at: incoming, withIntermediateDirectories: true)
            let items = try FileManager.default.contentsOfDirectory(at: incoming, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
                .sorted { $0.lastPathComponent < $1.lastPathComponent }
            var outcomes: [Outcome] = []
            let day = Self.dayFormatter.string(from: Date())
            for item in items {
                for source in try importer.importSource(item, label: item.lastPathComponent) {
                    outcomes += source.outcomes
                    if !source.outcomes.isEmpty, source.outcomes.allSatisfy(\.isSettled) {
                        try importer.moveToImported(source.url, incoming: incoming, day: day)
                    }
                }
            }
            return Self.report(outcomes)
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

    // MARK: Pipeline

    private func run<T>(_ body: @escaping (LibraryImporter) throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            Self.queue.async { continuation.resume(with: Result { try body(self) }) }
        }
    }

    struct SourceResult {
        var url: URL
        var outcomes: [Outcome]
    }

    /// One result per source file (a .zip counts as one source).
    func importSource(_ url: URL, label: String) throws -> [SourceResult] {
        let fm = FileManager.default
        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            return [SourceResult(url: url, outcomes: [.unsupported("\(label): not found")])]
        }
        guard isDirectory.boolValue else { return [SourceResult(url: url, outcomes: try importFile(url))] }
        var results: [SourceResult] = []
        let enumerator = fm.enumerator(at: url, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles, .skipsPackageDescendants])
        var files: [URL] = []
        while let next = enumerator?.nextObject() as? URL {
            if (try? next.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true { files.append(next) }
        }
        for file in files.sorted(by: { $0.path < $1.path }) {
            results.append(SourceResult(url: file, outcomes: try importFile(file)))
        }
        return results
    }

    func importFile(_ url: URL) throws -> [Outcome] {
        let filename = url.lastPathComponent
        if SystemDetector.isIgnorable(filename) { return [.ignored] }
        if url.pathExtension.lowercased() == "zip" { return try importZip(url) }
        let staged = stagingDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: stagingDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: staged) }
        do {
            try FileManager.default.copyItem(at: url, to: staged)
        } catch {
            return [.unsupported("\(filename): could not read (\(error.localizedDescription))")]
        }
        return [try ingest(staged: staged, filename: filename, label: filename)]
    }

    func importZip(_ url: URL) throws -> [Outcome] {
        let zipName = url.lastPathComponent
        let archive: ZipArchive
        do { archive = try ZipArchive(url: url) } catch { return [.unsupported("\(zipName): \(error)")] }
        try FileManager.default.createDirectory(at: stagingDirectory, withIntermediateDirectories: true)
        var outcomes: [Outcome] = []
        for entry in archive.entries where !entry.isDirectory {
            let label = "\(zipName)/\(entry.path)"
            if entry.path.hasPrefix("__MACOSX/") || SystemDetector.isIgnorable(entry.filename) {
                outcomes.append(.ignored)
                continue
            }
            let data: Data
            do { data = try archive.data(for: entry) } catch {
                outcomes.append(.unsupported("\(label): \(error)"))
                continue
            }
            let staged = stagingDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: staged) }
            try data.write(to: staged)
            outcomes.append(try ingest(staged: staged, filename: entry.filename, label: label))
        }
        return outcomes.isEmpty ? [.unsupported("\(zipName): empty archive")] : outcomes
    }

    /// Hashes and classifies a staged private copy, then moves it into `games/<sha256>/<filename>`.
    func ingest(staged: URL, filename: String, label: String) throws -> Outcome {
        let size = Int64((try FileManager.default.attributesOfItem(atPath: staged.path)[.size] as? NSNumber)?.int64Value ?? 0)
        let (sha, header) = try Self.sha256AndHeader(of: staged)
        let detection = SystemDetector.detect(filename: filename, header: header, size: size)

        let system: SystemID?, reviewReason: String?
        switch detection {
        case .ignored: return .ignored
        case .unsupported(let reason): return .unsupported("\(label): \(reason)")
        case .system(let id): (system, reviewReason) = (id, nil)
        case .needsReview(let reason):
            guard size <= Self.maxReviewFileSize else { return .unsupported("\(label): \(reason); too large to queue for review") }
            (system, reviewReason) = (nil, reason)
        }

        if let existing = try store.db.read({ db in
            try Row.fetchOne(db, sql: """
                SELECT g.needs_review, g.review_reason, f.filename FROM games g JOIN game_files f ON f.game_id = g.id WHERE g.id = ? LIMIT 1
                """, arguments: [sha])
        }) {
            if (existing["needs_review"] as Int) == 1 {
                return .review(ReviewItem(id: sha, filename: existing["filename"], reason: existing["review_reason"] ?? "Needs review"))
            }
            return .duplicate
        }

        let storedName = Self.safeFilename(filename)
        let directory = store.paths.games.appendingPathComponent(sha, isDirectory: true)
        let destination = directory.appendingPathComponent(storedName)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: destination.path) { try FileManager.default.removeItem(at: destination) }
        try FileManager.default.moveItem(at: staged, to: destination)

        let title = TitleNormalizer.title(fromFilename: storedName)
        try store.db.write { db in
            try db.execute(sql: """
                INSERT INTO games (id, title, system, needs_review, review_reason, created_at) VALUES (?, ?, ?, ?, ?, ?)
                """, arguments: [sha, title, system?.rawValue ?? "unknown", reviewReason == nil ? 0 : 1, reviewReason, Date()])
            try db.execute(sql: """
                INSERT INTO game_files (id, game_id, filename, role, size, stored_path) VALUES (?, ?, ?, ?, ?, ?)
                """, arguments: [sha, sha, storedName, GameFileRole.rom.rawValue, size, "games/\(sha)/\(storedName)"])
        }
        if let reviewReason { return .review(ReviewItem(id: sha, filename: storedName, reason: reviewReason)) }
        return .imported(GameSummary(id: sha, title: title, system: system!, year: nil, genre: nil, coverPath: nil, totalSize: size))
    }

    func moveToImported(_ source: URL, incoming: URL, day: String) throws {
        let incomingPath = incoming.resolvingSymlinksInPath().path
        let sourcePath = source.resolvingSymlinksInPath().path
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
        for outcome in outcomes {
            switch outcome {
            case .imported(let game): report.imported.append(game)
            case .duplicate: report.duplicates += 1
            case .review(let item): if !report.needsReview.contains(item) { report.needsReview.append(item) }
            case .unsupported(let reason): report.unsupported.append(reason)
            case .ignored: break
            }
        }
        return report
    }

    static func auditDetail(_ report: ImportReport, paths: [String]) -> String {
        "paths=\(paths.count) imported=\(report.imported.count) duplicates=\(report.duplicates) review=\(report.needsReview.count) unsupported=\(report.unsupported.count)"
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
        return (hasher.finalize().map { String(format: "%02x", $0) }.joined(), header)
    }

    /// Keeps the original name but never lets it escape `games/<sha256>/`.
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
