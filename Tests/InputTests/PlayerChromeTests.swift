import XCTest

final class PlayerChromeTests: XCTestCase {
    func testIsControllerActive() {
        XCTAssertFalse(PlayerChrome.isControllerActive(connectedGamepads: 0))
        XCTAssertTrue(PlayerChrome.isControllerActive(connectedGamepads: 1))
        XCTAssertTrue(PlayerChrome.isControllerActive(connectedGamepads: 3))
    }

    func testResolveControllerAndSettingGoesFullScreen() {
        let chrome = PlayerChrome.resolve(controllerActive: true, hideWhenControllerConnected: true, hasTouchControls: true)
        XCTAssertEqual(chrome, PlayerChrome(showsTouchControls: false, isFullScreen: true))
    }

    func testResolveControllerWithSettingOffKeepsTouchControls() {
        let chrome = PlayerChrome.resolve(controllerActive: true, hideWhenControllerConnected: false, hasTouchControls: true)
        XCTAssertEqual(chrome, PlayerChrome(showsTouchControls: true, isFullScreen: false))
    }

    func testResolveNoControllerKeepsTouchControls() {
        let chrome = PlayerChrome.resolve(controllerActive: false, hideWhenControllerConnected: true, hasTouchControls: true)
        XCTAssertEqual(chrome, PlayerChrome(showsTouchControls: true, isFullScreen: false))
    }

    func testResolveWithoutTouchControlsIsAlwaysChromeless() {
        for controller in [true, false] {
            for setting in [true, false] {
                let chrome = PlayerChrome.resolve(controllerActive: controller,
                                                  hideWhenControllerConnected: setting,
                                                  hasTouchControls: false)
                XCTAssertEqual(chrome, PlayerChrome(showsTouchControls: false, isFullScreen: false))
            }
        }
    }

    func testConnectThenDisconnectRoundTrip() {
        let connected = PlayerChrome.resolve(
            controllerActive: PlayerChrome.isControllerActive(connectedGamepads: 1),
            hideWhenControllerConnected: true, hasTouchControls: true)
        XCTAssertTrue(connected.isFullScreen)
        XCTAssertFalse(connected.showsTouchControls)

        let disconnected = PlayerChrome.resolve(
            controllerActive: PlayerChrome.isControllerActive(connectedGamepads: 0),
            hideWhenControllerConnected: true, hasTouchControls: true)
        XCTAssertFalse(disconnected.isFullScreen)
        XCTAssertTrue(disconnected.showsTouchControls)
    }

    @MainActor
    func testTopBarAutoHideRevealsThenHides() async throws {
        let autoHide = TopBarAutoHide(delay: .milliseconds(100))
        XCTAssertFalse(autoHide.isRevealed)
        autoHide.reveal()
        XCTAssertTrue(autoHide.isRevealed)
        try await Task.sleep(for: .milliseconds(500))
        XCTAssertFalse(autoHide.isRevealed)
    }

    @MainActor
    func testTopBarAutoHideSecondRevealRestartsTimer() async throws {
        let delay = Duration.milliseconds(600)
        let clock = ContinuousClock()
        let autoHide = TopBarAutoHide(delay: delay)
        let firstReveal = clock.now
        autoHide.reveal()
        try await Task.sleep(for: .milliseconds(400))
        let secondReveal = clock.now
        autoHide.reveal()  // restart: without this the bar would hide 600 ms after the first reveal
        try await Task.sleep(for: .milliseconds(400))
        let now = clock.now
        // Only meaningful between the first timer's deadline and the restarted one; a stalled runner can't tell.
        guard now - firstReveal > delay, now - secondReveal < delay else {
            throw XCTSkip("runner timing drifted past the check window")
        }
        XCTAssertTrue(autoHide.isRevealed)
        let deadline = clock.now + .seconds(5)
        while autoHide.isRevealed, clock.now < deadline {
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertFalse(autoHide.isRevealed)
    }

    @MainActor
    func testTopBarAutoHideToggle() {
        let autoHide = TopBarAutoHide(delay: .seconds(60))
        autoHide.toggle()
        XCTAssertTrue(autoHide.isRevealed)
        autoHide.toggle()
        XCTAssertFalse(autoHide.isRevealed)
    }

    @MainActor
    func testTopBarAutoHideCancelsPendingHide() async throws {
        let autoHide = TopBarAutoHide(delay: .milliseconds(100))
        autoHide.reveal()
        autoHide.hide()
        XCTAssertFalse(autoHide.isRevealed)
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertFalse(autoHide.isRevealed)
    }
}
