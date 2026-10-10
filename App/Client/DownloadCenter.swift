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

    /// Systems this build has a core for (GameSession is Snes9x-only today); others can download but not launch.
    static let launchableSystems: Set<SystemID> = [.snes]

    let cache: GameCache
    private(set) var states: [String: State] = [:]
    private(set) var downloaded: [String: CachedGame] = [:]
    @ObservationIgnored private var tasks: [String: Task<Void, Never>] = [:]

    init(cache: GameCache = GameCache(root: AppPaths.cache)) {
        self.cache = cache
        reload()
    }

    func reload() {
        downloaded = Dictionary(uniqueKeysWithValues: cache.cachedGames().map { ($0.detail.game.id, $0) })
    }

    func isDownloaded(_ gameID: String) -> Bool { downloaded[gameID] != nil }

    /// Ready-to-play `Game` for a downloaded server game, compatible with GameSession/PlayerView.
    func playableGame(_ gameID: String) -> Game? {
        guard let cached = downloaded[gameID], Self.launchableSystems.contains(cached.detail.game.system),
              let url = cache.launchFileURL(for: cached) else { return nil }
        let game = cached.detail.game
        return Game(id: game.id, title: game.title, fileURL: url, console: game.system.displayName,
                    hasResumePoint: FileManager.default.fileExists(atPath: AppPaths.autoState(for: game.id).path))
    }

    func start(_ gameID: String, session: ServerSession) {
        guard tasks[gameID] == nil, !isDownloaded(gameID) else { return }
        guard let downloader = session.downloader(cache: cache) else {
            states[gameID] = .failed("Connect to your server to download")
            return
        }
        let total = session.games.first { $0.id == gameID }?.totalSize ?? 0
        states[gameID] = .downloading(.init(receivedBytes: cache.bytesOnDisk(for: gameID), totalBytes: total))
        tasks[gameID] = Task { [weak self] in
            do {
                let cached = try await downloader.download(gameID: gameID) { progress in
                    Task { @MainActor [weak self] in self?.report(progress, for: gameID) }
                }
                self?.finish(gameID, cached: cached)
            } catch is CancellationError {
                self?.finish(gameID, error: nil)
            } catch let error as URLError where error.code == .cancelled {
                self?.finish(gameID, error: nil)
            } catch {
                self?.finish(gameID, error: error)
            }
        }
    }

    func cancel(_ gameID: String) {
        tasks[gameID]?.cancel()
    }

    func remove(_ gameID: String) {
        cancel(gameID)
        try? cache.remove(gameID)
        states[gameID] = nil
        reload()
    }

    /// Downloads belong to the account that made them; called when this device disconnects.
    func removeAll() {
        for task in tasks.values { task.cancel() }
        tasks = [:]
        states = [:]
        for id in downloaded.keys { try? cache.remove(id) }
        if let leftovers = try? FileManager.default.contentsOfDirectory(at: cache.root, includingPropertiesForKeys: nil) {
            for url in leftovers { try? FileManager.default.removeItem(at: url) }
        }
        reload()
    }

    private func report(_ progress: DownloadProgress, for gameID: String) {
        guard tasks[gameID] != nil else { return }
        if case .downloading(let current) = states[gameID],
           progress.receivedBytes < progress.totalBytes, progress.fraction - current.fraction < 0.002 { return }
        states[gameID] = .downloading(progress)
    }

    private func finish(_ gameID: String, cached: CachedGame) {
        tasks[gameID] = nil
        states[gameID] = nil
        downloaded[gameID] = cached
    }

    private func finish(_ gameID: String, error: Error?) {
        tasks[gameID] = nil
        if let error {
            states[gameID] = .failed((error as? DownloadError)?.description ?? error.localizedDescription)
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
