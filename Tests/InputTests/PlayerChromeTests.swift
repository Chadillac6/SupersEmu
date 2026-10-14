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
        let autoHide = TopBarAutoHide(delay: .milliseconds(300))
        autoHide.reveal()
        try await Task.sleep(for: .milliseconds(200))
        autoHide.reveal()  // restart: without this the bar would hide at ~300 ms
        try await Task.sleep(for: .milliseconds(200))  // ~400 ms after first reveal, ~200 after second
        XCTAssertTrue(autoHide.isRevealed)
        try await Task.sleep(for: .milliseconds(400))
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
