import Foundation
import SupersEmuKit

/// Decides which system a file belongs to from its extension and header bytes.
/// Never guesses: anything ambiguous is sent to the review queue with a reason.
public enum SystemDetector {
    public enum Result: Equatable, Sendable {
        case system(SystemID)
        /// Looks like a game file but can't be identified safely. Stored and queued for review.
        case needsReview(String)
        /// Not a game file (or a format we don't take). Reported, not stored.
        case unsupported(String)
        /// OS junk (`.DS_Store`, AppleDouble). Skipped without reporting.
        case ignored
    }

    /// Bytes of the file header that `detect` and `detectDisc` need: one de-interleaved .smd block, or a
    /// disc's 16-sector system area in raw 2352-byte sectors.
    public static let headerLength = max(512 + 0x4000, 16 * 2352)

    static let archiveExtensions: Set<String> = ["7z", "rar", "tar", "gz", "tgz", "bz2", "xz"]
    /// Notes, checksums, scans and disc sidecars that come with ROM sets. Skipped without reporting.
    static let junkExtensions: Set<String> = [
        "txt", "nfo", "diz", "md5", "sfv", "sha1", "crc", "dat", "xml", "json", "ini", "cfg", "log", "url", "htm", "html",
        "pdf", "doc", "docx", "rtf", "jpg", "jpeg", "png", "gif", "bmp", "webp", "heic", "tif", "tiff", "db", "sub", "sbi",
    ]
    static let patchExtensions: Set<String> = ["ips", "bps", "ups", "xdelta"]
    /// Disc formats the importer groups itself (`LibraryImporter`), never passed to `detect`.
    public static let discExtensions: Set<String> = ["cue", "m3u", "chd", "iso"]

    static let nintendoLogo: [UInt8] = [
        0xCE, 0xED, 0x66, 0x66, 0xCC, 0x0D, 0x00, 0x0B, 0x03, 0x73, 0x00, 0x83, 0x00, 0x0C, 0x00, 0x0D,
        0x00, 0x08, 0x11, 0x1F, 0x88, 0x89, 0x00, 0x0E, 0xDC, 0xCC, 0x6E, 0xE6, 0xDD, 0xDD, 0xD9, 0x99,
        0xBB, 0xBB, 0x67, 0x63, 0x6E, 0x0E, 0xEC, 0xCC, 0xDD, 0xDC, 0x99, 0x9F, 0xBB, 0xB9, 0x33, 0x3E,
    ]

    static let n64Magics: Set<[UInt8]> = [[0x80, 0x37, 0x12, 0x40], [0x37, 0x80, 0x40, 0x12], [0x40, 0x12, 0x37, 0x80]]

    public static func isIgnorable(_ filename: String) -> Bool {
        filename == ".DS_Store" || filename.hasPrefix("._") || filename == "Thumbs.db" || filename == "desktop.ini"
            || junkExtensions.contains((filename as NSString).pathExtension.lowercased())
    }

    /// Disc system from the first data track's first 16 sectors (2048-byte or raw 2352-byte sectors):
    /// Sega CD's `SEGADISCSYSTEM` / `SEGA SEGASYSTEM` at sector 0, or the PS1 licence string in the system area.
    public static func detectDisc(header: Data) -> SystemID? {
        let bytes = [UInt8](header.prefix(headerLength))
        for offset in [0, 16] where bytes.count >= offset + 16 {
            let name = String(decoding: bytes[offset..<offset + 16], as: UTF8.self)
            if name.hasPrefix("SEGADISCSYSTEM") || name.hasPrefix("SEGA SEGASYSTEM") { return .segacd }
        }
        if Data(bytes).range(of: Data("Sony Computer Entertainment".utf8)) != nil { return .psx }
        return nil
    }

    /// - Parameters:
    ///   - header: the first `headerLength` bytes (or the whole file if shorter).
    ///   - size: full file size in bytes.
    public static func detect(filename: String, header: Data, size: Int64) -> Result {
        if isIgnorable(filename) { return .ignored }
        let ext = (filename as NSString).pathExtension.lowercased()
        let bytes = [UInt8](header)
        switch ext {
        case "sfc", "smc":
            // SNES has no magic number; the extension is SNES-only, so only sanity-check the size.
            let romSize = size % 1024 == 512 ? size - 512 : size
            return romSize >= 0x8000 ? .system(.snes) : .needsReview("Too small for a SNES ROM (\(size) bytes)")
        case "gb", "gbc":
            guard bytes.count >= 0x150, Array(bytes[0x104..<0x134]) == nintendoLogo else {
                return .needsReview("No Game Boy header (Nintendo logo at 0x104 missing)")
            }
            switch bytes[0x143] {
            case 0xC0: return .system(.gbc)
            case 0x80: return .system(ext == "gbc" ? .gbc : .gb)
            default: return .system(.gb)
            }
        case "z64", "n64", "v64":
            // The first word is 0x80371240 in big-endian .z64; .v64 swaps each 16-bit pair, .n64 each 32-bit word.
            guard bytes.count >= 0x40, n64Magics.contains(Array(bytes[0..<4])) else {
                return .needsReview("No Nintendo 64 header (0x80371240 in any byte order)")
            }
            return .system(.n64)
        case "gba":
            guard bytes.count >= 0xC0, bytes[0xB2] == 0x96 else {
                return .needsReview("No Game Boy Advance header (fixed byte 0x96 at 0xB2 missing)")
            }
            return .system(.gba)
        case "md", "gen", "bin", "smd":
            return detectGenesis(ext: ext, bytes: bytes, size: size)
        case "32x":
            if let header = segaHeader(bytes, at: 0x100), is32X(header: header, bytes: bytes) { return .system(.sega32x) }
            return .needsReview("No Sega 32X header (\"32X\" at 0x100 or \"MARS\" at 0x3C0 missing)")
        case "pbp":
            return .unsupported("PBP (EBOOT) discs aren't supported yet; convert to .chd or .cue/.bin")
        case "zip":
            return .unsupported("Archive inside an archive")
        case _ where archiveExtensions.contains(ext):
            return .unsupported("Archive format .\(ext) is not supported (use .zip)")
        case _ where patchExtensions.contains(ext):
            return .unsupported("Patch files are not applied (.\(ext))")
        default:
            return .needsReview(ext.isEmpty ? "Unknown file type (no extension)" : "Unknown file type .\(ext)")
        }
    }

    static func detectGenesis(ext: String, bytes: [UInt8], size: Int64) -> Result {
        if let header = segaHeader(bytes, at: 0x100) {
            return .system(is32X(header: header, bytes: bytes) ? .sega32x : .genesis)
        }
        if size % 0x4000 == 512, let block = smdBlock(bytes), let header = segaHeader(block, at: 0x100) {
            return .system(is32X(header: header, bytes: block) ? .sega32x : .genesis)
        }
        if bytes.count >= 0x20, String(decoding: bytes[0..<0x20], as: UTF8.self).contains("SEGADISCSYSTEM") {
            return .needsReview("Sega CD disc image without a .cue sheet")
        }
        return .needsReview(ext == "bin"
            ? "Ambiguous .bin: no SEGA header at 0x100"
            : "No SEGA header at 0x100")
    }

    /// 32X carts have a Genesis header naming "SEGA 32X", and/or the "MARS CHECK MODE" security string at 0x3C0.
    static func is32X(header: String, bytes: [UInt8]) -> Bool {
        if header.contains("32X") { return true }
        guard bytes.count >= 0x3C4 else { return false }
        return bytes[0x3C0..<0x3C4].elementsEqual("MARS".utf8)
    }

    /// The 16-byte system name at `offset` if it contains "SEGA" (e.g. "SEGA GENESIS", " SEGA MEGA DRIVE").
    static func segaHeader(_ bytes: [UInt8], at offset: Int) -> String? {
        guard bytes.count >= offset + 16 else { return nil }
        let name = String(decoding: bytes[offset..<offset + 16], as: UTF8.self)
        return name.contains("SEGA") ? name : nil
    }

    /// Super Magic Drive dumps: 512-byte header, then 16 KB blocks with odd bytes in the first half, even in the second.
    static func smdBlock(_ bytes: [UInt8]) -> [UInt8]? {
        guard bytes.count >= 512 + 0x4000 else { return nil }
        var block = [UInt8](repeating: 0, count: 0x4000)
        for i in 0..<0x2000 {
            block[i * 2 + 1] = bytes[512 + i]
            block[i * 2] = bytes[512 + 0x2000 + i]
        }
        return block
    }
}
