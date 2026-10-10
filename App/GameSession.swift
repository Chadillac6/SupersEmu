import Foundation
import Observation
import QuartzCore

@MainActor
@Observable
final class GameSession {
    let game: Game
    private(set) var status = ""
    private(set) var errorMessage: String?
    private(set) var hasManualState: Bool

    @ObservationIgnored let input = GameInput()
    @ObservationIgnored weak var displayLayer: CALayer?
    @ObservationIgnored private var host: SELibretroHost?
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var lastAutosave = ContinuousClock.now

    private static let autosaveInterval = Duration.seconds(30)

    init(game: Game) {
        self.game = game
        hasManualState = FileManager.default.fileExists(atPath: AppPaths.manualState(for: game.id).path)
    }

    func start() {
        guard host == nil else { return }
        do {
            let host = try SELibretroHost(
                coreID: CoreRegistry.coreID(for: game.fileURL, console: game.console),
                romURL: game.fileURL,
                saveRAMURL: AppPaths.saveRAM(for: game.id),
                systemDirectory: AppPaths.system)
            self.host = host
            let autoState = AppPaths.autoState(for: game.id)
            if FileManager.default.fileExists(atPath: autoState.path) {
                do {
                    try host.loadState(from: autoState)
                    status = "Resumed where you left off"
                } catch {
                    preserveIncompatibleState(at: autoState)
                    status = "Couldn't resume; old save kept, started fresh"
                }
            }
            host.audioEnabled = true
            lastAutosave = .now
            resume()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func resume() {
        guard let host, timer == nil else { return }
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
        guard let host else { return }
        host.flushSaveRAM()
        do {
            try host.saveState(to: AppPaths.autoState(for: game.id))
            status = "Auto-saved on this device"
        } catch {
            status = "Auto-save failed"
        }
    }

    /// Moves an auto state the current core can't load aside so later autosaves never overwrite it.
    private func preserveIncompatibleState(at url: URL) {
        let stamp = Int(Date().timeIntervalSince1970)
        let destination = url.deletingLastPathComponent().appendingPathComponent("auto.incompatible-\(stamp).state")
        try? FileManager.default.moveItem(at: url, to: destination)
    }

    func saveManualState() {
        guard let host else { return }
        do {
            try host.saveState(to: AppPaths.manualState(for: game.id))
            hasManualState = true
            status = "Saved to slot 1"
        } catch {
            status = "Save failed: \(error.localizedDescription)"
        }
    }

    func loadManualState() {
        guard let host else { return }
        do {
            try host.loadState(from: AppPaths.manualState(for: game.id))
            status = "Loaded slot 1"
        } catch {
            status = "Load failed: \(error.localizedDescription)"
        }
    }

    func stop() {
        pause()
        autosave()
        host?.shutdown()
        host = nil
    }
}
