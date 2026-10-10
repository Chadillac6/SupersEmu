import CryptoKit
import Foundation

/// Supplies the API client for the signed-in server. Returns nil in local-only mode: nothing syncs and nothing breaks.
/// The sign-in/client track owns where the URL and token come from.
public protocol SaveSyncServerProvider: Sendable {
    func currentClient() async -> APIClient?
}

/// One (game, kind, slot) line of revisions, e.g. the auto state of a game.
public struct SaveLine: Hashable, Codable, Sendable {
    public var gameID: String
    public var kind: SaveKind
    public var slot: String

    public init(gameID: String, kind: SaveKind, slot: String = "") {
        self.gameID = gameID; self.kind = kind; self.slot = slot
    }

    public var key: String { "\(gameID)/\(kind.rawValue)/\(slot)" }
}

public struct SaveCore: Hashable, Codable, Sendable {
    public var id: String
    public var version: String
    public init(id: String, version: String) { self.id = id; self.version = version }
    public static let unknown = SaveCore(id: "unknown", version: "unknown")
}

/// A save file on this device that should match its server line.
public struct LocalSaveFile: Sendable {
    public var line: SaveLine
    public var url: URL
    /// The core that writes this file now. Nil when it isn't known yet (native SRAM before the core loads).
    public var core: SaveCore?
    /// States only load in the exact core build that wrote them. Native SRAM is portable.
    public var requiresMatchingCore: Bool

    public init(line: SaveLine, url: URL, core: SaveCore?, requiresMatchingCore: Bool) {
        self.line = line; self.url = url; self.core = core; self.requiresMatchingCore = requiresMatchingCore
    }

    public func canLoad(_ revision: SaveRevision) -> Bool {
        guard requiresMatchingCore else { return true }
        guard let core else { return false }
        return revision.coreID == core.id && revision.coreVersion == core.version
    }
}

/// "A newer save from <device> is available": never resolved silently.
public struct SaveConflict: Codable, Equatable, Sendable, Identifiable {
    public var line: SaveLine
    public var remote: SaveRevision
    public var id: String { line.key }
    public var deviceName: String { remote.deviceName ?? "another device" }
    public var message: String { "A newer save from \(deviceName) is available" }
}

public enum SaveConflictChoice: Sendable {
    /// Replace this device's copy with the newer save. This device's copy stays on the server as a branch.
    case useRemote
    /// Keep playing this device's copy; it becomes the newest revision. The other save stays in history.
    case keepLocal
}

public enum SavePullOutcome: Equatable, Sendable {
    case localOnly
    case upToDate
    case downloaded(SaveRevision)
    case conflict(SaveConflict)
    /// The newer revision needs a different core build. Nothing was loaded; this device's copy was kept.
    case incompatible(SaveRevision)
    case failed(String)
}

/// Sync statuses shown to the user (`docs/specs/save-and-resume.md`).
public enum SaveSyncStatus: Equatable, Sendable {
    case savedLocally, waitingToUpload, uploading, synced, conflict
    case failed(String)

    public var label: String {
        switch self {
        case .savedLocally: return "Saved on this device"
        case .waitingToUpload: return "Waiting to upload"
        case .uploading: return "Uploading"
        case .synced: return "Synced"
        case .conflict: return "Conflict"
        case .failed: return "Upload failed, retrying"
        }
    }
}

public struct SaveFlushReport: Equatable, Sendable {
    public var uploaded: Int
    public var remaining: Int
    /// Set when the server couldn't be reached; remaining uploads stay queued on disk.
    public var offlineError: String?
}

/// Client save sync: an on-disk upload queue plus pull-before-launch with branch-safe conflict handling.
///
/// Rules: the server only ever gains revisions; this device's copy is never replaced unless it is already on
/// the server (or queued to be uploaded as a branch) and the user chose the newer save.
public actor SaveSyncEngine {
    struct LineState: Codable {
        /// The server revision this device's file was last identical to.
        var baseRevisionID: String?
        var baseSHA256: String?
        var lastCore: SaveCore?
        var conflict: SaveRevision?
    }

    struct PendingUpload: Codable, Identifiable {
        var id: UUID
        var line: SaveLine
        var sha256: String
        var core: SaveCore
        var enqueuedAt: Date
        /// Detached uploads preserve a copy as a branch off `detachedParentID` and don't move the base.
        var detached: Bool = false
        var detachedParentID: String?
        var attempts = 0
        var lastError: String?
    }

    struct PersistedState: Codable {
        var lines: [String: LineState] = [:]
        var queue: [PendingUpload] = []
    }

    public nonisolated let directory: URL
    private var provider: any SaveSyncServerProvider
    private var state: PersistedState
    private var uploadingID: UUID?
    private var isFlushing = false
    private var flushAgain = false

    private var stateURL: URL { directory.appendingPathComponent("sync-state.json") }
    private var blobs: URL { directory.appendingPathComponent("pending", isDirectory: true) }

    public init(directory: URL, provider: any SaveSyncServerProvider) {
        self.directory = directory
        self.provider = provider
        try? FileManager.default.createDirectory(at: directory.appendingPathComponent("pending", isDirectory: true),
                                                 withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("sync-state.json")
        state = (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode(PersistedState.self, from: $0) } ?? PersistedState()
    }

    public func setProvider(_ provider: any SaveSyncServerProvider) { self.provider = provider }

    public var pendingCount: Int { state.queue.count }

    public func status(of line: SaveLine) -> SaveSyncStatus {
        let key = line.key
        if state.lines[key]?.conflict != nil { return .conflict }
        if let pending = state.queue.last(where: { $0.line.key == key }) {
            if pending.id == uploadingID { return .uploading }
            if let error = pending.lastError { return .failed(error) }
            return .waitingToUpload
        }
        return state.lines[key]?.baseRevisionID != nil ? .synced : .savedLocally
    }

    // MARK: Upload queue

    /// Queues the file's current bytes for upload. Returns false when there is nothing new to send
    /// (no server signed in, missing file, or identical to what the server already has / what is queued).
    @discardableResult
    public func enqueueUpload(_ file: LocalSaveFile) async -> Bool {
        guard await provider.currentClient() != nil else { return false }
        return enqueue(file, detachedFrom: nil)
    }

    @discardableResult
    private func enqueue(_ file: LocalSaveFile, detachedFrom parent: String??) -> Bool {
        guard let data = try? Data(contentsOf: file.url) else { return false }
        let sha = Self.sha256(data)
        let key = file.line.key
        var line = state.lines[key] ?? LineState()
        if let core = file.core { line.lastCore = core }
        state.lines[key] = line
        let attached = state.queue.lastIndex { $0.line.key == key && !$0.detached }
        if parent == nil {
            if let attached, state.queue[attached].sha256 == sha { return false }
            if attached == nil, line.baseSHA256 == sha { return false }
        }
        let item = PendingUpload(id: UUID(), line: file.line, sha256: sha, core: file.core ?? line.lastCore ?? .unknown,
                                 enqueuedAt: Date(), detached: parent != nil, detachedParentID: parent ?? nil)
        do {
            try data.write(to: blobURL(item.id), options: .atomic)
        } catch {
            return false
        }
        // Only the newest attached copy of a line needs uploading; older queued copies are superseded.
        if parent == nil, let attached, state.queue[attached].id != uploadingID {
            try? FileManager.default.removeItem(at: blobURL(state.queue[attached].id))
            state.queue.remove(at: attached)
        }
        state.queue.append(item)
        persist()
        return true
    }

    /// Uploads queued saves in order. Transport errors stop the flush (offline) and keep everything queued.
    @discardableResult
    public func flush() async -> SaveFlushReport {
        if isFlushing {
            flushAgain = true
            return SaveFlushReport(uploaded: 0, remaining: state.queue.count, offlineError: nil)
        }
        isFlushing = true
        defer { isFlushing = false }
        var uploaded = 0
        var offline: String?
        repeat {
            flushAgain = false
            guard let client = await provider.currentClient() else { break }
            var index = 0
            while index < state.queue.count {
                let item = state.queue[index]
                switch await upload(item, client: client) {
                case .done:
                    uploaded += 1
                case .retryLater:
                    index += 1
                case .offline(let message):
                    offline = message
                    index = state.queue.count
                }
            }
        } while flushAgain && offline == nil
        return SaveFlushReport(uploaded: uploaded, remaining: state.queue.count, offlineError: offline)
    }

    private enum UploadResult { case done, retryLater(String), offline(String) }

    private func upload(_ item: PendingUpload, client: APIClient) async -> UploadResult {
        let key = item.line.key
        guard let data = try? Data(contentsOf: blobURL(item.id)), Self.sha256(data) == item.sha256 else {
            remove(item.id)
            return .retryLater("Queued copy missing")
        }
        let parent = item.detached ? item.detachedParentID : state.lines[key]?.baseRevisionID
        uploadingID = item.id
        defer { uploadingID = nil }
        do {
            let response = try await client.uploadSave(gameID: item.line.gameID, kind: item.line.kind, slot: item.line.slot,
                                                       parentID: parent, coreID: item.core.id, coreVersion: item.core.version, data: data)
            guard response.revision.sha256 == item.sha256 else {
                return markFailed(item.id, "Server stored different bytes; will retry")
            }
            var line = state.lines[key] ?? LineState()
            if !item.detached {
                line.baseRevisionID = response.revision.id
                line.baseSHA256 = item.sha256
            }
            if response.branched, line.conflict == nil, !item.detached {
                // We uploaded on top of a stale base: another device moved this line while we were offline.
                let others = (try? await client.saves(gameID: item.line.gameID).revisions) ?? []
                line.conflict = others.last { $0.kind == item.line.kind && $0.slot == item.line.slot && $0.id != response.revision.id }
            }
            state.lines[key] = line
            remove(item.id)
            return .done
        } catch let error as APIClientError {
            return markFailed(item.id, error.description)
        } catch {
            if let index = state.queue.firstIndex(where: { $0.id == item.id }) {
                state.queue[index].attempts += 1
                state.queue[index].lastError = error.localizedDescription
                persist()
            }
            return .offline(error.localizedDescription)
        }
    }

    private func markFailed(_ id: UUID, _ message: String) -> UploadResult {
        if let index = state.queue.firstIndex(where: { $0.id == id }) {
            state.queue[index].attempts += 1
            state.queue[index].lastError = message
            persist()
        }
        return .retryLater(message)
    }

    private func remove(_ id: UUID) {
        try? FileManager.default.removeItem(at: blobURL(id))
        state.queue.removeAll { $0.id == id }
        persist()
    }

    // MARK: Pull before launch

    /// Brings each local file up to date with the server before the game starts.
    /// Fast-forwards only when this device has nothing the server lacks; otherwise reports a conflict and
    /// queues this device's copy so it is kept on the server as a branch.
    public func prepare(_ files: [LocalSaveFile]) async -> [String: SavePullOutcome] {
        var outcomes: [String: SavePullOutcome] = [:]
        guard let client = await provider.currentClient() else {
            for file in files { outcomes[file.line.key] = .localOnly }
            return outcomes
        }
        var listings: [String: Result<[SaveRevision], Error>] = [:]
        for gameID in Set(files.map(\.line.gameID)) {
            do { listings[gameID] = .success(try await client.saves(gameID: gameID).revisions) } catch { listings[gameID] = .failure(error) }
        }
        for file in files {
            switch listings[file.line.gameID] {
            case .success(let revisions): outcomes[file.line.key] = await prepare(file, revisions: revisions, client: client)
            case .failure(let error): outcomes[file.line.key] = .failed(Self.describe(error))
            case nil: outcomes[file.line.key] = .failed("No listing")
            }
        }
        await flush()
        return outcomes
    }

    private func prepare(_ file: LocalSaveFile, revisions: [SaveRevision], client: APIClient) async -> SavePullOutcome {
        let key = file.line.key
        var line = state.lines[key] ?? LineState()
        if let core = file.core { line.lastCore = core }
        defer { state.lines[key] = line; persist() }

        let lineRevisions = revisions.filter { $0.kind == file.line.kind && $0.slot == file.line.slot }
        let localSHA = (try? Data(contentsOf: file.url)).map(Self.sha256)
        let hasPending = state.queue.contains { $0.line.key == key && !$0.detached }
        guard let head = lineRevisions.last(where: \.isHead) ?? lineRevisions.last else {
            // Nothing on the server yet: seed it with this device's copy.
            if localSHA != nil, !hasPending { state.lines[key] = line; enqueue(file, detachedFrom: nil) }
            return .upToDate
        }
        if head.id == line.baseRevisionID {
            if let conflict = line.conflict { return .conflict(SaveConflict(line: file.line, remote: conflict)) }
            if let localSHA, localSHA != line.baseSHA256, !hasPending { state.lines[key] = line; enqueue(file, detachedFrom: nil) }
            return .upToDate
        }
        if localSHA == head.sha256 {
            line.baseRevisionID = head.id
            line.baseSHA256 = head.sha256
            line.conflict = nil
            return .upToDate
        }

        let localIsOnServer = localSHA == nil || (localSHA == line.baseSHA256 && !hasPending)
        let headDescendsFromBase: Bool = {
            guard let base = line.baseRevisionID, lineRevisions.contains(where: { $0.id == base }) else { return true }
            var byID: [String: SaveRevision] = [:]
            for revision in lineRevisions { byID[revision.id] = revision }
            var cursor: SaveRevision? = head
            while let current = cursor {
                if current.id == base { return true }
                cursor = current.parentID.flatMap { byID[$0] }
            }
            return false
        }()

        if localIsOnServer && headDescendsFromBase {
            guard file.canLoad(head) else { return .incompatible(head) }
            do {
                try await download(head, to: file.url, client: client)
            } catch {
                return .failed(Self.describe(error))
            }
            line.baseRevisionID = head.id
            line.baseSHA256 = head.sha256
            line.conflict = nil
            return .downloaded(head)
        }

        // This device has progress the server lacks, or the server moved to another branch: ask, never overwrite.
        if localSHA != nil, !hasPending, localSHA != line.baseSHA256 {
            // Keep this device's copy on the server as a branch without moving the line's base.
            state.lines[key] = line
            enqueue(file, detachedFrom: .some(line.baseRevisionID))
        }
        guard file.canLoad(head) else { return .incompatible(head) }
        line.conflict = head
        return .conflict(SaveConflict(line: file.line, remote: head))
    }

    /// Applies the user's choice for a conflict reported by `prepare`.
    public func resolve(_ conflict: SaveConflict, choice: SaveConflictChoice, file: LocalSaveFile) async throws {
        let key = conflict.line.key
        switch choice {
        case .useRemote:
            guard file.canLoad(conflict.remote) else { throw SaveSyncError.incompatibleCore }
            guard let client = await provider.currentClient() else { throw SaveSyncError.noServer }
            // Preserve this device's copy as a branch before replacing it locally.
            if let localSHA = (try? Data(contentsOf: file.url)).map(Self.sha256), localSHA != state.lines[key]?.baseSHA256 || hasPending(key) {
                let base = state.lines[key]?.baseRevisionID
                dropAttachedPending(key)
                enqueue(file, detachedFrom: .some(base))
            }
            try await download(conflict.remote, to: file.url, client: client)
            var line = state.lines[key] ?? LineState()
            line.baseRevisionID = conflict.remote.id
            line.baseSHA256 = conflict.remote.sha256
            line.conflict = nil
            state.lines[key] = line
        case .keepLocal:
            var line = state.lines[key] ?? LineState()
            if hasPending(key) || (try? Data(contentsOf: file.url)).map(Self.sha256) != line.baseSHA256 {
                // The next upload continues from the other device's save, so this copy becomes the newest revision.
                line.baseRevisionID = conflict.remote.id
                line.baseSHA256 = nil
                state.lines[key] = line
                if !hasPending(key) { enqueue(file, detachedFrom: nil) }
                line = state.lines[key] ?? line
            }
            line.conflict = nil
            state.lines[key] = line
        }
        persist()
        await flush()
    }

    public func conflict(for line: SaveLine) -> SaveConflict? {
        state.lines[line.key]?.conflict.map { SaveConflict(line: line, remote: $0) }
    }

    private func hasPending(_ key: String) -> Bool { state.queue.contains { $0.line.key == key && !$0.detached } }

    private func dropAttachedPending(_ key: String) {
        for item in state.queue where item.line.key == key && !item.detached && item.id != uploadingID { remove(item.id) }
    }

    private func download(_ revision: SaveRevision, to url: URL, client: APIClient) async throws {
        let data = try await client.saveData(gameID: revision.gameID, revisionID: revision.id)
        guard Self.sha256(data) == revision.sha256 else { throw SaveSyncError.hashMismatch }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }

    // MARK: Helpers

    private func blobURL(_ id: UUID) -> URL { blobs.appendingPathComponent(id.uuidString) }

    private func persist() {
        guard let data = try? JSONEncoder().encode(state) else { return }
        try? data.write(to: stateURL, options: .atomic)
    }

    static func describe(_ error: Error) -> String {
        (error as? APIClientError)?.description ?? error.localizedDescription
    }

    public static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

public enum SaveSyncError: Error, Equatable, CustomStringConvertible {
    case noServer, hashMismatch, incompatibleCore
    public var description: String {
        switch self {
        case .noServer: return "Not connected to a SupersEmu Server"
        case .hashMismatch: return "Downloaded save failed its integrity check"
        case .incompatibleCore: return "That save needs a different core version"
        }
    }
}
