import Foundation
import Observation

/// How the player screen is laid out. On iOS a connected gamepad replaces the touch controls
/// and the game goes full screen.
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

/// Top bar visibility in full screen: a tap reveals it for a few seconds, then it hides again.
@MainActor
@Observable
final class TopBarAutoHide {
    private(set) var isRevealed = false
    private let delay: Duration
    private var hideTask: Task<Void, Never>?

    init(delay: Duration = .seconds(3)) {
        self.delay = delay
    }

    func reveal() {
        isRevealed = true
        hideTask?.cancel()
        hideTask = Task { [delay, weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            self?.isRevealed = false
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
        isRevealed = false
        hideTask?.cancel()
        hideTask = nil
    }
}
