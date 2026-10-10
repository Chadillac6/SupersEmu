import CryptoKit
import Foundation
import GRDB
import SupersEmuKit

/// A cue sheet with its referenced tracks, or a single .chd/.iso, before hashing.
struct DiscUnit {
    var primary: LibraryImporter.Candidate
    var cue: CueSheet?
    var cueData: Data?
    var tracks: [LibraryImporter.Candidate]
    var missing: [String]
    var origins: [URL] { [primary.origin] + tracks.map(\.origin) }
}

/// A hashed file readable at `local` (the source itself, or a staged copy of a zip entry).
struct ExaminedFile {
    var candidate: LibraryImporter.Candidate
    var sha: String
    var size: Int64
    var header: Data
    var local: URL
    var role: GameFileRole
}

/// One disc after hashing and detection. `reason` sends it to Review Needed; `unsupported` reports it.
struct Disc {
    var unit: DiscUnit
    var name: DiscName
    /// Per-disc ID (docs/specs/disc-games.md): file SHA-256 for .chd/.iso, cue+track hash for cue sheets.
    var id = ""
    /// Primary file first (cue, or the .chd/.iso), then tracks in cue order.
    var files: [ExaminedFile] = []
    var system: SystemID?
    var reason: String?
    var unsupported: String?
    var label: String { unit.primary.label }
    var isPlayable: Bool { reason == nil && unsupported == nil && system != nil }
}

extension LibraryImporter {
    /// Folder names that declare a disc system for .chd files, whose compressed sectors can't be header-checked yet.
    static let chdFolderSystems: [String: SystemID] = [
        "ps1": .psx, "psx": .psx, "playstation": .psx, "sony - playstation": .psx, "sony playstation": .psx,
        "sega cd": .segacd, "segacd": .segacd, "mega-cd": .segacd, "mega cd": .segacd, "megacd": .segacd,
        "sega - mega-cd - sega cd": .segacd,
    ]

    func examineFile(_ candidate: Candidate, role: GameFileRole, batch: Batch) throws -> ExaminedFile {
        if var cached = batch.examined[candidate.key] { cached.role = role; return cached }
        let local: URL
        switch candidate.source {
        case .file(let url): local = url
        case .zip(let archive, let entry):
            try FileManager.default.createDirectory(at: stagingDirectory, withIntermediateDirectories: true)
            local = stagingDirectory.appendingPathComponent(UUID().uuidString)
            batch.staged.append(local)
            try archive.extract(entry, to: local)
        }
        let size = Int64((try FileManager.default.attributesOfItem(atPath: local.path)[.size] as? NSNumber)?.int64Value ?? 0)
        let (sha, header) = try Self.sha256AndHeader(of: local)
        let file = ExaminedFile(candidate: candidate, sha: sha, size: size, header: header, local: local, role: role)
        batch.examined[candidate.key] = file
        return file
    }

    func examine(_ unit: DiscUnit, batch: Batch) throws -> Disc {
        let folder = (unit.primary.container as NSString).lastPathComponent
        var disc = Disc(unit: unit, name: DiscName(filename: unit.primary.filename, folder: folder))
        do {
            if let cue = unit.cue {
                let cueFile = try examineFile(unit.primary, role: .cue, batch: batch)
                disc.files = [cueFile]
                disc.id = cueFile.sha
                if !unit.missing.isEmpty {
                    disc.reason = unit.missing.map { "Missing track: \($0)" }.joined(separator: "; ")
                    return disc
                }
                let tracks = try unit.tracks.map { try examineFile($0, role: .disc, batch: batch) }
                disc.files += tracks
                var hasher = SHA256()
                hasher.update(data: cue.normalized)
                for track in tracks { hasher.update(data: Data(track.sha.utf8)) }
                disc.id = hasher.finalize().hex
                if Set(tracks.map(\.sha)).count != tracks.count {
                    disc.reason = "Two tracks in the cue sheet have identical contents"
                    return disc
                }
                let dataKey = cue.firstDataFile.map { Candidate.key(unit.primary.container, $0.name) }
                let dataTrack = tracks.first { $0.candidate.key == dataKey } ?? tracks.first
                disc.system = dataTrack.flatMap { SystemDetector.detectDisc(header: $0.header) }
            } else {
                let file = try examineFile(unit.primary, role: .disc, batch: batch)
                disc.files = [file]
                disc.id = file.sha
                if unit.primary.ext == "chd" {
                    let folders = unit.primary.container.split(separator: "/").map { $0.lowercased() }
                    disc.system = folders.reversed().lazy.compactMap { Self.chdFolderSystems[$0] }.first
                    if disc.system == nil {
                        disc.reason = "CHD disc image: system can't be read from the file yet (put it in a PS1 or Sega CD folder)"
                    }
                    return disc
                }
                disc.system = SystemDetector.detectDisc(header: file.header)
            }
            if disc.system == nil { disc.reason = "Unrecognised disc (no PS1 or Sega CD header)" }
        } catch {
            disc.unsupported = "\(unit.primary.label): could not read (\(error))"
        }
        return disc
    }

    // MARK: Grouping

    func commitDiscs(_ discs: [String: Disc], units: [DiscUnit], playlists: [(Candidate, [String])], batch: Batch) throws {
        var used = Set<String>()

        // A user .m3u overrides inferred grouping.
        for (m3u, lines) in playlists {
            var members: [Disc] = [], missing: [String] = [], seen = Set<String>()
            for line in lines {
                let key = Candidate.key(m3u.container, line)
                guard let disc = discs[key] else { missing.append(line); continue }
                used.insert(key)
                if seen.insert(disc.id).inserted { members.append(disc) }
            }
            let origins = [m3u.origin] + members.flatMap(\.unit.origins)
            if members.isEmpty, missing.isEmpty {
                batch.record(.unsupported("\(m3u.label): empty playlist"), origins: origins)
            } else if !missing.isEmpty {
                let reason = missing.map { "Missing disc: \($0)" }.joined(separator: "; ")
                batch.record(try reviewPlaylist(m3u, reason: reason, batch: batch), origins: origins)
            } else if let broken = members.first(where: { !$0.isPlayable }) {
                for disc in members where !disc.isPlayable { batch.record(try review(disc), origins: disc.unit.origins + [m3u.origin]) }
                _ = broken
            } else if Set(members.compactMap(\.system)).count != 1 {
                batch.record(try reviewPlaylist(m3u, reason: "Playlist mixes discs from different systems", batch: batch), origins: origins)
            } else {
                let title = DiscName(filename: m3u.filename).title
                let playlistSHA = try? examineFile(m3u, role: .m3u, batch: batch).sha
                batch.record(try commitGame(members, title: title, clearingReview: playlistSHA.map { [$0] } ?? []), origins: origins)
            }
        }

        // Inferred sets: same normalized title, tags (region, revision) and system; disc numbers 1...N.
        var groups: [String: [Disc]] = [:], order: [String] = []
        for unit in units where !used.contains(unit.primary.key) {
            guard let disc = discs[unit.primary.key] else { continue }
            guard disc.isPlayable else {
                batch.record(try review(disc), origins: disc.unit.origins)
                continue
            }
            guard disc.name.discNumber != nil else {
                batch.record(try commitGame([disc], title: disc.name.title), origins: disc.unit.origins)
                continue
            }
            let key = "\(disc.system!.rawValue)|\(disc.name.groupKey)"
            if groups[key] == nil { order.append(key) }
            groups[key, default: []].append(disc)
        }
        for key in order {
            var set: [Disc] = [], seen = Set<String>()
            for disc in groups[key]! {
                if seen.insert(disc.id).inserted { set.append(disc) } else { batch.record(.duplicate, origins: disc.unit.origins) }
            }
            set.sort { $0.name.discNumber! < $1.name.discNumber! }
            let numbers = set.map { $0.name.discNumber! }
            let declared = Set(set.compactMap(\.name.discCount))
            let expected = Array(1...max(declared.max() ?? 0, numbers.last ?? 1))
            if numbers == expected, declared.allSatisfy({ $0 == numbers.count }) {
                batch.record(try commitGame(set, title: set[0].name.title), origins: set.flatMap(\.unit.origins))
                continue
            }
            let missing = expected.filter { !numbers.contains($0) }.map { "Disc \($0)" }
            let repeated = Dictionary(grouping: numbers, by: { $0 }).first { $0.value.count > 1 }?.key
            let reason = !missing.isEmpty ? "Disc set is missing \(missing.joined(separator: ", "))"
                : repeated.map { "Disc set has more than one Disc \($0)" }
                ?? "Disc set says \(declared.sorted().map(String.init).joined(separator: "/")) discs but has \(numbers.count)"
            for var disc in set {
                disc.reason = reason
                batch.record(try review(disc), origins: disc.unit.origins)
            }
        }
    }

    // MARK: Committing

    /// Stores every disc of one game under `games/<gameID>/` and inserts its rows. Generated .m3u for multi-disc sets.
    func commitGame(_ discs: [Disc], title: String, clearingReview extraReviewIDs: [String] = []) throws -> Outcome {
        let multi = discs.count > 1
        let gameID: String = {
            guard multi else { return discs[0].id }
            var hasher = SHA256()
            hasher.update(data: Data(discs.map(\.id).sorted().joined(separator: "\n").utf8))
            return hasher.finalize().hex
        }()
        let system = discs[0].system!
        if try store.db.read({ try Int.fetchOne($0, sql: "SELECT needs_review FROM games WHERE id = ?", arguments: [gameID]) }) == 0 {
            return .duplicate
        }
        // Cue sheets are re-hashed after their FILE lines are rewritten to unique stored names.
        let contentFiles = discs.flatMap(\.files).filter { $0.role != .cue }
        if Set(contentFiles.map(\.sha)).count != contentFiles.count {
            var disc = discs[0]
            disc.reason = "The discs share identical track files"
            return try review(disc)
        }

        // Stored names: originals, made unique within the game ("Disc 2 - Track 01.bin").
        var taken = Set<String>()
        func unique(_ name: String, disc: Int) -> String {
            var candidate = Self.safeFilename(name)
            if taken.contains(candidate.lowercased()), multi { candidate = "Disc \(disc) - \(candidate)" }
            let base = (candidate as NSString).deletingPathExtension, ext = (candidate as NSString).pathExtension
            var n = 2
            while taken.contains(candidate.lowercased()) {
                candidate = ext.isEmpty ? "\(base) \(n)" : "\(base) \(n).\(ext)"
                n += 1
            }
            taken.insert(candidate.lowercased())
            return candidate
        }

        struct Row { var id: String; var filename: String; var role: GameFileRole; var size: Int64; var disc: Int? }
        let fm = FileManager.default
        try fm.createDirectory(at: stagingDirectory, withIntermediateDirectories: true)
        let temp = stagingDirectory.appendingPathComponent("game-" + UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: temp, withIntermediateDirectories: true)
        var tempLive = true
        defer { if tempLive { try? fm.removeItem(at: temp) } }

        var rows: [Row] = [], launchNames: [String] = []
        for (index, disc) in discs.enumerated() {
            let number = index + 1
            var storedNames: [String: String] = [:]
            for file in disc.files {
                let name = unique(file.candidate.filename, disc: number)
                storedNames[file.candidate.key] = name
                try fm.copyItem(at: file.local, to: temp.appendingPathComponent(name))
                if file.role != .cue {
                    guard try LibraryHTTP.sha256Hex(of: temp.appendingPathComponent(name)) == file.sha else {
                        return .unsupported("\(file.candidate.label): changed while importing")
                    }
                    rows.append(Row(id: file.sha, filename: name, role: file.role, size: file.size, disc: number))
                }
            }
            if let cue = disc.unit.cue, let cueFile = disc.files.first {
                // Point FILE lines at the stored names, which may differ from the originals (subfolders, collisions).
                var lineNames: [Int: String] = [:]
                for file in cue.files { lineNames[file.line] = storedNames[Candidate.key(disc.unit.primary.container, file.name)] }
                let cueURL = temp.appendingPathComponent(storedNames[cueFile.candidate.key]!)
                let needsRewrite = cue.files.contains { lineNames[$0.line] != $0.name }
                if needsRewrite { try cue.rewritten(names: lineNames).write(to: cueURL) }
                let data = try Data(contentsOf: cueURL)
                guard needsRewrite || SHA256.hash(data: data).hex == cueFile.sha else {
                    return .unsupported("\(cueFile.candidate.label): changed while importing")
                }
                rows.insert(Row(id: SHA256.hash(data: data).hex, filename: cueURL.lastPathComponent, role: .cue,
                                size: Int64(data.count), disc: number), at: rows.firstIndex { $0.disc == number } ?? rows.count)
                launchNames.append(cueURL.lastPathComponent)
            } else if let name = disc.files.first.flatMap({ storedNames[$0.candidate.key] }) {
                launchNames.append(name)
            }
        }
        if multi {
            let data = Data((launchNames.joined(separator: "\n") + "\n").utf8)
            let name = unique(title + ".m3u", disc: 0)
            try data.write(to: temp.appendingPathComponent(name))
            rows.insert(Row(id: SHA256.hash(data: data).hex, filename: name, role: .m3u, size: Int64(data.count), disc: nil), at: 0)
        }

        guard Set(rows.map(\.id)).count == rows.count else {
            var disc = discs[0]
            disc.reason = "Two files in the game have identical contents"
            return try review(disc)
        }

        // Replace any review-queue copies of these discs (or a crashed earlier attempt) before moving in.
        let stale = Set(discs.map { $0.files[0].sha } + extraReviewIDs + [gameID])
        let staleIDs = try store.db.read { db in
            try stale.filter { try Int.fetchOne(db, sql: "SELECT needs_review FROM games WHERE id = ?", arguments: [$0]) == 1 }
        }
        let directory = store.paths.games.appendingPathComponent(gameID, isDirectory: true)
        for id in staleIDs where id != gameID { try? fm.removeItem(at: store.paths.games.appendingPathComponent(id, isDirectory: true)) }
        if fm.fileExists(atPath: directory.path) { try fm.removeItem(at: directory) }
        try fm.moveItem(at: temp, to: directory)
        tempLive = false
        do {
            try store.db.write { db in
                for id in staleIDs { try db.execute(sql: "DELETE FROM games WHERE id = ? AND needs_review = 1", arguments: [id]) }
                try db.execute(sql: "INSERT INTO games (id, title, system, needs_review, created_at) VALUES (?, ?, ?, 0, ?)",
                               arguments: [gameID, title, system.rawValue, Date()])
                for row in rows {
                    try db.execute(sql: """
                        INSERT INTO game_files (id, game_id, filename, role, size, disc_number, stored_path) VALUES (?, ?, ?, ?, ?, ?, ?)
                        """, arguments: [row.id, gameID, row.filename, row.role.rawValue, row.size, row.disc, "games/\(gameID)/\(row.filename)"])
                }
            }
        } catch {
            try? fm.removeItem(at: directory)
            throw error
        }
        return .imported(GameSummary(id: gameID, title: title, system: system, year: nil, genre: nil, coverPath: nil,
                                     totalSize: rows.reduce(0) { $0 + $1.size }))
    }

    /// Queues a disc's primary file (cue, .chd or .iso) for review under its file hash.
    func review(_ disc: Disc) throws -> Outcome {
        if let unsupported = disc.unsupported { return .unsupported(unsupported) }
        guard let primary = disc.files.first else { return .unsupported("\(disc.label): could not read") }
        return try queueForReview(primary, reason: disc.reason ?? "Needs review", title: disc.name.title, system: disc.system)
    }

    func reviewPlaylist(_ m3u: Candidate, reason: String, batch: Batch) throws -> Outcome {
        let file: ExaminedFile
        do { file = try examineFile(m3u, role: .m3u, batch: batch) } catch { return .unsupported("\(m3u.label): could not read (\(error))") }
        return try queueForReview(file, reason: reason, title: DiscName(filename: m3u.filename).title, system: nil)
    }

    private func queueForReview(_ file: ExaminedFile, reason: String, title: String, system: SystemID?) throws -> Outcome {
        let label = file.candidate.label
        guard file.size <= Self.maxReviewFileSize else { return .unsupported("\(label): \(reason); too large to queue for review") }
        let existing = try store.db.read { db in
            try Row.fetchOne(db, sql: """
                SELECT g.needs_review, g.review_reason, f.filename FROM games g JOIN game_files f ON f.game_id = g.id WHERE g.id = ? LIMIT 1
                """, arguments: [file.sha])
        }
        if let existing {
            if (existing["needs_review"] as Int) == 0 { return .unsupported("\(label): \(reason)") }
            if existing["review_reason"] as String? != reason {
                try store.db.write { try $0.execute(sql: "UPDATE games SET review_reason = ? WHERE id = ?", arguments: [reason, file.sha]) }
            }
            return .review(ReviewItem(id: file.sha, filename: existing["filename"], reason: reason))
        }
        let name = Self.safeFilename(file.candidate.filename)
        let directory = store.paths.games.appendingPathComponent(file.sha, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let destination = directory.appendingPathComponent(name)
        if FileManager.default.fileExists(atPath: destination.path) { try FileManager.default.removeItem(at: destination) }
        try FileManager.default.copyItem(at: file.local, to: destination)
        try store.db.write { db in
            try db.execute(sql: """
                INSERT INTO games (id, title, system, needs_review, review_reason, created_at) VALUES (?, ?, ?, 1, ?, ?)
                """, arguments: [file.sha, title, system?.rawValue ?? "unknown", reason, Date()])
            try db.execute(sql: """
                INSERT INTO game_files (id, game_id, filename, role, size, stored_path) VALUES (?, ?, ?, ?, ?, ?)
                """, arguments: [file.sha, file.sha, name, file.role.rawValue, file.size, "games/\(file.sha)/\(name)"])
        }
        return .review(ReviewItem(id: file.sha, filename: name, reason: reason))
    }
}
