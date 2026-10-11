import ServiceManagement
import SupersEmuKit
import XCTest

final class ServerMenuStatusTests: XCTestCase {
    func testRunningDaemonWithTwoDevices() {
        let status = makeStatus(daemonStatus: .enabled, health: health, deviceCount: 2)

        XCTAssertEqual(status.state, .running)
        XCTAssertEqual(status.title, "SupersEmu Server: Running")
        XCTAssertTrue(status.detail.contains("2 devices"))
        XCTAssertEqual(status.symbolName, "server.rack")
    }

    func testRunningDaemonUsesSingularDeviceDetail() {
        let status = makeStatus(daemonStatus: .enabled, health: health, deviceCount: 1)

        XCTAssertEqual(status.detail, "Boot server · port 8487 · 1 device")
    }

    func testNeedsApproval() {
        let status = makeStatus(daemonStatus: .requiresApproval)

        XCTAssertEqual(status.state, .needsApproval)
        XCTAssertEqual(status.title, "SupersEmu Server: Needs approval in Login Items")
        XCTAssertEqual(status.symbolName, "exclamationmark.triangle")
    }

    func testEnabledDaemonWithoutHealthIsNotResponding() {
        let status = makeStatus(daemonStatus: .enabled)

        XCTAssertEqual(status.state, .notRunning)
        XCTAssertEqual(status.title, "SupersEmu Server: Not responding")
    }

    func testUnregisteredDaemonWithoutSessionIsOff() {
        let status = makeStatus(daemonStatus: .notRegistered)

        XCTAssertEqual(status.state, .off)
        XCTAssertEqual(status.title, "SupersEmu Server: Off")
    }

    func testUnexpectedSessionExitIsNotRespondingAndCanRestart() {
        let status = makeStatus(daemonStatus: .notRegistered, sessionStoppedUnexpectedly: true)

        XCTAssertEqual(status.state, .notRunning)
        XCTAssertEqual(status.title, "SupersEmu Server: Not responding")
        XCTAssertEqual(status.detail, "Server stopped unexpectedly")
        XCTAssertTrue(status.sessionStoppedUnexpectedly)
    }

    private var health: HealthResponse {
        HealthResponse(status: "ok", serverName: "SupersEmu", serverVersion: "1.0")
    }

    private func makeStatus(
        daemonStatus: SMAppService.Status,
        sessionRunning: Bool = false,
        health: HealthResponse? = nil,
        deviceCount: Int = 0,
        sessionStoppedUnexpectedly: Bool = false
    ) -> ServerMenuStatus {
        ServerMenuStatus(
            daemonStatus: daemonStatus,
            sessionRunning: sessionRunning,
            health: health,
            deviceCount: deviceCount,
            sessionStoppedUnexpectedly: sessionStoppedUnexpectedly
        )
    }
}
