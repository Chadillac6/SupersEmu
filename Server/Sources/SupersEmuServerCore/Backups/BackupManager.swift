import CryptoKit
import Foundation
import GRDB
import SupersEmuKit

public enum BackupError: Error, CustomStringConvertible, Equatable {
    case destinationUnavailable(String)
    case notFound(String)
    case corrupted(String)
    case alreadyRunning
    case restoreUnavailable
    case invalidConfig(String)

    public var description: String {
        switch self {
        case .destinationUnavailable(let path): return "Backup destination isn't available: \(path). Is the drive connected?"
        case .notFound(let id): return "No backup \(id)"
        case .corrupted(let reason): return "Backup failed verification: \(reason)"
        case .alreadyRunning: return "A backup or restore is already running"
        case .restoreUnavailable: return "Restore needs the server daemon (supersemu-server run)"
        case .invalidConfig(let reason): return reason
        }
    }
}

/// `manifest.json` at the root of every backup folder.
public struct BackupManifest: Codable, Sendable, Equatable {
    public struct File: Codable, Sendable, Equatable {
        public var path: String
        public var size: Int64
        public var sha256: String
    }

    public static let currentFormat = 1
    public var format: Int
    public var id: String
    public var createdAt: Date
    public var serverName: String
    public var serverVersion: String
    public var includesROMs: Bool
    public var files: [File]
}

/// Consistent backups of a server data directory.
///
/// A backup is a folder `SupersEmu-<id>` in the destination with `library.sqlite` (written with SQLite's online
/// backup API, so it's consistent while the server keeps serving), save revisions and profiles (`users/`), artwork,
/// the TLS identity and admin token (so paired devices keep trusting the server after a restore) and other settings,
/// plus `manifest.json` with a SHA-256 for every file. ROMs (`games/`) and BIOS files are only copied with
/// `includeROMs`; the BIOS index is always in the database.
public actor BackupManager {
    public nonisolated let paths: ServerPaths
    private let db: any DatabaseWriter
    private let serverName: String
    private var busy = false
    private var restoreHandler: (@Sendable (BackupInfo) async -> Void)?

    static let folderPrefix = "SupersEmu-"
    static let manifestName = "manifest.json"
    /// Persisted next to the database; not part of backups (it describes where backups go).
    nonisolated var stateURL: URL { paths.root.appendingPathComponent("backups.json") }

    struct State: Codable {
        var config = BackupConfig()
        var last: BackupRunResult?
        var lastSuccessAt: Date?
    }

    public init(paths: ServerPaths, db: any DatabaseWriter, serverName: String) {
        self.paths = paths
        self.db = db
        self.serverName = serverName
    }

    // MARK: Config and status

    func loadState() -> State {
        guard let data = try? Data(contentsOf: stateURL),
              let state = try? Self.decoder.decode(State.self, from: data) else { return State() }
        return state
    }

    private func save(_ state: State) {
        try? Self.encoder.encode(state).write(to: stateURL, options: .atomic)
    }

    public func config() -> BackupConfig { loadState().config }

    @discardableResult
    public func updateConfig(_ update: BackupConfigUpdate) throws -> BackupConfig {
        var state = loadState()
        if let destination = update.destination {
            let trimmed = destination.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.isEmpty || trimmed.hasPrefix("/") else { throw BackupError.invalidConfig("destination must be an absolute path") }
            guard trimmed.isEmpty || isSafeDestination(URL(fileURLWithPath: trimmed, isDirectory: true)) else {
                throw BackupError.invalidConfig("destination can't be inside the server's data folder (other than \(paths.root.path)/Backups)")
            }
            state.config.destination = trimmed.isEmpty ? nil : trimmed
        }
        if let keep = update.keep {
            guard (1...365).contains(keep) else { throw BackupError.invalidConfig("keep must be between 1 and 365") }
            state.config.keep = keep
        }
        if let hour = update.hour {
            guard (0...23).contains(hour) else { throw BackupError.invalidConfig("hour must be between 0 and 23") }
            state.config.hour = hour
        }
        if let includeROMs = update.includeROMs { state.config.includeROMs = includeROMs }
        if let enabled = update.scheduleEnabled { state.config.scheduleEnabled = enabled }
        save(state)
        return state.config
    }

    public nonisolated func destination(for config: BackupConfig) -> URL {
        config.destination.map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? paths.root.appendingPathComponent("Backups", isDirectory: true)
    }

    /// Paths under `/Volumes/<name>` need that volume mounted; we never create a folder where an unplugged drive was.
    nonisolated func destinationAvailable(_ url: URL) -> Bool {
        let components = url.standardizedFileURL.pathComponents
        if components.count >= 3, components[1] == "Volumes" {
            var isDirectory: ObjCBool = false
            let volume = "/Volumes/" + components[2]
            return FileManager.default.fileExists(atPath: volume, isDirectory: &isDirectory) && isDirectory.boolValue
        }
        return true
    }

    public func overview(now: Date = Date()) -> BackupOverview {
        let state = loadState()
        let destination = destination(for: state.config)
        let available = destinationAvailable(destination)
        return BackupOverview(
            config: state.config, destination: destination.path, destinationAvailable: available,
            last: state.last, lastSuccessAt: state.lastSuccessAt,
            nextScheduledAt: Self.nextRun(config: state.config, lastAttempt: state.last?.at, now: now),
            running: busy, backups: available ? list(in: destination) : [])
    }

    public func list() -> [BackupInfo] { list(in: destination(for: loadState().config)) }

    private func list(in destination: URL) -> [BackupInfo] {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(at: destination, includingPropertiesForKeys: nil) else { return [] }
        return entries
            .filter { $0.lastPathComponent.hasPrefix(Self.folderPrefix) }
            .compactMap { folder in (try? Self.readManifest(folder)).map { Self.info($0, folder: folder) } }
            .sorted { ($0.createdAt, $0.id) > ($1.createdAt, $1.id) }
    }

    /// Next daily run: today's slot if it hasn't been attempted yet (also catches up after the Mac was off), else tomorrow's.
    static func nextRun(config: BackupConfig, lastAttempt: Date?, now: Date, calendar: Calendar = .current) -> Date? {
        guard config.scheduleEnabled,
              let today = calendar.date(bySettingHour: config.hour, minute: 0, second: 0, of: now) else { return nil }
        let slot = today <= now ? today : calendar.date(byAdding: .day, value: -1, to: today)!
        if let lastAttempt, lastAttempt >= slot { return calendar.date(byAdding: .day, value: 1, to: slot) }
        return max(slot, now)
    }

    // MARK: Create

    @discardableResult
    public func create(trigger: BackupTrigger = .manual, includeROMs: Bool? = nil, now: Date = Date()) throws -> BackupInfo {
        guard !busy else { throw BackupError.alreadyRunning }
        busy = true
        defer { busy = false }
        var state = loadState()
        do {
            let info = try makeBackup(config: state.config, includeROMs: includeROMs ?? state.config.includeROMs, now: now)
            state = loadState()
            state.last = BackupRunResult(at: now, trigger: trigger, ok: true, backupID: info.id)
            state.lastSuccessAt = now
            save(state)
            prune(keep: state.config.keep, in: destination(for: state.config))
            return info
        } catch {
            state = loadState()
            state.last = BackupRunResult(at: now, trigger: trigger, ok: false, error: "\(error)")
            save(state)
            throw error
        }
    }

    /// A backup must never copy itself: anywhere in the data folder other than `Backups/` is refused.
    func isSafeDestination(_ url: URL) -> Bool {
        let destination = url.standardizedFileURL.resolvingSymlinksInPath().path
        let root = paths.root.standardizedFileURL.resolvingSymlinksInPath().path
        func inside(_ base: String) -> Bool { destination == base || destination.hasPrefix(base + "/") }
        return !inside(root) || inside(root + "/Backups")
    }

    private func makeBackup(config: BackupConfig, includeROMs: Bool, now: Date) throws -> BackupInfo {
        let fm = FileManager.default
        let destination = destination(for: config)
        guard isSafeDestination(destination) else { throw BackupError.invalidConfig("destination is inside the server's data folder") }
        guard destinationAvailable(destination) else { throw BackupError.destinationUnavailable(destination.path) }
        try fm.createDirectory(at: destination, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])

        var id = Self.idFormatter.string(from: now)
        var suffix = 1
        while fm.fileExists(atPath: destination.appendingPathComponent(Self.folderPrefix + id).path) {
            suffix += 1
            id = Self.idFormatter.string(from: now) + "-\(suffix)"
        }
        let staging = destination.appendingPathComponent(".\(Self.folderPrefix)\(id).partial", isDirectory: true)
        try? fm.removeItem(at: staging)
        try fm.createDirectory(at: staging, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        // It holds the admin token and TLS key, so it stays private even in a shared destination.
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: staging.path)
        do {
            let items = Self.items(paths: paths, includeROMs: includeROMs).filter { $0 != "library.sqlite" }
            func copyItem(_ item: String) throws {
                let source = (Self.libraryItems.contains(item) ? paths.libraryRoot : paths.root).appendingPathComponent(item)
                guard fm.fileExists(atPath: source.path) else { return }
                try fm.copyItem(at: source, to: staging.appendingPathComponent(item))
            }
            let copy = try DatabaseQueue(path: staging.appendingPathComponent("library.sqlite").path)
            // Holding the writer: no upload can commit (and then delete pruned save files) until the save files
            // the snapshot references are copied. ROMs are copied after, they're only added or removed by imports.
            try db.writeWithoutTransaction { source in
                try copy.writeWithoutTransaction { try source.backup(to: $0) }
                for item in items where item != "games" && item != "bios" { try copyItem(item) }
            }
            // The copy inherits WAL mode; a single self-contained file verifies (read-only) and restores cleanly.
            try copy.writeWithoutTransaction { try $0.execute(sql: "PRAGMA journal_mode=DELETE") }
            try copy.close()
            for item in items where item == "games" || item == "bios" { try copyItem(item) }
            let manifest = BackupManifest(
                format: BackupManifest.currentFormat, id: id, createdAt: now, serverName: serverName,
                serverVersion: ServerInfo.version, includesROMs: includeROMs, files: try Self.hashFiles(in: staging))
            try Self.encoder.encode(manifest).write(to: staging.appendingPathComponent(Self.manifestName))
            _ = try Self.verify(folder: staging)
            let final = destination.appendingPathComponent(Self.folderPrefix + id, isDirectory: true)
            try fm.moveItem(at: staging, to: final)
            return Self.info(manifest, folder: final)
        } catch {
            try? fm.removeItem(at: staging)
            throw error
        }
    }

    /// Top-level entries of the data directory that go into a backup.
    static func items(paths: ServerPaths, includeROMs: Bool) -> [String] {
        var items = ["library.sqlite", "users", "artwork", "tls", "admin.token"]
        let settings = ((try? FileManager.default.contentsOfDirectory(atPath: paths.root.path)) ?? [])
            .filter { $0.hasSuffix(".json") && $0 != "backups.json" && $0 != "ddns-state.json" }
            .sorted()
        items += settings
        if includeROMs { items += ["games", "bios"] }
        return items
    }

    private func prune(keep: Int, in destination: URL) {
        let fm = FileManager.default
        for old in list(in: destination).dropFirst(keep) { try? fm.removeItem(atPath: old.path) }
        let partials = (try? fm.contentsOfDirectory(atPath: destination.path))?.filter { $0.hasSuffix(".partial") } ?? []
        for name in partials { try? fm.removeItem(at: destination.appendingPathComponent(name)) }
    }

    // MARK: Verify

    public func verify(id: String) throws -> BackupInfo {
        let folder = try folder(for: id)
        return Self.info(try Self.verify(folder: folder), folder: folder)
    }

    func folder(for id: String) throws -> URL {
        guard !id.contains("/"), !id.contains("..") else { throw BackupError.notFound(id) }
        let folder = destination(for: loadState().config).appendingPathComponent(Self.folderPrefix + id, isDirectory: true)
        guard FileManager.default.fileExists(atPath: folder.appendingPathComponent(Self.manifestName).path) else { throw BackupError.notFound(id) }
        return folder
    }

    /// Checks every file against the manifest (nothing missing, extra or changed) and runs `PRAGMA integrity_check`.
    @discardableResult
    public static func verify(folder: URL) throws -> BackupManifest {
        let manifest: BackupManifest
        do { manifest = try readManifest(folder) } catch { throw BackupError.corrupted("manifest.json is missing or unreadable") }
        guard manifest.format <= BackupManifest.currentFormat else { throw BackupError.corrupted("made by a newer server (format \(manifest.format))") }
        let actual = try hashFiles(in: folder)
        let expected = Dictionary(manifest.files.map { ($0.path, $0) }, uniquingKeysWith: { a, _ in a })
        let found = Dictionary(actual.map { ($0.path, $0) }, uniquingKeysWith: { a, _ in a })
        if let missing = expected.keys.sorted().first(where: { found[$0] == nil }) { throw BackupError.corrupted("\(missing) is missing") }
        if let extra = found.keys.sorted().first(where: { expected[$0] == nil }) { throw BackupError.corrupted("unexpected file \(extra)") }
        if let changed = expected.keys.sorted().first(where: { expected[$0] != found[$0] }) { throw BackupError.corrupted("\(changed) checksum mismatch") }
        guard expected["library.sqlite"] != nil else { throw BackupError.corrupted("library.sqlite is missing") }

        var configuration = Configuration()
        configuration.readonly = true
        do {
            let queue = try DatabaseQueue(path: folder.appendingPathComponent("library.sqlite").path, configuration: configuration)
            defer { try? queue.close() }
            let (result, savePaths) = try queue.read { db in
                (try String.fetchAll(db, sql: "PRAGMA integrity_check"),
                 try db.tableExists("save_revisions") ? try String.fetchAll(db, sql: "SELECT stored_path FROM save_revisions") : [])
            }
            guard result == ["ok"] else { throw BackupError.corrupted("integrity_check: \(result.prefix(3).joined(separator: "; "))") }
            if let missing = savePaths.first(where: { found[$0] == nil }) { throw BackupError.corrupted("save file \(missing) is missing") }
        } catch let error as BackupError {
            throw error
        } catch {
            throw BackupError.corrupted("library.sqlite: \(error)")
        }
        return manifest
    }

    // MARK: Restore

    /// The daemon installs this; it stops serving, calls `applyRestore` and starts again.
    public func setRestoreHandler(_ handler: (@Sendable (BackupInfo) async -> Void)?) { restoreHandler = handler }

    /// Verifies the backup, then hands it to the daemon, which restores it after it has stopped serving.
    public func requestRestore(id: String) async throws -> BackupInfo {
        guard let restoreHandler else { throw BackupError.restoreUnavailable }
        guard !busy else { throw BackupError.alreadyRunning }
        let info = try verify(id: id)
        busy = true
        Task { await restoreHandler(info) }
        return info
    }

    /// Replaces the data directory's contents with a verified backup. The server must not be serving and the
    /// database must be closed. What's replaced is moved to a `.pre-restore-<date>` folder first (one per restore,
    /// in the data folder, and in the library folder for artwork, games and BIOS) and put back if anything fails.
    /// ROMs and BIOS files are left as they are unless the backup includes them.
    public struct RestoreRecord: Sendable {
        struct Kept: Sendable { let live: URL; let kept: URL }
        /// Where this restore kept the data folder's replaced files.
        public let safety: URL
        var moved: [Kept] = []
        var copied: [URL] = []

        /// Puts back what the restore replaced.
        public func revert(_ paths: ServerPaths) {
            let fm = FileManager.default
            for url in copied.reversed() { try? fm.removeItem(at: url) }
            for item in moved.reversed() {
                try? fm.removeItem(at: item.live)
                try? fm.moveItem(at: item.kept, to: item.live)
            }
            try? paths.storage.reload(config: paths.storageConfig, dataRoot: paths.root)
        }
    }

    /// Backup entries that live in the library folder, which Move Library can put on another drive.
    static let libraryItems: Set<String> = ["artwork", "games", "bios"]

    @discardableResult
    public static func applyRestore(folder: URL, to paths: ServerPaths, now: Date = Date()) throws -> RestoreRecord {
        try verify(folder: folder)
        let fm = FileManager.default
        let name = ".pre-restore-\(idFormatter.string(from: now))-\(UUID().uuidString.prefix(8).lowercased())"
        let safety = paths.root.appendingPathComponent(name, isDirectory: true)
        try fm.createDirectory(at: safety, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])

        let backedUp = Set(((try? fm.contentsOfDirectory(atPath: folder.path)) ?? []).filter { $0 != manifestName })
        let dataItems = backedUp.subtracting(libraryItems)
        var replaced = ["library.sqlite", "library.sqlite-wal", "library.sqlite-shm", "users", "tls", "admin.token"]
        // Settings files added after the backup go too, so the restored server has the backup's settings.
        let live = ((try? fm.contentsOfDirectory(atPath: paths.root.path)) ?? []).filter { $0.hasSuffix(".json") && $0 != "backups.json" }
        replaced += Set(live).union(dataItems.filter { $0.hasSuffix(".json") }).sorted()
        var record = RestoreRecord(safety: safety)
        do {
            func keep(_ live: URL, in kept: URL) throws {
                guard fm.fileExists(atPath: live.path) else { return }
                try fm.createDirectory(at: kept.deletingLastPathComponent(), withIntermediateDirectories: true,
                                       attributes: [.posixPermissions: 0o700])
                try fm.moveItem(at: live, to: kept)
                record.moved.append(.init(live: live, kept: kept))
            }
            func put(_ item: String, at live: URL) throws {
                try fm.copyItem(at: folder.appendingPathComponent(item), to: live)
                record.copied.append(live)
            }
            for item in replaced { try keep(paths.root.appendingPathComponent(item), in: safety.appendingPathComponent(item)) }
            for item in dataItems.sorted() { try put(item, at: paths.root.appendingPathComponent(item)) }
            // The restored storage.json decides where artwork, games and BIOS go.
            try paths.storage.reload(config: paths.storageConfig, dataRoot: paths.root)
            let library = backedUp.intersection(libraryItems).sorted()
            if !library.isEmpty {
                guard paths.storage.isAvailable else { throw BackupError.destinationUnavailable(paths.libraryRoot.path) }
                let librarySafety = paths.libraryRoot.appendingPathComponent(name, isDirectory: true)
                for item in library {
                    let target = paths.libraryRoot.appendingPathComponent(item)
                    try keep(target, in: librarySafety.appendingPathComponent(item))
                    try put(item, at: target)
                }
            }
            try paths.createDirectories()
        } catch {
            record.revert(paths)
            throw error
        }
        return record
    }

    func finishRestore() { busy = false }

    func nextScheduledRun(now: Date = Date()) -> Date? {
        let state = loadState()
        return Self.nextRun(config: state.config, lastAttempt: state.last?.at, now: now)
    }

    // MARK: Helpers

    static func readManifest(_ folder: URL) throws -> BackupManifest {
        try decoder.decode(BackupManifest.self, from: Data(contentsOf: folder.appendingPathComponent(manifestName)))
    }

    static func info(_ manifest: BackupManifest, folder: URL) -> BackupInfo {
        BackupInfo(id: manifest.id, createdAt: manifest.createdAt, path: folder.path,
                   sizeBytes: manifest.files.reduce(0) { $0 + $1.size }, fileCount: manifest.files.count,
                   includesROMs: manifest.includesROMs, serverVersion: manifest.serverVersion)
    }

    /// Every regular file under `folder` except the manifest, with relative paths, sorted.
    static func hashFiles(in folder: URL) throws -> [BackupManifest.File] {
        let fm = FileManager.default
        let base = folder.standardizedFileURL.resolvingSymlinksInPath().path
        guard let enumerator = fm.enumerator(at: folder, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey]) else { return [] }
        var files: [BackupManifest.File] = []
        for case let url as URL in enumerator {
            guard try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else { continue }
            let full = url.standardizedFileURL.resolvingSymlinksInPath().path
            let relative = String(full.dropFirst(base.count + 1))
            guard relative != manifestName else { continue }
            let size = Int64(try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0)
            files.append(.init(path: relative, size: size, sha256: try sha256(of: url)))
        }
        return files.sorted { $0.path < $1.path }
    }

    static func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    static let idFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter
    }()

    static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }()

    static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}
