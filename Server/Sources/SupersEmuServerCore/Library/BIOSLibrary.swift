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
        /// A real-looking PS2 BIOS (ROMDIR with `ROMVER`) whose hash isn't in the table, e.g. a bad or modified dump.
        case unknownPS2(romver: String, KnownBIOS)
    }

    static func md5Hex(of url: URL) throws -> String {
        var hasher = Insecure.MD5()
        try Hashing.update(&hasher, withContentsOf: url)
        return hasher.finalize().hexString
    }

    static func files(store: ServerStore) throws -> [BIOSFileInfo] {
        try store.db.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM bios_files WHERE verified = 1 ORDER BY system, filename").compactMap(info)
        }
    }

    static func status(store: ServerStore, known: [KnownBIOS]) throws -> [BIOSStatus] {
        let rows = try store.db.read {
            try Row.fetchAll($0, sql: "SELECT id, filename, original_filename, system, region, required, verified FROM bios_files ORDER BY created_at")
        }
        let listed = known.filter(\.listed)
        let listedNames = Set(listed.map { "\($0.system.rawValue)/\($0.filename)" })
        // Unlisted dumps (other PS2 revisions) get a row once a good copy is stored.
        let extra = rows.filter { ($0["verified"] as Int) == 1 && !listedNames.contains("\($0["system"] as String)/\($0["filename"] as String)") }
            .compactMap { row -> BIOSStatus? in
                guard let system = SystemID(rawValue: row["system"]) else { return nil }
                return BIOSStatus(system: system, filename: row["filename"], region: row["region"] ?? "", required: (row["required"] as Int) == 1,
                                  state: .present, sha256: row["id"])
            }
        return listed.map { bios in
            let good = rows.first { ($0["verified"] as Int) == 1 && ($0["system"] as String) == bios.system.rawValue && ($0["filename"] as String) == bios.filename }
            let bad = rows.last { ($0["verified"] as Int) == 0 && ($0["filename"] as String) == bios.filename }
            let state: BIOSStatus.State = good != nil ? .present : bad != nil ? .wrongHash : .missing
            return BIOSStatus(system: bios.system, filename: bios.filename, region: bios.region, required: bios.required,
                              state: state, sha256: (good ?? bad)?["id"])
        } + extra
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
        if named == nil, size == PS2BIOS.size, let romver = PS2BIOS.romver(try Data(contentsOf: url, options: .mappedIfSafe)) {
            return .unknownPS2(romver: romver, KnownBIOS(filename: PS2BIOS.filename(romver: romver), system: .ps2,
                                                         region: PS2BIOS.region(romver: romver), required: false, md5: md5, size: size))
        }
        return named.map { .wrongHash($0) }
    }

    func fileBIOS(_ match: BIOSLibrary.Match, staged: URL, sha: String, size: Int64, originalFilename: String, label: String) throws -> Outcome {
        switch match {
        case .unknownPS2(let romver, let bios):
            try store.db.write { db in
                try db.execute(sql: """
                    INSERT OR IGNORE INTO bios_files (id, filename, original_filename, system, region, required, verified, size, stored_path, created_at)
                    VALUES (?, ?, ?, ?, ?, ?, 0, ?, NULL, ?)
                    """, arguments: [sha, bios.filename, originalFilename, bios.system.rawValue, bios.region, bios.required, size, Date()])
            }
            return .unsupported("\(label): looks like a PS2 BIOS (version \(romver)) but its hash isn't a known good dump", .wrongBIOS)
        case .wrongHash(let bios):
            try store.db.write { db in
                try db.execute(sql: """
                    INSERT OR IGNORE INTO bios_files (id, filename, original_filename, system, region, required, verified, size, stored_path, created_at)
                    VALUES (?, ?, ?, ?, ?, ?, 0, ?, NULL, ?)
                    """, arguments: [sha, bios.filename, originalFilename, bios.system.rawValue, bios.region, bios.required, size, Date()])
            }
            return .unsupported("\(label): named like the \(bios.system.rawValue) \(bios.region) BIOS (\(bios.filename)) but its hash isn't a known good dump",
                                .wrongBIOS)
        case .known(let bios):
            let info = BIOSFileInfo(id: sha, filename: bios.filename, system: bios.system, region: bios.region, required: bios.required)
            let exists = try store.db.read { try Bool.fetchOne($0, sql: "SELECT 1 FROM bios_files WHERE id = ? AND verified = 1", arguments: [sha]) } ?? false
            if exists { return .duplicate }
            let destination = store.paths.bios.appendingPathComponent(sha, isDirectory: true).appendingPathComponent(bios.filename)
            try place(staged, at: destination) {
                try store.db.write { db in
                    try db.execute(sql: """
                        INSERT OR REPLACE INTO bios_files (id, filename, original_filename, system, region, required, verified, size, stored_path, created_at)
                        VALUES (?, ?, ?, ?, ?, ?, 1, ?, ?, ?)
                        """, arguments: [sha, bios.filename, originalFilename, bios.system.rawValue, bios.region, bios.required, size,
                                         "bios/\(sha)/\(bios.filename)", Date()])
                }
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
        let bios: (filename: String, storedPath: String?)? = try await store.db.read { db in
            guard let row = try Row.fetchOne(db, sql: "SELECT filename, stored_path FROM bios_files WHERE id = ? AND verified = 1", arguments: [sha]) else { return nil }
            return (row["filename"], row["stored_path"])
        }
        let biosRoot = store.paths.bios.resolvingSymlinksInPath().standardizedFileURL.path + "/"
        guard let bios, let stored = bios.storedPath, !stored.split(separator: "/").contains(".."),
              case let path = store.paths.libraryFile(stored).resolvingSymlinksInPath().standardizedFileURL.path,
              path.hasPrefix(biosRoot),
              let size = (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? NSNumber)?.intValue else {
            throw HTTPError(.notFound, message: "BIOS not found")
        }
        return try await LibraryHTTP.serveImmutableFile(request, context: context, fileIO: fileIO, path: path, size: size,
                                                        filename: bios.filename, eTag: "\"\(sha)\"")
    }
}

/// PS2 BIOS images: a 4 MB ROM whose ROMDIR (16-byte entries: name[10], extinfo size, file size) starts with
/// `RESET`, `ROMDIR` and holds a `ROMVER` file like `0230AC20080220` (version, region, console type, date).
enum PS2BIOS {
    static let size: Int64 = 4_194_304

    static func romver(_ data: Data) -> String? {
        let bytes = [UInt8](data.prefix(Int(size)))
        func name(_ offset: Int) -> String {
            String(decoding: bytes[offset..<offset + 10].prefix { $0 != 0 }, as: UTF8.self)
        }
        func le(_ offset: Int, _ count: Int) -> Int { (0..<count).reduce(0) { $0 | Int(bytes[offset + $1]) << (8 * $1) } }
        var start = 0
        while start + 32 <= min(bytes.count, 0x10000), !(name(start) == "RESET" && name(start + 16) == "ROMDIR") { start += 16 }
        guard start + 32 <= min(bytes.count, 0x10000) else { return nil }
        var entry = start, offset = 0
        while entry + 16 <= bytes.count, entry < start + 16 * 256 {
            let entryName = name(entry), fileSize = le(entry + 12, 4)
            if entryName.isEmpty { return nil }
            if entryName == "ROMVER" {
                guard offset + 14 <= bytes.count else { return nil }
                let version = String(decoding: bytes[offset..<offset + 14], as: UTF8.self)
                return version.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber) } ? version : nil
            }
            offset += (fileSize + 15) & ~15
            entry += 16
        }
        return nil
    }

    /// libretro's naming, e.g. `ps2-0230a-20080220.bin` for ROMVER `0230AC20080220` (a `d` suffix marks DEX units).
    static func filename(romver: String) -> String {
        let chars = Array(romver)
        let devSuffix = chars[5] == "D" ? "d" : ""
        return "ps2-\(String(chars[0..<4]))\(String(chars[4]).lowercased())\(devSuffix)-\(String(chars[6..<14])).bin"
    }

    static func region(romver: String) -> String {
        switch Array(romver)[4] {
        case "A": "US"
        case "E": "EU"
        case "J": "JP"
        case "H": "Asia"
        case "C": "CN"
        default: String(Array(romver)[4])
        }
    }
}
