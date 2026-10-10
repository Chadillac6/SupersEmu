import CryptoKit
import Foundation
import SupersEmuKit

/// No-Intro/Redump hash matching via libretro-database DATs, artwork from libretro-thumbnails. No API key.
public actor LibretroMetadataProvider: MetadataProvider {
    public nonisolated let id = "libretro"
    public nonisolated let catalog: MetadataCatalog
    public nonisolated var version: String { catalog.databaseCommit }
    let cacheRoot: URL
    let http: RateLimitedFetcher
    private var indexes: [SystemID: DatIndex] = [:]

    /// Supplement DAT kind -> the field it carries.
    static let supplements = ["genre": "genre", "releaseyear": "releaseyear", "publisher": "publisher",
                              "developer": "developer", "maxusers": "users"]
    static let thumbnailFolders: [(ArtworkKind, String)] = [(.cover, "Named_Boxarts"), (.title, "Named_Titles"),
                                                            (.screenshot, "Named_Snaps")]

    /// `cacheRoot` is normally `<data-dir>/metadata`.
    public init(catalog: MetadataCatalog = .pinned, cacheRoot: URL, http: RateLimitedFetcher) {
        self.catalog = catalog
        self.cacheRoot = cacheRoot
        self.http = http
    }

    public func lookup(_ game: MetadataLookup) async throws -> MetadataLookupResult {
        guard let set = catalog.systems[game.system] else { return .unmatched }
        let index: DatIndex
        do {
            index = try await self.index(for: game.system, set: set)
        } catch {
            return .unavailable
        }
        for url in game.files {
            for hashes in (try? ROMHasher.variants(of: url, system: game.system)) ?? [] {
                guard let entry = index.match(hashes) else { continue }
                func value(_ kind: String) -> String? { index.supplement(Self.supplements[kind]!, crc: entry.crc, serial: entry.serial) }
                return .matched(MetadataRecord(
                    provider: id, providerRef: entry.name, title: CanonicalName.title(entry.name),
                    region: entry.region ?? CanonicalName.region(entry.name),
                    year: value("releaseyear").flatMap { Int($0.prefix(4)) }, publisher: value("publisher"),
                    developer: value("developer"), genres: value("genre").map { [$0] }, players: value("maxusers").flatMap { Int($0) },
                    source: MetadataSource(provider: id, name: "\(set.source == "redump" ? "Redump" : "No-Intro") via libretro-database",
                                           url: catalog.datURL(set, kind: "source").absoluteString)))
            }
        }
        return .unmatched
    }

    public nonisolated func artwork(for record: MetadataRecord, system: SystemID) -> [ArtworkCandidate] {
        guard let set = catalog.systems[system], let name = record.providerRef else { return [] }
        let names = [name, CanonicalName.withoutDiscNumber(name)].compactMap { $0 }.map(CanonicalName.thumbnailName)
        return Self.thumbnailFolders.map { kind, folder in
            ArtworkCandidate(kind: kind, position: 0, urls: names.map { catalog.thumbnailURL(set, kind: folder, name: $0) })
        }
    }

    public nonisolated func artworkVersion(system: SystemID) -> String {
        catalog.systems[system]?.thumbnailsCommit ?? version
    }

    /// Every pinned DAT must load, or the lookup is retried later rather than matching with missing fields.
    func index(for system: SystemID, set: MetadataCatalog.SystemSet) async throws -> DatIndex {
        if let index = indexes[system] { return index }
        var index = DatIndex(dat: try await dat(set, kind: "source"))
        for (kind, field) in Self.supplements.sorted(by: { $0.key < $1.key }) where set.files[kind] != nil {
            index.addSupplement(field: field, dat: try await dat(set, kind: kind))
        }
        indexes[system] = index
        return index
    }

    /// `metadata/libretro-database/<commit>/<folder>/<name>.dat`, downloaded once and verified against the pinned SHA-256.
    func dat(_ set: MetadataCatalog.SystemSet, kind: String) async throws -> String {
        guard let expected = set.files[kind] else { throw LibretroError.notPinned }
        let url = cacheRoot.appendingPathComponent("libretro-database").appendingPathComponent(catalog.databaseCommit)
            .appendingPathComponent(kind == "source" ? set.source : kind).appendingPathComponent("\(set.name).dat")
        if let data = try? Data(contentsOf: url), SHA256.hash(data: data).hex == expected {
            return String(decoding: data, as: UTF8.self)
        }
        guard let data = try await http.get(catalog.datURL(set, kind: kind)) else { throw LibretroError.notFound }
        guard SHA256.hash(data: data).hex == expected else { throw LibretroError.checksumMismatch }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
        return String(decoding: data, as: UTF8.self)
    }

    enum LibretroError: Error { case notPinned, notFound, checksumMismatch }
}
