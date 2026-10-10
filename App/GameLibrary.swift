import CryptoKit
import Foundation
import SupersEmuKit
import Observation

struct Game: Identifiable, Hashable {
    /// SHA-256 of the ROM contents; stable across renames and devices.
    let id: String
    let title: String
    let fileURL: URL
    let console: String
    let hasResumePoint: Bool
}

enum AppPaths {
    static let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("SupersEmu", isDirectory: true)
    static let library = root.appendingPathComponent("Library/SNES", isDirectory: true)
    static let saves = root.appendingPathComponent("Saves", isDirectory: true)
    static let states = root.appendingPathComponent("States", isDirectory: true)
    static let system = root.appendingPathComponent("System", isDirectory: true)
    /// Downloaded server games: Cache/<gameID>/<files> + manifest.json.
    static let cache = root.appendingPathComponent("Cache", isDirectory: true)
    static let covers = root.appendingPathComponent("Covers", isDirectory: true)
    static let serverLibrarySnapshot = root.appendingPathComponent("ServerLibrary.json")

    static func autoState(for gameID: String) -> URL {
        states.appendingPathComponent(gameID, isDirectory: true).appendingPathComponent("auto.state")
    }

    static func manualState(for gameID: String) -> URL {
        states.appendingPathComponent(gameID, isDirectory: true).appendingPathComponent("slot1.state")
    }

    static func saveRAM(for gameID: String) -> URL {
        saves.appendingPathComponent("\(gameID).srm")
    }

    static func ensureDirectories() {
        for url in [library, saves, states, system, cache] {
            try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }
    }
}

enum TitleNormalizer {
    /// "Super_Game (USA) [!].sfc" -> "Super Game", "HelloWorld.sfc" -> "Hello World"
    static func title(fromFilename filename: String) -> String {
        var title = (filename as NSString).deletingPathExtension
        title = title.replacingOccurrences(of: #"\s*[\(\[][^\)\]]*[\)\]]"#, with: "", options: .regularExpression)
        title = title.replacingOccurrences(of: "_", with: " ")
        title = title.replacingOccurrences(of: #"([a-z])([A-Z])"#, with: "$1 $2", options: .regularExpression)
        title = title.trimmingCharacters(in: .whitespaces)
        return title.isEmpty ? filename : title
    }
}

@MainActor
@Observable
final class GameLibrary {
    static let supportedExtensions = CoreRegistry.supportedExtensions

    /// Console for a local ROM, from the core that handles its extension ("gbc" stays GBC, "dmg" -> GB).
    static func system(for fileURL: URL) -> SystemID? {
        let ext = fileURL.pathExtension.lowercased()
        guard let core = CoreRegistry.core(forExtension: ext) else { return nil }
        if let system = SystemID(rawValue: ext), core.systems.contains(system.rawValue) { return system }
        let system = core.systems.first.flatMap(SystemID.init(rawValue:))
        return system == .genesis && is32X(fileURL) ? .sega32x : system
    }

    /// Same check as the server's `SystemDetector`: "SEGA ... 32X" system name at 0x100, or "MARS" at 0x3C0.
    static func is32X(_ url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        guard let bytes = try? handle.read(upToCount: 0x3C4), bytes.count >= 0x110 else { return false }
        let header = String(decoding: bytes[0x100..<0x110], as: UTF8.self)
        guard header.contains("SEGA") else { return false }
        return header.contains("32X") || (bytes.count >= 0x3C4 && bytes[0x3C0..<0x3C4].elementsEqual("MARS".utf8))
    }

    private(set) var games: [Game] = []
    var importMessage: String?

    init() {
        AppPaths.ensureDirectories()
        refresh()
        if let dir = ProcessInfo.processInfo.environment["SUPERSEMU_IMPORT_DIR"] {
            let urls = (try? FileManager.default.contentsOfDirectory(
                at: URL(fileURLWithPath: dir), includingPropertiesForKeys: nil)) ?? []
            importFiles(urls)
        }
    }

    func refresh() {
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: AppPaths.library, includingPropertiesForKeys: nil)) ?? []
        games = urls
            .filter { Self.supportedExtensions.contains($0.pathExtension.lowercased()) }
            .compactMap { url in
                guard let id = try? Self.sha256(of: url) else { return nil }
                return Game(
                    id: id,
                    title: TitleNormalizer.title(fromFilename: url.lastPathComponent),
                    fileURL: url,
                    console: Self.system(for: url)?.displayName ?? "Unknown console",
                    hasResumePoint: FileManager.default.fileExists(atPath: AppPaths.autoState(for: id).path))
            }
            .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }

    func importFiles(_ urls: [URL]) {
        var imported = 0, duplicates = 0, unsupported = 0, multiFile = 0
        var knownIDs = Set(games.map(\.id))
        for url in urls {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            if CoreRegistry.multiFileExtensions.contains(url.pathExtension.lowercased()) {
                multiFile += 1
                continue
            }
            guard Self.supportedExtensions.contains(url.pathExtension.lowercased()),
                  let id = try? Self.sha256(of: url) else {
                unsupported += 1
                continue
            }
            guard !knownIDs.contains(id) else {
                duplicates += 1
                continue
            }
            var destination = AppPaths.library.appendingPathComponent(url.lastPathComponent)
            if FileManager.default.fileExists(atPath: destination.path) {
                destination = AppPaths.library.appendingPathComponent(
                    "\(url.deletingPathExtension().lastPathComponent)-\(id.prefix(8)).\(url.pathExtension)")
            }
            do {
                try FileManager.default.copyItem(at: url, to: destination)
                knownIDs.insert(id)
                imported += 1
            } catch {
                unsupported += 1
            }
        }
        var parts = ["Imported \(imported) game\(imported == 1 ? "" : "s")"]
        if duplicates > 0 { parts.append("skipped \(duplicates) already in your library") }
        if unsupported > 0 { parts.append("\(unsupported) not recognised") }
        if multiFile > 0 { parts.append("\(multiFile) .cue/.m3u disc set\(multiFile == 1 ? "" : "s") need the home server import") }
        importMessage = parts.joined(separator: ", ")
        refresh()
    }

    nonisolated static func sha256(of url: URL) throws -> String {
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
