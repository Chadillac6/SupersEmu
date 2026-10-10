import Foundation
import Observation
import QuartzCore
import SupersEmuKit

@MainActor
@Observable
final class GameSession {
    let game: Game
    private(set) var status = ""
    private(set) var errorMessage: String?
    private(set) var hasManualState: Bool
    /// A newer save from another device; the game waits until the player picks which copy to continue.
    private(set) var pendingConflict: SaveConflict?
    private(set) var isSyncing = false

    @ObservationIgnored let input = GameInput()
    @ObservationIgnored weak var displayLayer: CALayer?
    @ObservationIgnored private var host: SELibretroHost?
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var lastAutosave = ContinuousClock.now
    @ObservationIgnored private let sync: SaveSync
    @ObservationIgnored private var conflictChoice: CheckedContinuation<SaveConflictChoice?, Never>?
    @ObservationIgnored private var hasStarted = false
    @ObservationIgnored private var startTask: Task<Void, Never>?
    @ObservationIgnored private var core: SaveCore?

    private static let autosaveInterval = Duration.seconds(30)

    init(game: Game, sync: SaveSync? = nil) {
        self.game = game
        self.sync = sync ?? .shared
        hasManualState = FileManager.default.fileExists(atPath: AppPaths.manualState(for: game.id).path)
    }

    func start() {
        guard host == nil, startTask == nil else { return }
        startTask = Task { await launch() }
    }

    /// Pulls newer saves from the server (if signed in) before the core reads them, then starts the game.
    private func launch() async {
        isSyncing = true
        status = "Checking for newer saves…"
        // Battery saves are read when the core loads the game, so they sync before the host exists.
        await pull([SaveSync.nativeFile(for: game.id)])
        guard !Task.isCancelled else { return }
        let host: SELibretroHost
        do {
            host = try SELibretroHost(
                coreID: CoreRegistry.coreID(for: game.fileURL, console: game.console),
                romURL: game.fileURL,
                saveRAMURL: AppPaths.saveRAM(for: game.id),
                systemDirectory: AppPaths.system)
        } catch {
            isSyncing = false
            errorMessage = error.localizedDescription
            startTask = nil
            return
        }
        self.host = host
        let core = SaveCore(id: host.coreID, version: host.coreVersion)
        self.core = core
        let pulled = await pull([SaveSync.autoFile(for: game.id, core: core), SaveSync.manualFile(for: game.id, core: core)])
        isSyncing = false
        guard !Task.isCancelled, self.host === host else { return }
        hasManualState = FileManager.default.fileExists(atPath: AppPaths.manualState(for: game.id).path)
        status = pulled ?? ""
        let autoState = AppPaths.autoState(for: game.id)
        if FileManager.default.fileExists(atPath: autoState.path) {
            do {
                try host.loadState(from: autoState)
                status = pulled ?? "Resumed where you left off"
            } catch {
                preserveIncompatibleState(at: autoState)
                status = "Couldn't resume; old save kept, started fresh"
            }
        }
        host.audioEnabled = true
        lastAutosave = .now
        hasStarted = true
        resume()
    }

    /// Fetches the server's heads for `files`, downloads newer compatible revisions and asks about conflicts.
    /// Returns a status line when a save came from another device.
    @discardableResult
    private func pull(_ files: [LocalSaveFile]) async -> String? {
        let outcomes = await sync.engine.prepare(files)
        var message: String?
        for file in files {
            switch outcomes[file.line.key] {
            case .downloaded(let revision) where file.line.kind == .auto:
                message = "Resumed from \(revision.deviceName ?? "another device")"
            case .incompatible(let revision) where file.line.kind == .auto:
                // Same rule as local incompatible states: never load it, keep it, and say so.
                message = "Newer save from \(revision.deviceName ?? "another device") needs \(revision.coreID) \(revision.coreVersion); kept on server"
            case .conflict(let conflict):
                let answer: SaveConflictChoice? = await withCheckedContinuation { continuation in
                    conflictChoice = continuation
                    pendingConflict = conflict
                }
                pendingConflict = nil
                // Leaving the game without answering keeps both copies untouched; we ask again next launch.
                guard let choice = answer else { return message }
                do {
                    try await sync.engine.resolve(conflict, choice: choice, file: file)
                    if choice == .useRemote, file.line.kind == .auto { message = "Resumed from \(conflict.deviceName)" }
                } catch {
                    message = "Kept this device's save (\(error.localizedDescription))"
                }
            default:
                break
            }
        }
        return message
    }

    /// Answers the "A newer save from <device> is available" prompt.
    func resolveConflict(_ choice: SaveConflictChoice) {
        conflictChoice?.resume(returning: choice)
        conflictChoice = nil
    }

    private func abandonConflict() {
        conflictChoice?.resume(returning: nil)
        conflictChoice = nil
    }

    func resume() {
        // Never run frames while saves are still syncing or a conflict is waiting for an answer.
        guard let host, hasStarted, timer == nil else { return }
        let timer = Timer(timeInterval: 1.0 / max(host.framesPerSecond, 1), repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func pause() {
        timer?.invalidate()
        timer = nil
        #if os(macOS)
        input.releaseAll()
        #endif
    }

    private func tick() {
        guard let host else { return }
        host.buttons = input.currentButtons()
        host.runFrame()
        if let image = host.copyFrameImage() {
            displayLayer?.contents = image
        }
        if ContinuousClock.now - lastAutosave >= Self.autosaveInterval {
            autosave()
        }
    }

    func autosave() {
        lastAutosave = .now
        // Before the game has started (still syncing) there's nothing new to save, and a fresh state would replace the resume point.
        guard let host, hasStarted else { return }
        host.flushSaveRAM()
        do {
            try host.saveState(to: AppPaths.autoState(for: game.id))
            status = "Auto-saved on this device"
        } catch {
            status = "Auto-save failed"
            // The battery save was still flushed; sync it on its own.
            upload([SaveSync.nativeFile(for: game.id)], saved: "Auto-save failed")
            return
        }
        upload([SaveSync.nativeFile(for: game.id)] + (core.map { [SaveSync.autoFile(for: game.id, core: $0)] } ?? []),
               saved: "Auto-saved")
    }

    /// Uploads files right after they're written locally; offline copies stay queued on disk and retry later.
    private func upload(_ files: [LocalSaveFile], saved: String) {
        let sync = sync
        Task { [weak self] in
            guard let result = await sync.uploadAfterWrite(files) else { return }
            let text: String
            switch result {
            case .synced: text = "\(saved) · synced"
            case .conflict: text = "\(saved) · newer save on another device"
            case .failed, .waitingToUpload, .uploading: text = "\(saved) · will sync later"
            case .savedLocally: return
            }
            if let self, self.status.hasPrefix(saved) { self.status = text }
        }
    }

    /// Moves an auto state the current core can't load aside so later autosaves never overwrite it.
    private func preserveIncompatibleState(at url: URL) {
        let stamp = Int(Date().timeIntervalSince1970)
        let destination = url.deletingLastPathComponent().appendingPathComponent("auto.incompatible-\(stamp).state")
        try? FileManager.default.moveItem(at: url, to: destination)
    }

    func saveManualState() {
        guard let host, hasStarted else { return }
        do {
            try host.saveState(to: AppPaths.manualState(for: game.id))
            hasManualState = true
            status = "Saved to slot 1"
            host.flushSaveRAM()
            upload([SaveSync.nativeFile(for: game.id)] + (core.map { [SaveSync.manualFile(for: game.id, core: $0)] } ?? []),
                   saved: "Saved to slot 1")
        } catch {
            status = "Save failed: \(error.localizedDescription)"
        }
    }

    func loadManualState() {
        guard let host, hasStarted else { return }
        do {
            try host.loadState(from: AppPaths.manualState(for: game.id))
            status = "Loaded slot 1"
        } catch {
            status = "Load failed: \(error.localizedDescription)"
        }
    }

    func stop() {
        startTask?.cancel()
        startTask = nil
        abandonConflict()
        pause()
        autosave()
        hasStarted = false
        isSyncing = false
        host?.shutdown()
        host = nil
    }
}
