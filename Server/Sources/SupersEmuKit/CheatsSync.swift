import Foundation

public struct CheatFile: Codable, Sendable, Equatable {
    public var version = 1
    public var gameID: String
    public var cheats: [CheatRecord]
}

public enum CheatSyncStatus: Equatable, Sendable {
    /// Not paired with a server: cheats live on this device only.
    case deviceOnly
    /// The server predates cheat sync (404 on /v1/cheats): cheats stay on this device.
    case serverTooOld
    case offline(pending: Int)
    case failed(message: String, pending: Int)
    case synced(at: Date)
}

/// Cheats on this device, one JSON file per game (ROM SHA-256), plus a queue of edits the server hasn't seen.
/// Launching a game only ever reads these files; syncing never blocks play.
public actor CheatSyncEngine {
    struct State: Codable {
        var lastRevision = 0
        /// Cheat id -> game id for records with local edits not yet uploaded.
        var pending: [String: String] = [:]
    }

    public let directory: URL
    private let provider: (any SaveSyncServerProvider)?
    private var state: State
    private var syncing = false
    private var files: [String: CheatFile] = [:]
    public private(set) var status: CheatSyncStatus = .deviceOnly

    public init(directory: URL, provider: (any SaveSyncServerProvider)?) {
        self.directory = directory
        self.provider = provider
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let stateURL = directory.appendingPathComponent("sync-state.json")
        state = (try? Data(contentsOf: stateURL)).flatMap { try? SupersEmuJSON.decoder().decode(State.self, from: $0) } ?? State()
    }

    public static func isValidGameID(_ id: String) -> Bool {
        !id.isEmpty && id.count <= 128 && id.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }
    }

    // MARK: Local

    /// Visible cheats for a game, oldest first.
    public func cheats(for gameID: String) -> [CheatRecord] {
        file(for: gameID).cheats.filter { !$0.deleted }.sorted { ($0.createdAt, $0.id.uuidString) < ($1.createdAt, $1.id.uuidString) }
    }

    public var pendingCount: Int { state.pending.count }

    /// Inserts or replaces records (already edited by the caller via `setLabel` etc.) and queues them for upload.
    public func save(_ records: [CheatRecord]) throws {
        for (gameID, group) in Dictionary(grouping: records, by: \.gameID) {
            guard Self.isValidGameID(gameID) else { throw CocoaError(.fileWriteInvalidFileName) }
            var file = file(for: gameID)
            for record in group {
                if let index = file.cheats.firstIndex(where: { $0.id == record.id }) { file.cheats[index] = record }
                else { file.cheats.append(record) }
                state.pending[record.id.uuidString] = gameID
            }
            try write(file)
        }
        persistState()
    }

    public func delete(_ id: UUID, gameID: String) throws {
        guard var record = file(for: gameID).cheats.first(where: { $0.id == id }) else { return }
        record.markDeleted()
        try save([record])
    }

    // MARK: Sync

    @discardableResult
    public func sync() async -> CheatSyncStatus {
        guard !syncing else { return status }
        syncing = true
        defer { syncing = false }
        guard let provider, let client = await provider.currentClient() else { status = .deviceOnly; return status }
        guard await provider.isReachable() else { status = .offline(pending: state.pending.count); return status }
        do {
            try await pull(client)
            try await push(client)
            status = .synced(at: Date())
        } catch APIClientError.http(status: 404, _) where status == .serverTooOld || state.lastRevision == 0 {
            status = .serverTooOld
        } catch let error as URLError {
            status = .offline(pending: state.pending.count)
            _ = error
        } catch {
            status = .failed(message: String(describing: error), pending: state.pending.count)
        }
        return status
    }

    /// Forgets sync bookkeeping. On sign-out (`requeueLocal: false`) queued edits are dropped so the next account
    /// never receives them; cheats already on this device stay usable. After a server restore every local cheat is
    /// queued again so the server gets back what it lost.
    public func resetSync(requeueLocal: Bool = false) {
        state.lastRevision = 0
        state.pending = [:]
        if requeueLocal {
            for file in allFiles() { for cheat in file.cheats { state.pending[cheat.id.uuidString] = file.gameID } }
        }
        persistState()
        status = .deviceOnly
    }

    private func pull(_ client: APIClient) async throws {
        var response: CheatListResponse
        do {
            response = try await client.cheatChanges(since: state.lastRevision)
        } catch APIClientError.http(status: 404, let message) {
            // A current server answers 404 only for a missing route; treat it as an older server.
            status = .serverTooOld
            throw APIClientError.http(status: 404, message: message)
        }
        if response.revision < state.lastRevision {
            // The server was restored from an older backup: refetch everything and re-upload what it lacks.
            response = try await client.cheatChanges(since: 0)
            resetSync(requeueLocal: true)
        }
        try apply(response.cheats)
        state.lastRevision = max(state.lastRevision, response.revision)
        persistState()
    }

    private func push(_ client: APIClient) async throws {
        for (id, gameID) in state.pending.sorted(by: { $0.key < $1.key }) {
            guard let local = file(for: gameID).cheats.first(where: { $0.id.uuidString == id }) else {
                state.pending[id] = nil
                continue
            }
            let saved: CheatRecord
            do {
                saved = try await client.putCheat(local)
            } catch APIClientError.http(let code, _) where code == 400 || code == 403 || code == 404 || code == 409 {
                // The server will never take this one (bad data, or the game was removed): keep it local only.
                state.pending[id] = nil
                persistState()
                continue
            }
            let current = file(for: gameID).cheats.first(where: { $0.id.uuidString == id })
            try apply([saved])
            if current == local { state.pending[id] = nil }
            persistState()
        }
    }

    private func apply(_ remote: [CheatRecord]) throws {
        for (gameID, group) in Dictionary(grouping: remote, by: \.gameID) where Self.isValidGameID(gameID) {
            var file = file(for: gameID)
            for record in group {
                if let index = file.cheats.firstIndex(where: { $0.id == record.id }) {
                    var merged = CheatMerge.merge(file.cheats[index], record)
                    merged.revision = record.revision
                    file.cheats[index] = merged
                } else {
                    file.cheats.append(record)
                }
            }
            try write(file)
        }
    }

    // MARK: Files

    private func url(for gameID: String) -> URL { directory.appendingPathComponent("\(gameID).json") }

    private func file(for gameID: String) -> CheatFile {
        if let cached = files[gameID] { return cached }
        let loaded = (try? Data(contentsOf: url(for: gameID)))
            .flatMap { try? SupersEmuJSON.decoder().decode(CheatFile.self, from: $0) }
            .flatMap { $0.gameID == gameID ? $0 : nil } ?? CheatFile(gameID: gameID, cheats: [])
        files[gameID] = loaded
        return loaded
    }

    private func allFiles() -> [CheatFile] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        return names.filter { $0.hasSuffix(".json") && $0 != "sync-state.json" }
            .map { String($0.dropLast(5)) }.filter(Self.isValidGameID).map(file(for:))
    }

    private func write(_ file: CheatFile) throws {
        let data = try SupersEmuJSON.encoder().encode(file)
        try data.write(to: url(for: file.gameID), options: .atomic)
        files[file.gameID] = file
    }

    private func persistState() {
        guard let data = try? SupersEmuJSON.encoder().encode(state) else { return }
        try? data.write(to: directory.appendingPathComponent("sync-state.json"), options: .atomic)
    }
}
