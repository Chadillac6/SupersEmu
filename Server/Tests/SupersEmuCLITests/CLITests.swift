import ArgumentParser
import Foundation
import Hummingbird
import HummingbirdTesting
import SupersEmuKit
import SupersEmuServerCore
@testable import supersemu
import XCTest

final class CLIParsingTests: XCTestCase {
    func parse<T>(_ args: [String], as: T.Type = T.self) throws -> T {
        let command = try SupersEmuCLI.parseAsRoot(args)
        return try XCTUnwrap(command as? T, "\(Swift.type(of: command))")
    }

    func testTokensCreateParsesCommaSeparatedAndRepeatedScopes() throws {
        let command: Tokens.Create = try parse(["tokens", "create", "--name", "openclaw", "--scope", "library:read,library:write", "--scope", "saves:read,library:read", "--json"])
        XCTAssertEqual(command.name, "openclaw")
        XCTAssertEqual(try command.scopes, [.libraryRead, .libraryWrite, .savesRead])
        XCTAssertTrue(command.connection.json)
    }

    func testTokensCreateRejectsBadInput() {
        for args in [
            ["tokens", "create", "--name", "x", "--scope", "library:read,root"],
            ["tokens", "create", "--name", "x"],
            ["tokens", "create", "--scope", "library:read"],
            ["tokens", "create", "--name", " ", "--scope", "library:read"],
            ["tokens", "create", "--name", "x", "--scope", ","],
        ] {
            XCTAssertThrowsError(try SupersEmuCLI.parseAsRoot(args), args.joined(separator: " ")) { error in
                XCTAssertEqual(SupersEmuCLI.exitCode(for: error).rawValue, 64)
            }
        }
    }

    func testSubcommandsParse() throws {
        let revoke: Devices.Revoke = try parse(["devices", "revoke", "abc", "--server", "http://mini:8487", "--token", "t"])
        XCTAssertEqual(revoke.id, "abc")
        XCTAssertEqual(revoke.connection.server, "http://mini:8487")
        XCTAssertEqual(revoke.connection.token, "t")
        let _: Devices.List = try parse(["devices", "list"])
        let _: Users.List = try parse(["users", "list", "--json"])
        let _: Server.Status = try parse(["server", "status"])
        let tokenRevoke: Tokens.Revoke = try parse(["tokens", "revoke", "tid"])
        XCTAssertEqual(tokenRevoke.id, "tid")
        let _: Tokens.List = try parse(["tokens", "list"])
        XCTAssertThrowsError(try SupersEmuCLI.parseAsRoot(["devices", "revoke"]))
    }

    func testLoginNeedsExactlyOneTokenSource() throws {
        let login: Login = try parse(["login", "--server", "http://mini:8487", "--token", "t"])
        XCTAssertEqual(login.server, "http://mini:8487")
        let _: Login = try parse(["login", "--server", "http://mini:8487", "--token-stdin"])
        XCTAssertThrowsError(try SupersEmuCLI.parseAsRoot(["login", "--server", "http://mini:8487"]))
        XCTAssertThrowsError(try SupersEmuCLI.parseAsRoot(["login", "--server", "http://mini:8487", "--token", "t", "--token-stdin"]))
        XCTAssertThrowsError(try SupersEmuCLI.parseAsRoot(["login", "--token", "t"]))
    }

    func testExitCodes() {
        XCTAssertEqual(CLIError(APIClientError.http(status: 404, message: nil)).exitCode, 2)
        XCTAssertEqual(CLIError(APIClientError.http(status: 401, message: nil)).exitCode, 3)
        XCTAssertEqual(CLIError(APIClientError.http(status: 403, message: nil)).exitCode, 4)
        XCTAssertEqual(CLIError(URLError(.cannotConnectToHost)).exitCode, 5)
        XCTAssertEqual(CLIError(APIClientError.http(status: 400, message: nil)).exitCode, 6)
        XCTAssertEqual(CLIError(APIClientError.http(status: 500, message: nil)).exitCode, 7)
        XCTAssertEqual(CLIError.usage("x").exitCode, 64)
        XCTAssertEqual(CLIError(CocoaError(.fileWriteNoPermission)).exitCode, 1)
    }
}

final class CLIConfigTests: XCTestCase {
    var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("supersemu-cli-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: dir) }

    func connection(_ args: [String]) throws -> Connection { try Connection.parse(args) }

    func testConfigFileIsWrittenWith0600AndRoundTrips() throws {
        let url = dir.appendingPathComponent("nested/supersemu/config.json")
        try CLIConfigFile(server: "http://mini:8487", token: "sek_1").write(to: url)
        try CLIConfigFile(server: "http://mini:8487", token: "sek_2").write(to: url)
        XCTAssertEqual(try CLIConfigFile.load(from: url), CLIConfigFile(server: "http://mini:8487", token: "sek_2"))
        let mode = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(mode?.intValue, 0o600)
        let dirMode = try FileManager.default.attributesOfItem(atPath: url.deletingLastPathComponent().path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(dirMode?.intValue, 0o700)
    }

    func testDefaultConfigPath() {
        XCTAssertEqual(CLIConfigFile.defaultURL(environment: ["SUPERSEMU_CONFIG": "/x/c.json"]).path, "/x/c.json")
        XCTAssertEqual(CLIConfigFile.defaultURL(environment: ["XDG_CONFIG_HOME": "/x"]).path, "/x/supersemu/config.json")
        XCTAssertTrue(CLIConfigFile.defaultURL(environment: [:]).path.hasSuffix("/.config/supersemu/config.json"))
    }

    func testResolutionPrecedence() throws {
        let config = dir.appendingPathComponent("config.json")
        try CLIConfigFile(server: "http://mini:8487", token: "from-config").write(to: config)
        let adminToken = dir.appendingPathComponent("admin.token")
        try "from-admin-file\n".write(to: adminToken, atomically: true, encoding: .utf8)
        func resolve(_ args: [String], env: [String: String] = [:], configURL: URL? = nil) throws -> Connection.Resolved {
            try connection(args).resolve(environment: env, configURL: configURL ?? config, localAdminTokenPath: adminToken.path,
                                         localCertificatePath: dir.appendingPathComponent("server.cer").path)
        }

        XCTAssertEqual(try resolve([]), .init(server: URL(string: "http://mini:8487")!, token: "from-config"))
        XCTAssertEqual(try resolve([], env: ["SUPERSEMU_TOKEN": "from-env"]).token, "from-env")
        XCTAssertEqual(try resolve(["--token", "from-flag"], env: ["SUPERSEMU_TOKEN": "from-env"]).token, "from-flag")
        XCTAssertEqual(try resolve([], env: ["SUPERSEMU_SERVER": "http://other:1"]).server.absoluteString, "http://other:1")
        XCTAssertEqual(try resolve(["--server", "http://flag:2"], env: ["SUPERSEMU_SERVER": "http://other:1"]).server.absoluteString, "http://flag:2")
        // The saved token is only sent to the server it was saved for.
        XCTAssertNil(try resolve(["--server", "http://other:1"]).token)
        XCTAssertEqual(try resolve(["--server", "http://MINI:8487/"]).token, "from-config")
        XCTAssertNil(try resolve(["--server", "http://mini:8487/other"]).token)
        XCTAssertNil(try resolve(["--server", "https://mini:8487"]).token)
        XCTAssertTrue(Connection.sameServer("http://mini:8487/api/", "HTTP://Mini:8487/api"))
        XCTAssertFalse(Connection.sameServer("http://mini:8487/api", "http://mini:8487/API"))
        XCTAssertTrue(Connection.sameServer("http://mini", "http://mini:80"))
        // No config: localhost falls back to the Mac mini's admin.token, remote hosts don't.
        let missing = dir.appendingPathComponent("missing.json")
        XCTAssertEqual(try resolve([], configURL: missing), .init(server: URL(string: Connection.defaultServer)!, token: "from-admin-file"))
        XCTAssertNil(try resolve(["--server", "http://mini:8487"], configURL: missing).token)
        XCTAssertEqual(try resolve(["--server", "http://localhost:8487"], configURL: missing).token, "from-admin-file")
        // admin.token only goes to the server's own port, not another local service.
        XCTAssertNil(try resolve(["--server", "http://127.0.0.1:9999"], configURL: missing).token)
        XCTAssertNil(try resolve(["--server", "http://127.0.0.1:8487/x"], configURL: missing).token)
        // A broken config doesn't block explicit flags or env, but is reported when it's needed.
        let broken = dir.appendingPathComponent("broken.json")
        try "{invalid".write(to: broken, atomically: true, encoding: .utf8)
        XCTAssertEqual(try resolve(["--server", "http://mini:8487", "--token", "t"], configURL: broken).token, "t")
        XCTAssertEqual(try resolve([], env: ["SUPERSEMU_SERVER": "http://mini:8487", "SUPERSEMU_TOKEN": "e"], configURL: broken).token, "e")
        XCTAssertThrowsError(try resolve([], configURL: broken)) { XCTAssertEqual(($0 as? CLIError)?.exitCode, 1) }
        XCTAssertThrowsError(try resolve(["--server", "mini:8487"]))
        XCTAssertThrowsError(try resolve(["--server", "ftp://mini"]))
    }
}

/// Runs real CLI commands against a live in-process server.
final class CLIEndToEndTests: XCTestCase {
    final class Capture: @unchecked Sendable {
        var out: [String] = []
        var err: [String] = []
    }

    var store: ServerStore!
    var adminToken: String!
    var capture: Capture!

    override func setUp() async throws {
        store = try ServerStore.inMemory()
        let admin = try store.createUser(displayName: "Chad", role: .admin)
        adminToken = try store.createAPIToken(ownerUserID: admin.id, name: "local-cli", scopes: Scope.allCases).token
        let capture = Capture()
        self.capture = capture
        CLIOutput.stdout = { capture.out.append($0) }
        CLIOutput.stderr = { capture.err.append($0) }
        setenv("SUPERSEMU_CONFIG", store.paths.root.appendingPathComponent("config.json").path, 1)
        unsetenv("SUPERSEMU_TOKEN")
        unsetenv("SUPERSEMU_SERVER")
    }

    override func tearDown() async throws {
        CLIOutput.stdout = { print($0) }
        CLIOutput.stderr = { FileHandle.standardError.write(Data(($0 + "\n").utf8)) }
        unsetenv("SUPERSEMU_CONFIG")
    }

    func withServer(_ body: @escaping (String) async throws -> Void) async throws {
        let app = buildApplication(store: store, configuration: .init())
        try await app.test(.live) { client in
            try await body("http://localhost:\(try XCTUnwrap(client.port))")
        }
    }

    /// Runs `supersemu <args>` and returns its exit code; output lands in `capture`.
    @discardableResult
    func cli(_ args: [String]) async throws -> Int32 {
        capture.out = []
        capture.err = []
        do {
            var command = try XCTUnwrap(try SupersEmuCLI.parseAsRoot(args) as? AsyncParsableCommand)
            try await command.run()
            return 0
        } catch let exit as ExitCode {
            return exit.rawValue
        }
    }

    func expectExit(_ code: Int32, _ args: [String], file: StaticString = #filePath, line: UInt = #line) async throws {
        let actual = try await cli(args)
        XCTAssertEqual(actual, code, "supersemu \(args.joined(separator: " ")) stderr: \(capture.err)", file: file, line: line)
    }

    var stdout: Data { Data(capture.out.joined(separator: "\n").utf8) }

    func testTokenLifecycleThroughCLI() async throws {
        try await withServer { server in
            let auth = ["--server", server, "--token", self.adminToken!]
            try await self.expectExit(0, ["tokens", "create", "--name", "openclaw", "--scope", "library:read,library:write", "--json"] + auth)
            let created = try SupersEmuJSON.decoder().decode(TokenInfo.self, from: self.stdout)
            let botToken = try XCTUnwrap(created.token)
            XCTAssertEqual(created.scopes, [.libraryRead, .libraryWrite])

            // Text mode: stdout is only the token, the notice goes to stderr.
            try await self.expectExit(0, ["tokens", "create", "--name", "script", "--scope", "saves:read"] + auth)
            XCTAssertEqual(self.capture.out.count, 1)
            XCTAssertTrue(self.capture.out[0].hasPrefix("sek_"))
            XCTAssertTrue(self.capture.err.joined().contains("not shown again"))

            try await self.expectExit(0, ["tokens", "list", "--json"] + auth)
            let list = try SupersEmuJSON.decoder().decode([TokenInfo].self, from: self.stdout)
            XCTAssertEqual(list.map(\.name), ["local-cli", "openclaw", "script"])
            XCTAssertTrue(list.allSatisfy { $0.token == nil })
            XCTAssertFalse(self.capture.out.joined().contains(botToken))

            // The bot token can't use admin commands: exit 4 with a JSON error on stderr.
            try await self.expectExit(4, ["users", "list", "--json", "--server", server, "--token", botToken])
            XCTAssertTrue(self.capture.out.isEmpty)
            let error = try JSONSerialization.jsonObject(with: Data(self.capture.err.joined().utf8)) as? [String: Any]
            XCTAssertEqual(error?["status"] as? Int, 403)
            XCTAssertEqual(error?["exitCode"] as? Int, 4)

            // ...but `server status` still works for it, without the admin section.
            try await self.expectExit(0, ["server", "status", "--json", "--server", server, "--token", botToken])
            let status = try JSONSerialization.jsonObject(with: self.stdout) as? [String: Any]
            XCTAssertNotNil(status?["health"])
            XCTAssertNotNil(status?["me"])
            XCTAssertNil(status?["admin"])

            try await self.expectExit(0, ["tokens", "revoke", created.id] + auth)
            try await self.expectExit(3, ["server", "status", "--server", server, "--token", botToken])
            try await self.expectExit(2, ["tokens", "revoke", "missing"] + auth)
        }
    }

    func testStatusUsersAndDevicesThroughCLI() async throws {
        let admin = try XCTUnwrap(store.adminUser())
        let ipad = try store.createDeviceToken(userID: admin.id, deviceName: "Chad's iPad")
        try await withServer { server in
            let auth = ["--server", server, "--token", self.adminToken!]
            try await self.expectExit(0, ["server", "status", "--json"] + auth)
            let status = try JSONSerialization.jsonObject(with: self.stdout) as? [String: Any]
            let adminStatus = status?["admin"] as? [String: Any]
            XCTAssertEqual(adminStatus?["deviceCount"] as? Int, 1)
            XCTAssertNotNil(adminStatus?["freeBytes"] as? Int)

            try await self.expectExit(0, ["server", "status"] + auth)
            XCTAssertTrue(self.capture.out.contains { $0.hasPrefix("Data: ") && $0.contains("free") })

            try await self.expectExit(0, ["users", "create", "Alex", "--json"] + auth)
            XCTAssertEqual(try SupersEmuJSON.decoder().decode(UserInfo.self, from: self.stdout).role, .player)
            try await self.expectExit(0, ["users", "list"] + auth)
            XCTAssertEqual(self.capture.out.first?.hasPrefix("ID"), true)
            XCTAssertEqual(self.capture.out.count, 3)

            try await self.expectExit(0, ["devices", "revoke", ipad.deviceID, "--json"] + auth)
            XCTAssertNotNil(try SupersEmuJSON.decoder().decode(DeviceInfo.self, from: self.stdout).revokedAt)
            try await self.expectExit(0, ["devices", "list"] + auth)
            XCTAssertTrue(self.capture.out.contains { $0.contains("Chad's iPad") && $0.hasSuffix("revoked") })
            try await self.expectExit(2, ["devices", "revoke", "missing", "--json"] + auth)
        }
    }

    func testLoginWritesConfigUsedByLaterCommands() async throws {
        try await withServer { server in
            try await self.expectExit(3, ["login", "--server", server, "--token", "bad"])
            XCTAssertFalse(FileManager.default.fileExists(atPath: CLIConfigFile.defaultURL().path))

            try await self.expectExit(0, ["login", "--server", server, "--token", self.adminToken!])
            let url = CLIConfigFile.defaultURL()
            XCTAssertEqual(try CLIConfigFile.load(from: url), CLIConfigFile(server: server, token: self.adminToken!))
            let mode = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber
            XCTAssertEqual(mode?.intValue, 0o600)

            // No flags: server and token come from the config file.
            try await self.expectExit(0, ["users", "list", "--json"])
            XCTAssertEqual(try SupersEmuJSON.decoder().decode([UserInfo].self, from: self.stdout).map(\.displayName), ["Chad"])
        }
    }

    func testUnreachableServerExitCode() async throws {
        try await expectExit(5, ["server", "status", "--server", "http://127.0.0.1:1", "--token", "x", "--json"])
        XCTAssertTrue(capture.err.joined().contains("\"exitCode\" : 5"))
    }
}

/// Runs the built `supersemu` binary, so the entry point in main.swift is covered too.
final class CLIBinaryTests: XCTestCase {
    func runBinary(_ args: [String]) throws -> (status: Int32, stdout: String, stderr: String) {
        let binary = Bundle(for: Self.self).bundleURL.deletingLastPathComponent().appendingPathComponent("supersemu")
        try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: binary.path), "supersemu binary not built at \(binary.path)")
        let process = Process()
        process.executableURL = binary
        process.arguments = args
        var environment = ProcessInfo.processInfo.environment
        environment["SUPERSEMU_CONFIG"] = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).json").path
        environment.removeValue(forKey: "SUPERSEMU_TOKEN")
        environment.removeValue(forKey: "SUPERSEMU_SERVER")
        process.environment = environment
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        try process.run()
        process.waitUntilExit()
        return (process.terminationStatus,
                String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self),
                String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self))
    }

    func testBinaryRunsCommandsAndReturnsExitCodes() throws {
        let unreachable = try runBinary(["server", "status", "--server", "http://127.0.0.1:1", "--token", "x", "--json"])
        XCTAssertEqual(unreachable.status, 5, unreachable.stdout + unreachable.stderr)
        XCTAssertEqual(unreachable.stdout, "")
        let error = try JSONSerialization.jsonObject(with: Data(unreachable.stderr.utf8)) as? [String: Any]
        XCTAssertEqual(error?["exitCode"] as? Int, 5)

        let usage = try runBinary(["tokens", "create", "--name", "x", "--scope", "root"])
        XCTAssertEqual(usage.status, 64)
        XCTAssertTrue(usage.stderr.contains("Unknown scope 'root'"))
    }
}

extension CLIConfigTests {
    func testTokensOnlyGoOverHTTPSOrLoopback() throws {
        XCTAssertThrowsError(try Connection.session(for: .init(server: URL(string: "http://mini:8487")!, token: "t")))
        XCTAssertNoThrow(try Connection.session(for: .init(server: URL(string: "http://mini:8487")!, token: nil)))
        XCTAssertNoThrow(try Connection.session(for: .init(server: URL(string: "http://127.0.0.1:8487")!, token: "t")))
        XCTAssertNoThrow(try Connection.session(for: .init(server: URL(string: "https://mini:8487")!, token: "t", certificateSHA256: String(repeating: "a", count: 64))))
    }
}

extension CLIConfigTests {
    func testLoginPinIsReusedOnlyForItsServer() throws {
        let config = dir.appendingPathComponent("pinned.json")
        let pin = String(repeating: "b", count: 64)
        try CLIConfigFile(server: "https://mini:8487", token: "sek_1", certificateSHA256: pin).write(to: config)
        func resolve(_ args: [String]) throws -> Connection.Resolved {
            try connection(args).resolve(environment: [:], configURL: config, localAdminTokenPath: "/nonexistent")
        }
        XCTAssertEqual(try resolve([]).certificateSHA256, pin)
        XCTAssertNil(try resolve(["--server", "https://other:8487"]).certificateSHA256)
        XCTAssertEqual(try resolve(["--certificate-sha256", "cc"]).certificateSHA256, "cc")
        XCTAssertEqual(try resolve(["--server", "https://mini:8487", "--token", "sek_x"]).certificateSHA256, pin)
    }
}
