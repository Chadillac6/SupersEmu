import Foundation
import Observation

/// How the player screen is laid out. On iOS a connected gamepad replaces the touch controls
/// and the game also fills the area they used. The top bar always floats over the game (`TopBarAutoHide`).
struct PlayerChrome: Equatable {
    var showsTouchControls: Bool
    var isFullScreen: Bool

    /// UserDefaults/AppStorage key for the setting; default true.
    static let hideTouchControlsKey = "hideTouchControlsWithController"

    /// ControllerHub lists only extended gamepads (Siri Remote and keyboards aren't in it),
    /// and the first one is player 1.
    static func isControllerActive(connectedGamepads: Int) -> Bool {
        connectedGamepads > 0
    }

    static func resolve(controllerActive: Bool, hideWhenControllerConnected: Bool, hasTouchControls: Bool) -> PlayerChrome {
        guard hasTouchControls else { return PlayerChrome(showsTouchControls: false, isFullScreen: false) }
        if controllerActive && hideWhenControllerConnected {
            return PlayerChrome(showsTouchControls: false, isFullScreen: true)
        }
        return PlayerChrome(showsTouchControls: true, isFullScreen: false)
    }
}

/// Player top bar visibility: it sits over the game and hides after a few seconds without a tap (iOS) or mouse
/// movement (Mac). While pinned (a menu is open, the pointer is on the bar) it stays up.
@MainActor
@Observable
final class TopBarAutoHide {
    private(set) var isRevealed = false
    private(set) var isPinned = false
    private let delay: Duration
    private let clock = ContinuousClock()
    @ObservationIgnored private var deadline: ContinuousClock.Instant?
    @ObservationIgnored private var hideTask: Task<Void, Never>?

    init(delay: Duration = .seconds(3)) {
        self.delay = delay
    }

    /// Shows the bar and restarts the hide timer. Cheap to call on every mouse move.
    func reveal() {
        if !isRevealed { isRevealed = true }
        deadline = clock.now + delay
        guard !isPinned, hideTask == nil else { return }
        hideTask = Task { [weak self] in
            while let deadline = self?.deadline, !Task.isCancelled {
                guard let clock = self?.clock, clock.now < deadline else { break }
                try? await clock.sleep(until: deadline)
            }
            guard !Task.isCancelled, let self else { return }
            self.hideTask = nil
            self.isRevealed = false
        }
    }

    func toggle() {
        if isRevealed {
            hide()
        } else {
            reveal()
        }
    }

    func hide() {
        guard !isPinned else { return }
        isRevealed = false
        cancelTimer()
    }

    /// Pinned keeps the bar up with no timer; unpinning starts a fresh timer.
    func setPinned(_ pinned: Bool) {
        guard pinned != isPinned else { return }
        isPinned = pinned
        if pinned {
            cancelTimer()
            isRevealed = true
        } else {
            reveal()
        }
    }

    private func cancelTimer() {
        hideTask?.cancel()
        hideTask = nil
        deadline = nil
    }
}
