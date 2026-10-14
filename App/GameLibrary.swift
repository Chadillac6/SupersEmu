import CryptoKit
import Observation
import Dispatch
import Darwin
import Foundation
import SupersEmuKit
#if os(macOS)
import AppKit
#endif

struct Game: Identifiable, Hashable, Sendable {
    /// SHA-256 of the ROM contents; stable across renames and devices.
    let id: String
    let title: String
    let fileURL: URL
    let console: String
    let hasResumePoint: Bool
}

private struct LibraryFingerprint: Hashable, Sendable {
    let path: String
    let size: Int64
    let modificationDate: Date
}

private struct LibraryFile: Sendable {
    let url: URL
    let fingerprint: LibraryFingerprint
}

private struct HashedLibraryFile: Sendable {
    let url: URL
    let fingerprint: LibraryFingerprint
    let id: String
}

private struct LibraryRefreshResult: Sendable {
    let files: [HashedLibraryFile]
    let hashes: [LibraryFingerprint: String]
    let hasUnstableFiles: Bool
}

private enum LocalLibraryScanner {
    static func refresh(
        supportedExtensions: Set<String>,
        cachedHashes: [LibraryFingerprint: String]
    ) async -> LibraryRefreshResult {
        let before = files(supportedExtensions: supportedExtensions)
        try? await Task.sleep(nanoseconds: 500_000_000)
        let after = Dictionary(
            files(supportedExtensions: supportedExtensions).map { ($0.fingerprint.path, $0) },
            uniquingKeysWith: { _, latest in latest })
        let stable = before.filter { after[$0.fingerprint.path]?.fingerprint == $0.fingerprint }
            .sorted { $0.fingerprint.path < $1.fingerprint.path }
        var hashes = cachedHashes
        let hashed = stable.compactMap { file -> HashedLibraryFile? in
            let id: String
            if let cached = hashes[file.fingerprint] {
                id = cached
            } else {
                guard let computed = try? GameLibrary.sha256(of: file.url) else { return nil }
                id = computed
                hashes[file.fingerprint] = id
            }
            return HashedLibraryFile(url: file.url, fingerprint: file.fingerprint, id: id)
        }
        return LibraryRefreshResult(
            files: hashed,
            hashes: hashes,
            hasUnstableFiles: before.count != stable.count || after.count != stable.count
        )
    }

    private static func files(supportedExtensions: Set<String>) -> [LibraryFile] {
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: AppPaths.library,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles])) ?? []
        return urls.compactMap { url in
            guard supportedExtensions.contains(url.pathExtension.lowercased()),
                  let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey]),
                  values.isRegularFile == true,
                  let size = values.fileSize,
                  let modificationDate = values.contentModificationDate else { return nil }
            return LibraryFile(
                url: url,
                fingerprint: LibraryFingerprint(path: url.standardizedFileURL.path, size: Int64(size), modificationDate: modificationDate))
        }
    }
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

    static func stateDirectory(for gameID: String) -> URL {
        states.appendingPathComponent(gameID, isDirectory: true)
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

    @ObservationIgnored private var fileWatcher: DispatchSourceFileSystemObject?
    @ObservationIgnored private var wakeObserver: NSObjectProtocol?
    @ObservationIgnored private var refreshTask: Task<Void, Never>?
    @ObservationIgnored private var hashes: [LibraryFingerprint: String] = [:]
    @ObservationIgnored private var isRefreshing = false
    @ObservationIgnored private var refreshAgain = false

    init() {
        AppPaths.ensureDirectories()
        startWatchingLibrary()
        observeWake()
        let importURLs: [URL]? = ProcessInfo.processInfo.environment["SUPERSEMU_IMPORT_DIR"].map { dir in
            (try? FileManager.default.contentsOfDirectory(
                at: URL(fileURLWithPath: dir), includingPropertiesForKeys: nil)) ?? []
        }
        Task { @MainActor [weak self] in
            guard let self else { return }
            await self.rebuildGames()
            if let importURLs { self.importFiles(importURLs) }
        }
    }

    private func startWatchingLibrary() {
        let descriptor = open(AppPaths.library.path, O_EVTONLY)
        guard descriptor >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: [.write, .delete, .rename, .attrib, .extend],
            queue: DispatchQueue.global(qos: .utility))
        source.setEventHandler { [weak self] in
            Task { @MainActor [weak self] in self?.scheduleRefresh(after: .seconds(1)) }
        }
        source.setCancelHandler { close(descriptor) }
        source.resume()
        fileWatcher = source
    }

    private func observeWake() {
        #if os(macOS)
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.refresh() }
        }
        #endif
    }

    func refresh() {
        scheduleRefresh(after: .zero)
    }

    private func scheduleRefresh(after delay: Duration) {
        if isRefreshing {
            refreshAgain = true
            return
        }
        refreshTask?.cancel()
        refreshTask = Task { @MainActor [weak self] in
            if delay > .zero { try? await Task.sleep(for: delay) }
            guard !Task.isCancelled, let self else { return }
            await self.rebuildGames()
        }
    }

    private func rebuildGames() async {
        guard !isRefreshing else {
            refreshAgain = true
            return
        }
        isRefreshing = true
        let supportedExtensions = Self.supportedExtensions
        let cachedHashes = hashes
        let result = await Task.detached(priority: .utility) {
            await LocalLibraryScanner.refresh(
                supportedExtensions: supportedExtensions,
                cachedHashes: cachedHashes)
        }.value
        hashes = result.hashes
        var seenIDs = Set<String>()
        let refreshedGames = result.files.compactMap { file -> Game? in
            guard seenIDs.insert(file.id).inserted else { return nil }
            return Game(
                    id: file.id,
                    title: TitleNormalizer.title(fromFilename: file.url.lastPathComponent),
                    fileURL: file.url,
                    console: Self.system(for: file.url)?.displayName ?? "Unknown console",
                    hasResumePoint: FileManager.default.fileExists(atPath: AppPaths.autoState(for: file.id).path))
        }
            .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        if Set(refreshedGames) != Set(games) { games = refreshedGames }
        isRefreshing = false
        refreshTask = nil
        let shouldRefreshAgain = refreshAgain || result.hasUnstableFiles
        refreshAgain = false
        if shouldRefreshAgain { scheduleRefresh(after: .seconds(1)) }
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
