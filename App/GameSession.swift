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
    /// Discs the core can swap between (from the game's .m3u); the player offers "Swap disc" when > 1.
    private(set) var diskCount = 0
    /// Zero-based index of the inserted disc.
    private(set) var currentDisk = 0
    /// The disc picker is open; the game stays paused until it closes.
    private(set) var isChoosingDisc = false
    /// Highlighted row in the disc picker (zero-based).
    var discSelection = 0
    /// The in-game menu (Select+Start held 1 s, long-press Home/Guide, or the Menu button) is open; the game is paused.
    private(set) var isMenuOpen = false
    var menuSelection = 0
    var isShowingControls = false
    /// Set when the player picks "Exit to Library" from the in-game menu.
    private(set) var wantsExit = false
    /// A player's controller went away mid-game; the game stays paused until they resume.
    private(set) var disconnectedController: String?
    private(set) var controllerReconnected = false

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
    @ObservationIgnored private var pickerTimer: Timer?
    @ObservationIgnored private var pickerButtons: SEJoypadButtons = []
    /// The chord opens the picker only after it has been released since it last fired.
    @ObservationIgnored private var chordArmed = true
    @ObservationIgnored private var hotkeyHeldSince: ContinuousClock.Instant?
    /// False after the menu opens until the hotkey is released, so a still-held hotkey doesn't reopen it.
    @ObservationIgnored private var hotkeyArmed = true
    @ObservationIgnored private var overlayTimer: Timer?
    @ObservationIgnored private var overlayHeld: Set<PadInput> = []
    @ObservationIgnored private var controllerObservers: [NSObjectProtocol] = []

    private static let autosaveInterval = Duration.seconds(30)

    init(game: Game, sync: SaveSync? = nil) {
        self.game = game
        self.sync = sync ?? .shared
        hasManualState = FileManager.default.fileExists(atPath: AppPaths.manualState(for: game.id).path)
        input.layout = ConsoleLayout.forSystem(Self.system(for: game))
        input.gameID = game.id
        #if DEBUG
        // UI-only stub for overlay screenshots of consoles without a test ROM: SUPERSEMU_DEBUG_LAYOUT=n64.
        if let system = ProcessInfo.processInfo.environment["SUPERSEMU_DEBUG_LAYOUT"] {
            input.layout = ConsoleLayout.forSystem(system)
        }
        #endif
    }

    /// `SystemID` raw value for the game ("snes", "n64", ...), which picks the controller layout.
    static func system(for game: Game) -> String {
        CoreRegistry.systemID(forConsole: game.console)
            ?? CoreRegistry.core(forExtension: game.fileURL.pathExtension)?.systems.first
            ?? "snes"
    }

    func start() {
        guard host == nil, startTask == nil else { return }
        observeControllers()
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
        diskCount = host.diskCount
        currentDisk = host.currentDisk
        #if DEBUG
        if diskCount < 2, let stub = Self.debugDiscCount { diskCount = stub }
        #endif
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
        guard let host, hasStarted, timer == nil, !isChoosingDisc, !isMenuOpen, disconnectedController == nil else { return }
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
        if menuHotkeyHeld() {
            clearHostInput()
            openMenu()
            return
        }
        let outputs = input.outputs()
        let buttons = SEJoypadButtons(rawValue: outputs[0].buttons)
        if buttons.isSuperset(of: Self.discPickerChord) {
            if diskCount > 1, chordArmed {
                chordArmed = false
                clearHostInput()
                openDiscPicker()
                return
            }
        } else {
            chordArmed = true
        }
        for (port, output) in outputs.enumerated() {
            host.setButtons(SEJoypadButtons(rawValue: output.buttons), port: port)
            host.setAnalog(.left, x: output.leftStick.x, y: output.leftStick.y, port: port)
            host.setAnalog(.right, x: output.rightStick.x, y: output.rightStick.y, port: port)
        }
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

    func discLabel(_ index: Int) -> String? { host?.label(forDisk: index) }

    private func clearHostInput() {
        guard let host else { return }
        for port in 0..<SEInputPortCount {
            host.setButtons([], port: port)
            host.setAnalog(.left, x: 0, y: 0, port: port)
            host.setAnalog(.right, x: 0, y: 0, port: port)
        }
    }

    // MARK: In-game menu

    enum MenuItem: String, CaseIterable, Identifiable {
        case resume = "Resume", save = "Save State", load = "Load State", swapDisc = "Swap Disc"
        case controls = "Controls", exit = "Exit to Library"
        var id: String { rawValue }
    }

    var menuItems: [MenuItem] {
        MenuItem.allCases.filter { item in
            switch item {
            case .swapDisc: diskCount > 1
            case .load: hasManualState
            default: true
            }
        }
    }

    private static let menuChordDuration = Duration.seconds(1)
    private static let homeLongPress = Duration.milliseconds(600)

    /// Select+Start held for 1 s, or Home/Guide held, on any controller or the keyboard (Tab+Return).
    private func menuHotkeyHeld() -> Bool {
        let sources = input.sourceStates().map(\.pressed)
        let chord = sources.contains { $0.isSuperset(of: [.select, .start]) }
        let home = sources.contains { $0.contains(.home) }
        guard chord || home else {
            hotkeyHeldSince = nil
            hotkeyArmed = true
            return false
        }
        guard hotkeyArmed else { return false }
        let since = hotkeyHeldSince ?? .now
        hotkeyHeldSince = since
        return ContinuousClock.now - since >= (chord ? Self.menuChordDuration : Self.homeLongPress)
    }

    func openMenu() {
        guard hasStarted, !isMenuOpen, !isChoosingDisc, pendingConflict == nil else { return }
        pause()
        hotkeyHeldSince = nil
        hotkeyArmed = false
        menuSelection = 0
        isMenuOpen = true
        startOverlayPolling()
    }

    func closeMenu() {
        guard isMenuOpen else { return }
        isMenuOpen = false
        isShowingControls = false
        if disconnectedController == nil { stopOverlayPolling() }
        resume()
    }

    func choose(_ item: MenuItem) {
        switch item {
        case .resume:
            closeMenu()
        case .save:
            saveManualState()
            closeMenu()
        case .load:
            loadManualState()
            closeMenu()
        case .swapDisc:
            isMenuOpen = false
            stopOverlayPolling()
            openDiscPicker()
        case .controls:
            isShowingControls = true
        case .exit:
            isMenuOpen = false
            stopOverlayPolling()
            wantsExit = true
        }
    }

    // MARK: Controller disconnects

    private func observeControllers() {
        guard controllerObservers.isEmpty else { return }
        let center = NotificationCenter.default
        controllerObservers.append(center.addObserver(forName: .gamepadDisconnected, object: nil, queue: .main) { [weak self] note in
            MainActor.assumeIsolated { self?.controllerDisconnected(note.object as? String ?? "Controller") }
        })
        controllerObservers.append(center.addObserver(forName: .gamepadConnected, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.disconnectedController != nil else { return }
                self.controllerReconnected = true
            }
        })
    }

    private func controllerDisconnected(_ name: String) {
        guard hasStarted, disconnectedController == nil else { return }
        pause()
        clearHostInput()
        disconnectedController = name
        controllerReconnected = false
        if !isMenuOpen, !isChoosingDisc { startOverlayPolling() }
    }

    /// Continues after a disconnect, with the reconnected pad, another pad, touch or the keyboard.
    func dismissDisconnect() {
        guard disconnectedController != nil else { return }
        disconnectedController = nil
        controllerReconnected = false
        if !isMenuOpen {
            stopOverlayPolling()
            resume()
        }
    }

    // MARK: Menu navigation with a controller or the keyboard

    private func startOverlayPolling() {
        overlayTimer?.invalidate()
        // Buttons still held from the hotkey must be released before they count as menu input.
        overlayHeld = navigationInputs()
        let timer = Timer(timeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.pollOverlay() }
        }
        RunLoop.main.add(timer, forMode: .common)
        overlayTimer = timer
    }

    private func stopOverlayPolling() {
        overlayTimer?.invalidate()
        overlayTimer = nil
        #if os(macOS)
        input.releaseAll()
        #endif
    }

    private func navigationInputs() -> Set<PadInput> {
        var state = input.physicalState()
        if state.leftStick.y > 0.5 { state.pressed.insert(.dpadUp) }
        if state.leftStick.y < -0.5 { state.pressed.insert(.dpadDown) }
        return state.pressed
    }

    /// Up/down move, bottom face button or Start chooses, right face button or Select backs out.
    private func pollOverlay() {
        let held = navigationInputs()
        let pressed = held.subtracting(overlayHeld)
        overlayHeld = held
        if isShowingControls { return }
        if isMenuOpen {
            let items = menuItems
            if pressed.contains(.dpadUp) { menuSelection = max(menuSelection - 1, 0) }
            if pressed.contains(.dpadDown) { menuSelection = min(menuSelection + 1, items.count - 1) }
            if !pressed.isDisjoint(with: [.south, .start]), items.indices.contains(menuSelection) {
                choose(items[menuSelection])
            } else if !pressed.isDisjoint(with: [.east, .select, .home]) {
                closeMenu()
            }
        } else if disconnectedController != nil, !pressed.isDisjoint(with: [.south, .start]) {
            dismissDisconnect()
        }
    }

    /// L + R + Select opens the disc picker from a controller (keyboard: Command-D).
    private static let discPickerChord: SEJoypadButtons = [.l, .r, .select]

    func openDiscPicker() {
        guard hasStarted, diskCount > 1, pendingConflict == nil, !isChoosingDisc else { return }
        pause()
        isChoosingDisc = true
        chordArmed = false
        discSelection = currentDisk
        // Buttons still held from the chord must be released before they count as picker input.
        pickerButtons = input.currentButtons()
        let timer = Timer(timeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.pollDiscPicker() }
        }
        RunLoop.main.add(timer, forMode: .common)
        pickerTimer = timer
    }

    /// Controller/keyboard navigation of the open picker: up/down to move, bottom face button or Start
    /// to insert, right face button or Select to cancel.
    private func pollDiscPicker() {
        let buttons = input.currentButtons()
        let pressed = buttons.subtracting(pickerButtons)
        pickerButtons = buttons
        if pressed.contains(.up) { discSelection = max(discSelection - 1, 0) }
        if pressed.contains(.down) { discSelection = min(discSelection + 1, diskCount - 1) }
        if !pressed.isDisjoint(with: [.b, .start]) {
            closeDiscPicker(inserting: discSelection)
        } else if !pressed.isDisjoint(with: [.a, .select]) {
            closeDiscPicker(inserting: nil)
        }
    }

    /// Closes the picker, swapping to `disc` (zero-based) if given, and resumes the game.
    func closeDiscPicker(inserting disc: Int?) {
        guard isChoosingDisc else { return }
        pickerTimer?.invalidate()
        pickerTimer = nil
        isChoosingDisc = false
        if let disc, disc != currentDisk {
            insert(disc)
        }
        #if os(macOS)
        input.releaseAll()
        #endif
        resume()
        if disconnectedController != nil, overlayTimer == nil { startOverlayPolling() }
    }

    private func insert(_ disc: Int) {
        #if DEBUG
        if host?.diskCount ?? 0 < 2, Self.debugDiscCount != nil {
            currentDisk = disc
            status = "Inserted disc \(disc + 1)"
            return
        }
        #endif
        guard let host else { return }
        do {
            try host.insertDisk(disc)
            status = "Inserted disc \(disc + 1)"
        } catch {
            status = error.localizedDescription
        }
        currentDisk = host.currentDisk
    }

    #if DEBUG
    /// UI-only stub for screenshots without a disc core: SUPERSEMU_DEBUG_DISC_COUNT=3 fakes a 3-disc game.
    private static var debugDiscCount: Int? {
        ProcessInfo.processInfo.environment["SUPERSEMU_DEBUG_DISC_COUNT"].flatMap(Int.init)
    }
    #endif

    func stop() {
        startTask?.cancel()
        startTask = nil
        abandonConflict()
        pause()
        autosave()
        hasStarted = false
        isSyncing = false
        pickerTimer?.invalidate()
        pickerTimer = nil
        isChoosingDisc = false
        overlayTimer?.invalidate()
        overlayTimer = nil
        isMenuOpen = false
        disconnectedController = nil
        controllerObservers.forEach { NotificationCenter.default.removeObserver($0) }
        controllerObservers = []
        host?.shutdown()
        host = nil
    }
}
