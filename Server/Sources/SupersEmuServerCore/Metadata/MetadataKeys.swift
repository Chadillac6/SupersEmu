import Foundation
import SupersEmuKit

/// API keys for the optional providers. Environment variables win over `<data-dir>/metadata.keys` (JSON, mode 0600).
/// Keys never leave the server: no route returns them, nothing logs them, and backups skip the file.
public struct MetadataKeys: Codable, Sendable, Equatable {
    public enum Name: String, CaseIterable, Sendable {
        case igdbClientID = "igdb-client-id"
        case igdbClientSecret = "igdb-client-secret"
        case steamGridDB = "steamgriddb"

        public var environmentVariable: String {
            switch self {
            case .igdbClientID: "SUPERSEMU_IGDB_CLIENT_ID"
            case .igdbClientSecret: "SUPERSEMU_IGDB_CLIENT_SECRET"
            case .steamGridDB: "SUPERSEMU_STEAMGRIDDB_KEY"
            }
        }
    }

    var values: [String: String] = [:]

    public init() {}

    public subscript(name: Name) -> String? {
        get { values[name.rawValue].flatMap { $0.isEmpty ? nil : $0 } }
        set { values[name.rawValue] = newValue }
    }

    public static func url(_ paths: ServerPaths) -> URL { paths.root.appendingPathComponent("metadata.keys") }

    /// Read on every pass, so `metadata set-key` takes effect without a restart.
    public static func load(paths: ServerPaths, environment: [String: String] = ProcessInfo.processInfo.environment) -> MetadataKeys {
        var keys = MetadataKeys()
        if let data = try? Data(contentsOf: url(paths)), let stored = try? JSONDecoder().decode([String: String].self, from: data) {
            keys.values = stored
        }
        for name in Name.allCases {
            if let value = environment[name.environmentVariable]?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty {
                keys[name] = value
            }
        }
        return keys
    }

    /// Stores (or with nil, removes) one key in the file. Environment variables are left alone.
    public static func set(_ name: Name, to value: String?, paths: ServerPaths) throws {
        var stored = (try? Data(contentsOf: url(paths))).flatMap { try? JSONDecoder().decode([String: String].self, from: $0) } ?? [:]
        stored[name.rawValue] = value.flatMap { $0.isEmpty ? nil : $0 }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let fm = FileManager.default
        try fm.createDirectory(at: paths.root, withIntermediateDirectories: true)
        let temp = paths.root.appendingPathComponent(".metadata.keys.\(UUID().uuidString)")
        guard fm.createFile(atPath: temp.path, contents: try encoder.encode(stored), attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        guard rename(temp.path, url(paths).path) == 0 else {
            try? fm.removeItem(at: temp)
            throw CocoaError(.fileWriteUnknown)
        }
    }

    public var igdb: (clientID: String, secret: String)? {
        guard let id = self[.igdbClientID], let secret = self[.igdbClientSecret] else { return nil }
        return (id, secret)
    }
}

/// Loose title comparison for providers that search by name: case, accents, punctuation and a leading "The" are ignored.
enum TitleMatch {
    static func normalized(_ title: String) -> String {
        var value = title.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US"))
        value = value.replacingOccurrences(of: "&", with: "and")
        if value.hasPrefix("the ") { value.removeFirst(4) }
        return String(value.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }.map(Character.init))
    }

    static func same(_ a: String, _ b: String) -> Bool {
        let a = normalized(a), b = normalized(b)
        return !a.isEmpty && a == b
    }
}

extension SystemID {
    /// What Wikipedia, IGDB and IGN call the console, for search queries.
    var searchName: String {
        switch self {
        case .snes: "Super Nintendo"
        case .gb: "Game Boy"
        case .gbc: "Game Boy Color"
        case .gba: "Game Boy Advance"
        case .genesis: "Sega Genesis"
        case .segacd: "Sega CD"
        case .sega32x: "32X"
        case .psx: "PlayStation"
        case .n64: "Nintendo 64"
        }
    }
}
