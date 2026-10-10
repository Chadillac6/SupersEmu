import CryptoKit
import Foundation
import GRDB
import HTTPTypes
import Hummingbird
import SupersEmuKit

/// BIOS files live at `bios/<sha256>/<canonical filename>` with a `bios_files` row (docs/specs/disc-games.md).
enum BIOSLibrary {
    enum Match {
        case known(KnownBIOS)
        /// Named like a known BIOS (or its size) but the hash doesn't match a good dump.
        case wrongHash(KnownBIOS)
    }

    static func md5Hex(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = Insecure.MD5()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
        return hasher.finalize().hex
    }

    static func files(store: ServerStore) throws -> [BIOSFileInfo] {
        try store.db.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM bios_files WHERE verified = 1 ORDER BY system, filename").compactMap(info)
        }
    }

    static func status(store: ServerStore, known: [KnownBIOS]) throws -> [BIOSStatus] {
        let rows = try store.db.read { try Row.fetchAll($0, sql: "SELECT id, filename, original_filename, system, verified FROM bios_files ORDER BY created_at") }
        return known.map { bios in
            let good = rows.first { ($0["verified"] as Int) == 1 && ($0["system"] as String) == bios.system.rawValue && ($0["filename"] as String) == bios.filename }
            let bad = rows.last { ($0["verified"] as Int) == 0 && ($0["filename"] as String) == bios.filename }
            let state: BIOSStatus.State = good != nil ? .present : bad != nil ? .wrongHash : .missing
            return BIOSStatus(system: bios.system, filename: bios.filename, region: bios.region, required: bios.required,
                              state: state, sha256: (good ?? bad)?["id"])
        }
    }

    static func info(_ row: Row) -> BIOSFileInfo? {
        guard let system = SystemID(rawValue: row["system"]) else { return nil }
        return BIOSFileInfo(id: row["id"], filename: row["filename"], system: system, region: row["region"], required: (row["required"] as Int) == 1)
    }
}

extension LibraryImporter {
    /// Only files with a known BIOS size or name are MD5'd, so ordinary ROMs cost nothing extra.
    func matchBIOS(filename: String, size: Int64, url: URL) throws -> BIOSLibrary.Match? {
        let named = knownBIOS.first { $0.filename.lowercased() == filename.lowercased() }
        guard named != nil || knownBIOS.contains(where: { $0.size == size }) else { return nil }
        let md5 = try BIOSLibrary.md5Hex(of: url)
        if let known = knownBIOS.first(where: { $0.md5 == md5 && $0.size == size }) { return .known(known) }
        return named.map { .wrongHash($0) }
    }

    func fileBIOS(_ match: BIOSLibrary.Match, staged: URL, sha: String, size: Int64, originalFilename: String, label: String) throws -> Outcome {
        switch match {
        case .wrongHash(let bios):
            try store.db.write { db in
                try db.execute(sql: """
                    INSERT OR IGNORE INTO bios_files (id, filename, original_filename, system, region, required, verified, size, stored_path, created_at)
                    VALUES (?, ?, ?, ?, ?, ?, 0, ?, NULL, ?)
                    """, arguments: [sha, bios.filename, originalFilename, bios.system.rawValue, bios.region, bios.required, size, Date()])
            }
            return .unsupported("\(label): named like the \(bios.system.rawValue) \(bios.region) BIOS (\(bios.filename)) but its hash isn't a known good dump")
        case .known(let bios):
            let info = BIOSFileInfo(id: sha, filename: bios.filename, system: bios.system, region: bios.region, required: bios.required)
            let exists = try store.db.read { try Bool.fetchOne($0, sql: "SELECT 1 FROM bios_files WHERE id = ? AND verified = 1", arguments: [sha]) } ?? false
            if exists { return .duplicate }
            let directory = store.paths.bios.appendingPathComponent(sha, isDirectory: true)
            let destination = directory.appendingPathComponent(bios.filename)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            if FileManager.default.fileExists(atPath: destination.path) { try FileManager.default.removeItem(at: destination) }
            try FileManager.default.moveItem(at: staged, to: destination)
            try store.db.write { db in
                try db.execute(sql: """
                    INSERT OR REPLACE INTO bios_files (id, filename, original_filename, system, region, required, verified, size, stored_path, created_at)
                    VALUES (?, ?, ?, ?, ?, ?, 1, ?, ?, ?)
                    """, arguments: [sha, bios.filename, originalFilename, bios.system.rawValue, bios.region, bios.required, size,
                                     "bios/\(sha)/\(bios.filename)", Date()])
            }
            return .bios(info)
        }
    }
}

// Track: import (server). GET /v1/bios, /v1/bios/status, /v1/bios/{sha256} (Range/ETag like game files).
func registerBIOSRoutes(_ group: RouterGroup<SERequestContext>, store: ServerStore, known: [KnownBIOS] = KnownBIOS.all) {
    let fileIO = FileIO()

    group.get("bios") { _, context -> Response in
        try context.caller().require(.libraryRead)
        return try LibraryHTTP.json(try BIOSLibrary.files(store: store))
    }

    group.get("bios/status") { _, context -> Response in
        try context.caller().require(.libraryRead)
        return try LibraryHTTP.json(try BIOSLibrary.status(store: store, known: known))
    }

    group.get("bios/:sha256") { request, context -> Response in
        try context.caller().require(.libraryRead)
        let sha = try context.parameters.require("sha256")
        let row = try await store.db.read { db in
            try Row.fetchOne(db, sql: "SELECT filename, stored_path FROM bios_files WHERE id = ? AND verified = 1", arguments: [sha])
        }
        let biosRoot = store.paths.bios.resolvingSymlinksInPath().standardizedFileURL.path + "/"
        guard let row, let stored: String = row["stored_path"], !stored.split(separator: "/").contains(".."),
              case let path = store.paths.root.appendingPathComponent(stored).resolvingSymlinksInPath().standardizedFileURL.path,
              path.hasPrefix(biosRoot),
              let size = (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? NSNumber)?.intValue else {
            throw HTTPError(.notFound, message: "BIOS not found")
        }
        return try await LibraryHTTP.serveImmutableFile(request, context: context, fileIO: fileIO, path: path, size: size,
                                                        filename: row["filename"], eTag: "\"\(sha)\"")
    }
}
