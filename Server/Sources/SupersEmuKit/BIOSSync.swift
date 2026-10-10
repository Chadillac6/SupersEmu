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

    /// Synced BIOS files whose bytes still match their hash.
    public func installed() -> [BIOSFileInfo] { manifest().filter(isIntact) }

    /// True when `system` needs no BIOS or a verified one is installed.
    public static func isSatisfied(_ system: SystemID, by installed: [BIOSFileInfo]) -> Bool {
        !system.requiresBIOS || installed.contains { $0.system == system }
    }

    /// Downloads anything missing or changed, verifies each file's SHA-256 before it becomes visible
    /// to the core, and removes previously synced files the server no longer lists.
    public func sync(_ list: [BIOSFileInfo], fetch: @Sendable (BIOSFileInfo) async throws -> Data) async throws -> BIOSSyncResult {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var installed: [BIOSFileInfo] = []
        var failed: [BIOSFileInfo] = []
        var claimed = Set<String>()
        // Required files first so they win a canonical-name clash with an optional variant.
        for bios in list.sorted(by: { $0.required && !$1.required }) {
            try Task.checkCancellation()
            guard GameCache.isSHA256(bios.id), let url = fileURL(for: bios), !claimed.contains(url.lastPathComponent) else {
                failed.append(bios)
                continue
            }
            if isIntact(bios) {
                claimed.insert(url.lastPathComponent)
                installed.append(bios)
                continue
            }
            do {
                let data = try await fetch(bios)
                guard Self.sha256(data) == bios.id.lowercased() else { throw DownloadError.checksumMismatch(filename: bios.filename) }
                try data.write(to: url, options: .atomic)
                claimed.insert(url.lastPathComponent)
                installed.append(bios)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                failed.append(bios)
            }
        }
        for stale in manifest() where !claimed.contains(fileURL(for: stale)?.lastPathComponent ?? "") {
            if let url = fileURL(for: stale) { try? FileManager.default.removeItem(at: url) }
        }
        try SupersEmuJSON.encoder().encode(installed).write(to: manifestURL, options: .atomic)
        return BIOSSyncResult(installed: installed, failed: failed)
    }

    static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func manifest() -> [BIOSFileInfo] {
        guard let data = try? Data(contentsOf: manifestURL) else { return [] }
        return (try? SupersEmuJSON.decoder().decode([BIOSFileInfo].self, from: data)) ?? []
    }

    private func isIntact(_ bios: BIOSFileInfo) -> Bool {
        guard let url = fileURL(for: bios), FileManager.default.fileExists(atPath: url.path) else { return false }
        return (try? GameDownloader.sha256(of: url)) == bios.id.lowercased()
    }
}
