import XCTest

final class PrivilegedCommandTests: XCTestCase {
    func testShellCommandQuotesEachArgument() {
        XCTAssertEqual(
            PrivilegedCommand.shellCommand(["/bin/echo", "it's here", "a b"]),
            "'/bin/echo' 'it'\\''s here' 'a b'")
    }

    func testAppleScriptSourceEscapesQuotesBackslashesAndNewlines() {
        XCTAssertEqual(
            PrivilegedCommand.appleScriptSource(shellCommand: "echo \"a\\b\"\nnext"),
            "do shell script \"echo \\\"a\\\\b\\\"\\nnext\" with administrator privileges")
    }

    func testFirewallAllowCommandAddsThenUnblocks() {
        XCTAssertEqual(
            Firewall.allowShellCommand(binaryPath: "/Apps/My App/server"),
            "'/usr/libexec/ApplicationFirewall/socketfilterfw' '--add' '/Apps/My App/server' && "
                + "'/usr/libexec/ApplicationFirewall/socketfilterfw' '--unblockapp' '/Apps/My App/server'")
    }

    func testExitStatusPrefersOsascriptErrorCode() {
        let cancelled = ProcessResult(status: 1, stdout: "", stderr: "execution error: User canceled. (-128)")
        XCTAssertEqual(PrivilegedCommand.exitStatus(of: cancelled), PrivilegedCommand.userCancelledStatus)
        XCTAssertEqual(PrivilegedCommand.exitStatus(of: ProcessResult(status: 7, stdout: "", stderr: "")), 7)
    }

    func testServerMenuDetailUsesSharedPorts() {
        XCTAssertEqual(ServerMenuStatus.daemonDetail, "Boot server · port \(LocalServerConstants.daemonPort)")
        XCTAssertEqual(ServerMenuStatus.sessionDetail, "This session only · port 8488")
    }
}
