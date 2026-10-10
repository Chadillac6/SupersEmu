import CryptoKit
import Foundation
import GRDB
import SupersEmuKit

enum LibraryIssueError: Error, Equatable {
    case notFound, notAssignable, conflict
}

/// Review Needed: what the last scan left in Incoming plus the review queue, with the fixes that are safe.
extension LibraryImporter {
    static let uploadsFolder = "Uploads"
    static let uploadStagingFolder = ".uploads"
    nonisolated(unsafe) static var maxUploadFileSize: Int64 = 4 << 30
    static let uploadFreeSpaceMargin: Int64 = 512 << 20
    static let assignableSystems: [SystemID] = [.snes, .gb, .gbc, .gba, .genesis, .sega32x]

    static func relativePath(_ url: URL, in root: URL) -> String? {
        let rootPath = root.resolvingSymlinksInPath().standardizedFileURL.path
        let path = url.resolvingSymlinksInPath().standardizedFileURL.path
        guard path.hasPrefix(rootPath + "/") else { return nil }
        return String(path.dropFirst(rootPath.count + 1))
    }

    /// Uploaded files are copies of something on the sending Mac, so settled ones are removed rather than kept in Imported.
    func settle(_ origin: URL, incoming: URL, day: String) throws {
        if let relative = Self.relativePath(origin, in: incoming), relative.hasPrefix(Self.uploadsFolder + "/") {
            try? FileManager.default.removeItem(at: origin)
        } else {
            try moveToImported(origin, incoming: incoming, day: day)
        }
    }

    func recordIssues(_ batch: Batch, incoming: URL) throws {
        var rows: [(id: String, path: String, reason: String, reviewID: String?)] = []
        for (origin, outcomes) in batch.unsettled {
            guard let relative = Self.relativePath(origin, in: incoming) else { continue }
            var reasons: [String] = [], reviewID: String?
            for outcome in outcomes {
                switch outcome {
                case .review(let item):
                    reasons.append(item.reason)
                    reviewID = reviewID ?? item.id
                case .unsupported(let message):
                    reasons.append(message.range(of: ": ").map { String(message[$0.upperBound...]) } ?? message)
                default: break
                }
            }
            guard !reasons.isEmpty else { continue }
            var unique: [String] = []
            for reason in reasons where !unique.contains(reason) { unique.append(reason) }
            rows.append((Self.issueID(relative), relative, unique.joined(separator: "; "), reviewID))
        }
        try store.db.write { db in
            try db.execute(sql: "DELETE FROM import_issues")
            for row in rows {
                try db.execute(sql: "INSERT OR REPLACE INTO import_issues (id, path, reason, review_id, created_at) VALUES (?, ?, ?, ?, ?)",
                               arguments: [row.id, row.path, row.reason, row.reviewID, Date()])
            }
        }
    }

    static func issueID(_ relativePath: String) -> String {
        "in-" + SHA256.hash(data: Data(relativePath.utf8)).prefix(12).map { String(format: "%02x", $0) }.joined()
    }

    static func issueKind(_ reason: String) -> LibraryIssue.Kind {
        let reason = reason.lowercased()
        if reason.contains("missing track") || reason.contains("missing disc") || reason.contains("is missing")
            || reason.contains("without a .cue") { return .missingFiles }
        if reason.contains("pbp") || reason.contains("supported") { return .unsupportedFormat }
        if reason.contains("bios") { return .wrongBIOS }
        if reason.contains("unknown file type") { return .unknownSystem }
        if reason.contains("header") || reason.contains("ambiguous") || reason.contains("too small") { return .ambiguous }
        return .other
    }

    struct QueuedGame { var filename: String; var singleROM: Bool }

    static func queuedGame(_ id: String, db: Database) throws -> QueuedGame? {
        let files = try Row.fetchAll(db, sql: """
            SELECT f.filename, f.role FROM game_files f JOIN games g ON g.id = f.game_id
            WHERE g.id = ? AND g.needs_review = 1 ORDER BY f.filename
            """, arguments: [id])
        guard let first = files.first else { return nil }
        return QueuedGame(filename: first["filename"], singleROM: files.count == 1 && (first["role"] as String) == GameFileRole.rom.rawValue)
    }

    /// Picking a console is only offered for a single cartridge ROM the detector couldn't place; discs need their files.
    static func candidates(_ kind: LibraryIssue.Kind, _ queued: QueuedGame?) -> [SystemID] {
        guard let queued, queued.singleROM, kind == .unknownSystem || kind == .ambiguous else { return [] }
        return assignableSystems
    }

    public func issues() throws -> [LibraryIssue] {
        let incoming = store.paths.incoming
        return try store.db.read { db in
            var result: [LibraryIssue] = [], linked = Set<String>()
            for row in try Row.fetchAll(db, sql: "SELECT id, path, reason, review_id FROM import_issues ORDER BY path") {
                let path: String = row["path"], reason: String = row["reason"]
                guard FileManager.default.fileExists(atPath: incoming.appendingPathComponent(path).path) else { continue }
                let reviewID: String? = row["review_id"]
                let queued = try reviewID.flatMap { try Self.queuedGame($0, db: db) }
                if queued != nil, let reviewID { linked.insert(reviewID) }
                let kind = Self.issueKind(reason)
                result.append(LibraryIssue(id: row["id"], kind: kind, filename: (path as NSString).lastPathComponent, reason: reason,
                                           incomingPath: path, reviewID: queued == nil ? nil : reviewID,
                                           candidateSystems: Self.candidates(kind, queued)))
            }
            for row in try Row.fetchAll(db, sql: "SELECT id, review_reason FROM games WHERE needs_review = 1 ORDER BY created_at") {
                let id: String = row["id"]
                guard !linked.contains(id), let queued = try Self.queuedGame(id, db: db) else { continue }
                let reason: String = row["review_reason"] ?? "Needs review"
                let kind = Self.issueKind(reason)
                result.append(LibraryIssue(id: "rq-" + id, kind: kind, filename: queued.filename, reason: reason,
                                           incomingPath: nil, reviewID: id, candidateSystems: Self.candidates(kind, queued)))
            }
            return result
        }
    }

    public func assignSystem(issue id: String, system: SystemID, auth: AuthContext?) async throws -> GameSummary {
        let summary = try await run { importer -> GameSummary in
            guard let issue = try importer.issues().first(where: { $0.id == id }) else { throw LibraryIssueError.notFound }
            guard let reviewID = issue.reviewID, issue.candidateSystems.contains(system) else { throw LibraryIssueError.notAssignable }
            let summary = try importer.store.db.write { db -> GameSummary in
                try db.execute(sql: "UPDATE games SET system = ?, needs_review = 0, review_reason = NULL WHERE id = ? AND needs_review = 1",
                               arguments: [system.rawValue, reviewID])
                let row = try Row.fetchOne(db, sql: "SELECT g.title, f.size FROM games g JOIN game_files f ON f.game_id = g.id WHERE g.id = ?",
                                           arguments: [reviewID])
                return GameSummary(id: reviewID, title: row?["title"] ?? issue.filename, system: system, year: nil, genre: nil,
                                   coverPath: nil, totalSize: row?["size"] ?? 0)
            }
            try importer.removeSource(of: issue, settled: true)
            return summary
        }
        try store.audit(auth, action: "library.review.assign", detail: "\(summary.id) \(system.rawValue)")
        return summary
    }

    /// Deletes the queued copy and the file left in Incoming.
    public func deleteIssue(_ id: String, auth: AuthContext?) async throws {
        let issue = try await run { importer -> LibraryIssue in
            guard let issue = try importer.issues().first(where: { $0.id == id }) else { throw LibraryIssueError.notFound }
            if let reviewID = issue.reviewID, reviewID.allSatisfy(\.isHexDigit) {
                try importer.store.db.write { try $0.execute(sql: "DELETE FROM games WHERE id = ? AND needs_review = 1", arguments: [reviewID]) }
                try? FileManager.default.removeItem(at: importer.store.paths.games.appendingPathComponent(reviewID, isDirectory: true))
            }
            try importer.removeSource(of: issue, settled: false)
            return issue
        }
        try store.audit(auth, action: "library.review.delete", detail: issue.incomingPath ?? issue.filename)
    }

    func removeSource(of issue: LibraryIssue, settled: Bool) throws {
        let incoming = store.paths.incoming
        if let path = issue.incomingPath, !path.split(separator: "/").contains(".."),
           case let url = incoming.appendingPathComponent(path), Self.relativePath(url, in: incoming) != nil {
            if settled {
                try settle(url, incoming: incoming, day: Self.dayFormatter.string(from: Date()))
            } else {
                try FileManager.default.removeItem(at: url)
            }
            pruneEmptyUploads(incoming)
        }
        if issue.id.hasPrefix("in-") {
            try store.db.write { try $0.execute(sql: "DELETE FROM import_issues WHERE id = ?", arguments: [issue.id]) }
        }
    }

    // MARK: Uploads

    static func isSafeBatch(_ batch: String) -> Bool {
        (1...64).contains(batch.count) && batch.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }
    }

    /// A relative path from the sending Mac. Every component must be a plain, visible name: no `..`, hidden files or separators.
    static func safeUploadPath(_ path: String) -> [String]? {
        let parts = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard !path.isEmpty, path.utf8.count <= 1024, parts.count <= 16 else { return nil }
        for part in parts {
            guard !part.isEmpty, !part.hasPrefix("."), part.utf8.count <= 255, !part.contains(":"), !part.contains("\\"),
                  !part.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7F }) else { return nil }
        }
        return parts
    }

    var uploadStagingRoot: URL { store.paths.incoming.appendingPathComponent(Self.uploadStagingFolder, isDirectory: true) }

    func uploadDestination(batch: String, parts: [String]) -> URL? {
        let batchRoot = uploadStagingRoot.appendingPathComponent(batch, isDirectory: true)
        let url = parts.reduce(batchRoot) { $0.appendingPathComponent($1) }.standardizedFileURL
        return url.path.hasPrefix(batchRoot.standardizedFileURL.path + "/") ? url : nil
    }

    /// Moves a finished upload batch from hidden staging into `Incoming/Uploads/<batch>` so the next scan sees all of it at once.
    func finishUpload(batch: String) async throws {
        try await run { importer in
            let fm = FileManager.default
            let staging = importer.uploadStagingRoot.appendingPathComponent(batch, isDirectory: true)
            guard fm.fileExists(atPath: staging.path) else { throw LibraryIssueError.notFound }
            let uploads = importer.store.paths.incoming.appendingPathComponent(Self.uploadsFolder, isDirectory: true)
            try fm.createDirectory(at: uploads, withIntermediateDirectories: true)
            let destination = uploads.appendingPathComponent(batch, isDirectory: true)
            guard !fm.fileExists(atPath: destination.path) else { throw LibraryIssueError.conflict }
            try fm.moveItem(at: staging, to: destination)
            importer.pruneStaleUploads()
        }
    }

    /// Batches a Mac started but never finished (closed lid, lost Wi-Fi) are dropped after a day.
    func pruneStaleUploads() {
        let fm = FileManager.default
        let cutoff = Date().addingTimeInterval(-86_400)
        for url in (try? fm.contentsOfDirectory(at: uploadStagingRoot, includingPropertiesForKeys: [.contentModificationDateKey])) ?? [] {
            if let modified = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate, modified < cutoff {
                try? fm.removeItem(at: url)
            }
        }
    }

    func pruneEmptyUploads(_ incoming: URL) {
        let fm = FileManager.default
        let uploads = incoming.appendingPathComponent(Self.uploadsFolder, isDirectory: true)
        guard let enumerator = fm.enumerator(at: uploads, includingPropertiesForKeys: [.isDirectoryKey]) else { return }
        var directories: [URL] = []
        for case let url as URL in enumerator where (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
            directories.append(url)
        }
        for directory in directories.sorted(by: { $0.path.count > $1.path.count }) {
            let contents = (try? fm.contentsOfDirectory(atPath: directory.path)) ?? ["?"]
            if contents.allSatisfy({ $0 == ".DS_Store" }) { try? fm.removeItem(at: directory) }
        }
    }
}
