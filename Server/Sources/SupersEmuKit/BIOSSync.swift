import CryptoKit
import Foundation

public extension SystemID {
    /// Disc systems whose cores need a BIOS dump in the system directory before a game can boot.
    var requiresBIOS: Bool { self == .psx || self == .segacd }
}

public extension GameDetail {
    /// Discs in a multi-disc game: distinct disc numbers, else one per cue sheet / disc image.
    var discCount: Int {
        let numbers = Set(files.compactMap(\.discNumber))
        if !numbers.isEmpty { return numbers.count }
        let cues = files.filter { $0.role == .cue }.count
        return cues > 0 ? cues : files.filter { $0.role == .disc }.count
    }

    /// Bytes downloaded for this game across all of its files.
    var totalFileSize: Int64 { files.reduce(0) { $0 + $1.size } }
}

public struct BIOSSyncResult: Sendable, Equatable {
    /// Files in the system directory that match the server's list and their SHA-256.
    public var installed: [BIOSFileInfo]
    /// Server entries that couldn't be fetched or didn't match their hash.
    public var failed: [BIOSFileInfo]
}

/// Mirrors the server's BIOS list (`GET /v1/bios`) into a core system directory under each file's
/// canonical name. Only files it wrote itself (tracked in a manifest) are ever replaced or removed.
public struct BIOSStore: Sendable {
    public let directory: URL
    public init(directory: URL) { self.directory = directory }

    var manifestURL: URL { directory.appendingPathComponent(".supersemu-bios.json") }

    public func fileURL(for bios: BIOSFileInfo) -> URL? {
        // Cores look for exact canonical names, so anything that needs sanitizing is rejected outright.
        let name = GameCache.safeFilename(bios.filename, fallback: "")
        guard !name.isEmpty, name == bios.filename, !name.contains("/") else { return nil }
        return directory.appendingPathComponent(name)
    }

    /// BIOS files known from the last sync whose bytes still match their hash.
    public func installed() -> [BIOSFileInfo] { manifest().filter { isIntact($0.bios) }.map(\.bios) }

    /// True when `system` needs no BIOS or a verified one is installed.
    public static func isSatisfied(_ system: SystemID, by installed: [BIOSFileInfo]) -> Bool {
        !system.requiresBIOS || installed.contains { $0.system == system }
    }

    /// Downloads anything missing or changed, verifies each file's SHA-256 before it becomes visible
    /// to the core, and removes app-written files whose names the server no longer lists.
    /// Files the app didn't write are never replaced or removed; a matching one counts as installed.
    /// A failed replacement keeps the previous app-written copy.
    public func sync(_ list: [BIOSFileInfo], fetch: @Sendable (BIOSFileInfo) async throws -> Data) async throws -> BIOSSyncResult {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let previous = manifest()
        let ownedNames = Set(previous.filter(\.owned).compactMap { fileURL(for: $0.bios)?.lastPathComponent })
        let listedNames = Set(list.compactMap { fileURL(for: $0)?.lastPathComponent })
        var entries: [ManifestEntry] = []
        var failed: [BIOSFileInfo] = []
        var claimed = Set<String>()
        // Required files first so they win a canonical-name clash with an optional variant.
        for bios in list.sorted(by: { $0.required && !$1.required }) {
            try Task.checkCancellation()
            guard GameCache.isSHA256(bios.id), let url = fileURL(for: bios), !claimed.contains(url.lastPathComponent) else {
                failed.append(bios)
                continue
            }
            let name = url.lastPathComponent
            let owned = ownedNames.contains(name)
            claimed.insert(name)
            if isIntact(bios) {
                entries.append(ManifestEntry(bios: bios, owned: owned))
                continue
            }
            if !owned, FileManager.default.fileExists(atPath: url.path) {
                failed.append(bios)
                continue
            }
            do {
                let data = try await fetch(bios)
                guard Self.sha256(data) == bios.id.lowercased() else { throw DownloadError.checksumMismatch(filename: bios.filename) }
                try data.write(to: url, options: .atomic)
                entries.append(ManifestEntry(bios: bios, owned: true))
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                failed.append(bios)
                entries += previous.filter { $0.owned && fileURL(for: $0.bios)?.lastPathComponent == name && isIntact($0.bios) }
            }
        }
        for stale in previous where stale.owned {
            guard let url = fileURL(for: stale.bios), !listedNames.contains(url.lastPathComponent) else { continue }
            try? FileManager.default.removeItem(at: url)
        }
        try SupersEmuJSON.encoder().encode(entries).write(to: manifestURL, options: .atomic)
        return BIOSSyncResult(installed: entries.map(\.bios), failed: failed)
    }

    struct ManifestEntry: Codable, Equatable {
        var bios: BIOSFileInfo
        /// Written by sync (so sync may replace or delete it), as opposed to placed by the user.
        var owned: Bool
    }

    static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func manifest() -> [ManifestEntry] {
        guard let data = try? Data(contentsOf: manifestURL) else { return [] }
        return (try? SupersEmuJSON.decoder().decode([ManifestEntry].self, from: data)) ?? []
    }

    private func isIntact(_ bios: BIOSFileInfo) -> Bool {
        guard let url = fileURL(for: bios), FileManager.default.fileExists(atPath: url.path) else { return false }
        return (try? GameDownloader.sha256(of: url)) == bios.id.lowercased()
    }
}
