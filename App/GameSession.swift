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
    @ObservationIgnored private var framesSinceAutosave = 0

    private static let autosaveIntervalSeconds = 30.0

    init(game: Game) {
        self.game = game
        hasManualState = FileManager.default.fileExists(atPath: AppPaths.manualState(for: game.id).path)
    }

    func start() {
        guard host == nil else { return }
        do {
            let host = try SELibretroHost(
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
                    status = "Couldn't resume; started fresh"
                }
            }
            host.audioEnabled = true
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
    }

    private func tick() {
        guard let host else { return }
        host.buttons = input.currentButtons()
        host.runFrame()
        if let image = host.copyFrameImage() {
            displayLayer?.contents = image
        }
        framesSinceAutosave += 1
        if Double(framesSinceAutosave) >= host.framesPerSecond * Self.autosaveIntervalSeconds {
            autosave()
        }
    }

    func autosave() {
        framesSinceAutosave = 0
        guard let host else { return }
        do {
            try host.saveState(to: AppPaths.autoState(for: game.id))
            host.flushSaveRAM()
            status = "Auto-saved on this device"
        } catch {
            status = "Auto-save failed"
        }
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
