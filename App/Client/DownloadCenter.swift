import Foundation
import Observation
import SupersEmuKit

/// Per-game downloads into Application Support/SupersEmu/Cache/<gameID>/ with live progress.
@MainActor
@Observable
final class DownloadCenter {
    enum State: Equatable {
        case downloading(DownloadProgress)
        case failed(String)
    }

    /// Systems with a linked core; games for other systems can download but not launch.
    static func isLaunchable(_ system: SystemID) -> Bool { CoreRegistry.core(forSystem: system.rawValue) != nil }

    let cache: GameCache
    private(set) var states: [String: State] = [:]
    private(set) var downloaded: [String: CachedGame] = [:]
    @ObservationIgnored private var tasks: [String: Task<Void, Never>] = [:]
    /// Canceled downloads that may still be writing; a replacement waits for these before touching the folder.
    @ObservationIgnored private var stopping: [String: Task<Void, Never>] = [:]
    /// Bumped on start/remove so a task that finishes after Remove can't resurrect the game.
    @ObservationIgnored private var generations: [String: Int] = [:]
    @ObservationIgnored private var reloadToken = 0
    /// Changes made while a background reload is verifying, applied on top of its result.
    @ObservationIgnored private var editsDuringReload: [String: CachedGame?] = [:]

    init(cache: GameCache = GameCache(root: AppPaths.cache)) {
        self.cache = cache
        reload()
    }

    /// Re-verifies the cache off the main actor (hashing large disc images can take a while).
    func reload() {
        reloadToken += 1
        let token = reloadToken
        editsDuringReload = [:]
        let cache = cache
        Task { [weak self] in
            let games = await Task.detached(priority: .userInitiated) { cache.cachedGames() }.value
            guard let self, token == self.reloadToken else { return }
            var fresh = Dictionary(games.map { ($0.detail.game.id, $0) }, uniquingKeysWith: { first, _ in first })
            for (id, edit) in self.editsDuringReload { fresh[id] = edit }
            // An active download owns its game until finish publishes (or re-verifies) it.
            for id in self.tasks.keys { fresh[id] = nil }
            self.downloaded = fresh
        }
    }

    private func setDownloaded(_ gameID: String, _ game: CachedGame?) {
        downloaded[gameID] = game
        editsDuringReload[gameID] = .some(game)
    }

    func isDownloaded(_ gameID: String) -> Bool { downloaded[gameID] != nil }

    /// Ready-to-play `Game` for a downloaded server game, compatible with GameSession/PlayerView.
    func playableGame(_ gameID: String) -> Game? {
        guard let cached = downloaded[gameID], Self.isLaunchable(cached.detail.game.system),
              let url = cache.launchFileURL(for: cached) else { return nil }
        let game = cached.detail.game
        return Game(id: game.id, title: game.title, fileURL: url, console: game.system.displayName,
                    hasResumePoint: FileManager.default.fileExists(atPath: AppPaths.autoState(for: game.id).path))
    }

    static func describe(_ error: Error) -> String {
        guard let error = error as? URLError else { return error.localizedDescription }
        switch error.code {
        case .notConnectedToInternet, .networkConnectionLost, .timedOut, .cannotConnectToHost, .cannotFindHost, .dnsLookupFailed:
            return "Lost the connection to your server. Try again when it's back."
        default:
            return error.localizedDescription
        }
    }

    func start(_ gameID: String, session: ServerSession) {
        guard tasks[gameID] == nil, !isDownloaded(gameID) else { return }
        guard session.isReachable, let downloader = session.downloader(cache: cache) else {
            states[gameID] = .failed("Unavailable offline. Connect to \(session.serverName) to download it.")
            return
        }
        // A pending startup scan must not publish the old copy while this replaces it.
        setDownloaded(gameID, nil)
        let total = session.games.first { $0.id == gameID }?.totalSize ?? 0
        states[gameID] = .downloading(.init(receivedBytes: cache.bytesOnDisk(for: gameID), totalBytes: total))
        let generation = (generations[gameID] ?? 0) + 1
        generations[gameID] = generation
        let previous = stopping[gameID]
        tasks[gameID] = Task { [weak self] in
            await previous?.value
            do {
                let cached = try await downloader.download(gameID: gameID) { progress in
                    Task { @MainActor [weak self] in self?.report(progress, for: gameID, generation: generation) }
                }
                self?.finish(gameID, cached: cached, generation: generation)
            } catch is CancellationError {
                self?.finish(gameID, error: nil, generation: generation)
            } catch let error as URLError where error.code == .cancelled {
                self?.finish(gameID, error: nil, generation: generation)
            } catch {
                self?.finish(gameID, error: error, generation: generation)
            }
        }
    }

    func cancel(_ gameID: String) {
        tasks[gameID]?.cancel()
    }

    func remove(_ gameID: String) {
        if let task = tasks.removeValue(forKey: gameID) { retire(task, for: gameID) }
        generations[gameID, default: 0] += 1
        do {
            try cache.remove(gameID)
        } catch {
            states[gameID] = .failed("Couldn't remove the download: \(error.localizedDescription)")
            return
        }
        states[gameID] = nil
        setDownloaded(gameID, nil)
    }

    /// Downloads belong to the account that made them; called when this device disconnects.
    func removeAll() {
        // Also invalidates pending restoreIfIntact work for games with no active task.
        for id in Set(generations.keys).union(downloaded.keys) { generations[id, default: 0] += 1 }
        for (id, task) in tasks {
            generations[id, default: 0] += 1
            retire(task, for: id)
        }
        tasks = [:]
        states = [:]
        for id in downloaded.keys { try? cache.remove(id) }
        if let leftovers = try? FileManager.default.contentsOfDirectory(at: cache.root, includingPropertiesForKeys: nil) {
            for url in leftovers { try? FileManager.default.removeItem(at: url) }
        }
        reloadToken += 1
        editsDuringReload = [:]
        downloaded = [:]
    }

    private func retire(_ task: Task<Void, Never>, for gameID: String) {
        task.cancel()
        let waitFor = stopping[gameID]
        let done = Task<Void, Never> {
            await waitFor?.value
            await task.value
        }
        stopping[gameID] = done
        Task { [weak self] in
            await done.value
            if self?.stopping[gameID] == done { self?.stopping[gameID] = nil }
        }
    }

    private func report(_ progress: DownloadProgress, for gameID: String, generation: Int) {
        guard generations[gameID] == generation, tasks[gameID] != nil else { return }
        if case .downloading(let current) = states[gameID],
           progress.receivedBytes < progress.totalBytes, progress.fraction - current.fraction < 0.002 { return }
        states[gameID] = .downloading(progress)
    }

    private func finish(_ gameID: String, cached: CachedGame, generation: Int) {
        guard generations[gameID] == generation else {
            // Removed while finishing: drop what the stale task wrote unless a new download owns the folder.
            if tasks[gameID] == nil { try? cache.remove(gameID) }
            return
        }
        tasks[gameID] = nil
        states[gameID] = nil
        setDownloaded(gameID, cached)
    }

    /// A canceled or failed replacement may have left the previous copy untouched; show it again if it still verifies.
    private func restoreIfIntact(_ gameID: String, generation: Int) {
        let cache = cache
        Task { [weak self] in
            let game = await Task.detached(priority: .userInitiated) { cache.cachedGame(gameID) }.value
            guard let self, let game, self.generations[gameID] == generation, self.tasks[gameID] == nil else { return }
            self.states[gameID] = nil
            self.setDownloaded(gameID, game)
        }
    }

    private func finish(_ gameID: String, error: Error?, generation: Int) {
        guard generations[gameID] == generation else {
            if tasks[gameID] == nil { try? cache.remove(gameID) }
            return
        }
        tasks[gameID] = nil
        restoreIfIntact(gameID, generation: generation)
        if let error {
            states[gameID] = .failed((error as? DownloadError)?.description ?? Self.describe(error))
        } else {
            states[gameID] = nil
        }
    }
}

extension SystemID {
    var displayName: String {
        switch self {
        case .snes: return "Super Nintendo"
        case .gb: return "Game Boy"
        case .gbc: return "Game Boy Color"
        case .gba: return "Game Boy Advance"
        case .genesis: return "Sega Genesis"
        case .segacd: return "Sega CD"
        case .sega32x: return "Sega 32X"
        case .psx: return "PlayStation"
        case .n64: return "Nintendo 64"
        }
    }
}
