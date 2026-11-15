import CryptoKit
import Foundation

public extension SystemID {
    /// Disc systems whose cores need a BIOS dump in the system directory before a game can boot.
    var requiresBIOS: Bool { self == .psx || self == .segacd || self == .ps2 }

    /// Systems with BIOS files to manage: the required ones plus Dreamcast, whose BIOS is optional (Flycast has an HLE BIOS).
    var usesBIOS: Bool { requiresBIOS || self == .dreamcast }

    /// BIOS files this device syncs. PS2 runs on the Mac only, so iPhone/iPad skip its 4 MB BIOS.
    var syncsBIOSOnThisPlatform: Bool {
        #if os(macOS)
        return true
        #else
        return self != .ps2
        #endif
    }

    /// `syncsBIOSOnThisPlatform` as a set, the default for `BIOSStore`.
    static var biosSyncedOnThisPlatform: Set<SystemID> { Set(allCases.filter(\.syncsBIOSOnThisPlatform)) }
}

public extension BIOSFileInfo {
    /// Where the core looks for this file, relative to the system directory (e.g. `pcsx2/bios/<name>`).
    var relativePath: String { system.biosRelativePath(filename) }
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
    /// Dumps recognised by MD5 when the user puts them in the directory themselves.
    public let known: [KnownBIOS]
    /// Systems whose BIOS files this device keeps; others are skipped (and removed if sync wrote them earlier).
    public let systems: Set<SystemID>
    public init(directory: URL, known: [KnownBIOS] = KnownBIOS.all, systems: Set<SystemID> = SystemID.biosSyncedOnThisPlatform) {
        self.directory = directory
        self.known = known.filter { systems.contains($0.system) }
        self.systems = systems
    }

    var manifestURL: URL { directory.appendingPathComponent(".supersemu-bios.json") }

    public func fileURL(for bios: BIOSFileInfo) -> URL? {
        // Cores look for exact canonical names, so anything that needs sanitizing is rejected outright.
        let name = GameCache.safeFilename(bios.filename, fallback: "")
        guard !name.isEmpty, name == bios.filename, !name.contains("/") else { return nil }
        return directory.appendingPathComponent(bios.system.biosRelativePath(name))
    }

    /// BIOS files from the last sync whose bytes still match their hash, plus known dumps the user put under
    /// their canonical names (so those count offline, before any sync).
    public func installed() -> [BIOSFileInfo] { withUserPlaced(manifest().filter { isIntact($0.bios) }.map(\.bios)) }

    func withUserPlaced(_ synced: [BIOSFileInfo]) -> [BIOSFileInfo] {
        let paths = Set(synced.map(\.relativePath))
        let placed = known.filter { !paths.contains($0.relativePath) }.compactMap(userPlaced)
        let found = synced + placed
        return found + userPlacedByContent(excluding: Set(found.filter(\.system.biosMatchedByContent).map(\.id)))
    }

    /// Known dumps under any name in a folder whose core scans it (PS2's `pcsx2/bios/`), e.g. `SCPH-70012.bin`.
    func userPlacedByContent(excluding ids: Set<String>) -> [BIOSFileInfo] {
        var found: [BIOSFileInfo] = []
        var seen = ids
        for system in SystemID.allCases where system.biosMatchedByContent && systems.contains(system) {
            let candidates = known.filter { $0.system == system }
            guard let folder = system.biosSubdirectory, !candidates.isEmpty else { continue }
            let sizes = Set(candidates.map(\.size))
            let urls = (try? FileManager.default.contentsOfDirectory(at: directory.appendingPathComponent(folder),
                                                                    includingPropertiesForKeys: [.fileSizeKey], options: [.skipsHiddenFiles])) ?? []
            for url in urls.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                guard let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init), sizes.contains(size),
                      let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { continue }
                let md5 = Insecure.MD5.hash(data: data).hexString
                guard let match = candidates.first(where: { $0.md5 == md5 && $0.size == size }) else { continue }
                let id = Self.sha256(data)
                guard seen.insert(id).inserted else { continue }
                found.append(BIOSFileInfo(id: id, filename: url.lastPathComponent, system: system, region: match.region, required: match.required))
            }
        }
        return found
    }

    /// The file under `known`'s canonical name, if it is that dump (size + MD5).
    func userPlaced(_ known: KnownBIOS) -> BIOSFileInfo? {
        let url = directory.appendingPathComponent(known.relativePath)
        guard let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value,
              size == known.size, let data = try? Data(contentsOf: url, options: .mappedIfSafe),
              Insecure.MD5.hash(data: data).hexString == known.md5 else { return nil }
        return BIOSFileInfo(id: Self.sha256(data), filename: known.filename, system: known.system, region: known.region, required: known.required)
    }

    /// A synced file the user has since replaced with a known dump of their own.
    func isUserReplaced(_ entry: ManifestEntry) -> Bool {
        !isIntact(entry.bios) && known.contains { $0.relativePath == entry.bios.relativePath && userPlaced($0) != nil }
    }

    /// True when `system` needs no BIOS or a verified one is installed.
    public static func isSatisfied(_ system: SystemID, by installed: [BIOSFileInfo]) -> Bool {
        !system.requiresBIOS || installed.contains { $0.system == system }
    }

    /// Downloads anything missing or changed, verifies each file's SHA-256 before it becomes visible
    /// to the core, and removes app-written files whose names the server no longer lists.
    /// Files the app didn't write are never replaced or removed; a matching one (or a known dump) counts as installed.
    /// A failed replacement keeps the previous app-written copy.
    public func sync(_ list: [BIOSFileInfo], fetch: @Sendable (BIOSFileInfo) async throws -> Data) async throws -> BIOSSyncResult {
        let list = list.filter { systems.contains($0.system) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let previous = manifest()
        let ownedNames = Set(previous.filter { $0.owned && !isUserReplaced($0) }.compactMap { fileURL(for: $0.bios)?.path })
        let listedNames = Set(list.compactMap { fileURL(for: $0)?.path })
        var entries: [ManifestEntry] = []
        var failed: [BIOSFileInfo] = []
        var claimed = Set<String>()
        // Required files first so they win a canonical-name clash with an optional variant.
        for bios in list.sorted(by: { $0.required && !$1.required }) {
            try Task.checkCancellation()
            guard GameCache.isSHA256(bios.id), let url = fileURL(for: bios), !claimed.contains(url.path) else {
                failed.append(bios)
                continue
            }
            let name = url.path
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
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try data.write(to: url, options: .atomic)
                entries.append(ManifestEntry(bios: bios, owned: true))
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                failed.append(bios)
                entries += previous.filter { $0.owned && fileURL(for: $0.bios)?.path == name && isIntact($0.bios) }
            }
        }
        // Only delete bytes that are still exactly what sync wrote.
        for stale in previous where stale.owned && isIntact(stale.bios) {
            guard let url = fileURL(for: stale.bios), !listedNames.contains(url.path) else { continue }
            try? FileManager.default.removeItem(at: url)
        }
        try SyncStateFile.write(entries, to: manifestURL)
        return BIOSSyncResult(installed: withUserPlaced(entries.map(\.bios)), failed: failed)
    }

    struct ManifestEntry: Codable, Equatable {
        var bios: BIOSFileInfo
        /// Written by sync (so sync may replace or delete it), as opposed to placed by the user.
        var owned: Bool
    }

    static func sha256(_ data: Data) -> String {
        Hashing.sha256Hex(data)
    }

    private func manifest() -> [ManifestEntry] {
        SyncStateFile.read([ManifestEntry].self, from: manifestURL) ?? []
    }

    private func isIntact(_ bios: BIOSFileInfo) -> Bool {
        guard let url = fileURL(for: bios), FileManager.default.fileExists(atPath: url.path) else { return false }
        return (try? GameDownloader.sha256(of: url)) == bios.id.lowercased()
    }
}
