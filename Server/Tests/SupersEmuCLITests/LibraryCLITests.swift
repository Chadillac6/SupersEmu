import Foundation
import SupersEmuKit
import XCTest

extension CLIEndToEndTests {
    func testLibraryCommandsThroughCLI() async throws {
        let sources = store.paths.root.appendingPathComponent("cli-src", isDirectory: true)
        try FileManager.default.createDirectory(at: sources, withIntermediateDirectories: true)
        var snes = [UInt8](repeating: 0, count: 0x8000)
        for i in 0..<64 { snes[i] = UInt8(i) }
        try Data(snes).write(to: sources.appendingPathComponent("Hello_World (USA).sfc"))
        try Data(count: 0x4000).write(to: sources.appendingPathComponent("Mystery.bin"))
        try Data("notes".utf8).write(to: sources.appendingPathComponent("readme.txt"))

        try await withServer { server in
            let auth = ["--server", server, "--token", self.adminToken!]
            try await self.expectExit(0, ["library", "import", sources.path, "--json"] + auth)
            let report = try SupersEmuJSON.decoder().decode(ImportReport.self, from: self.stdout)
            XCTAssertEqual(report.imported.map(\.title), ["Hello World"])
            XCTAssertEqual(report.needsReview.map(\.filename), ["Mystery.bin"])
            XCTAssertEqual(report.unsupported, [], "readme.txt is skipped")
            let gameID = try XCTUnwrap(report.imported.first?.id)

            try await self.expectExit(0, ["library", "import", sources.path] + auth)
            XCTAssertEqual(self.capture.out.last, "Imported 0, 1 already in library, 1 need review, 0 unsupported")

            try await self.expectExit(0, ["library", "list"] + auth)
            XCTAssertEqual(self.capture.out.first?.hasPrefix("ID"), true)
            XCTAssertTrue(self.capture.out.contains { $0.hasSuffix("Hello World") })

            try await self.expectExit(64, ["library", "rematch"] + auth)
            XCTAssertTrue(self.capture.err.joined().contains("Provide game IDs or --all"))
            try await self.expectExit(64, ["library", "rematch", String(gameID.prefix(12)), "--all"] + auth)
            XCTAssertTrue(self.capture.err.joined().contains("but not both"))
            try await self.expectExit(64, ["library", "rematch", "unknown-prefix"] + auth)
            XCTAssertTrue(self.capture.err.joined().contains("No game matches ID prefix"))
            try await self.expectExit(0, ["library", "rematch", String(gameID.prefix(12)), "--json"] + auth)
            XCTAssertEqual(try SupersEmuJSON.decoder().decode(MetadataRematchResponse.self, from: self.stdout).queued, 1)
            try await self.expectExit(0, ["library", "rematch", "--all"] + auth)
            XCTAssertEqual(self.capture.out.last, "Queued 2 game(s) for a metadata rematch.")

            try await self.expectExit(0, ["library", "review", "--json"] + auth)
            XCTAssertEqual(try SupersEmuJSON.decoder().decode([ReviewItem].self, from: self.stdout).map(\.filename), ["Mystery.bin"])

            try await self.expectExit(0, ["library", "scan", "--json"] + auth)
            XCTAssertEqual(try SupersEmuJSON.decoder().decode(ImportReport.self, from: self.stdout).imported, [])

            // A read-only token can list but not import.
            let reader = try self.store.createAPIToken(ownerUserID: try XCTUnwrap(self.store.adminUser()).id, name: "reader", scopes: [.libraryRead]).token
            try await self.expectExit(0, ["library", "list", "--server", server, "--token", reader])
            try await self.expectExit(4, ["library", "import", sources.path, "--server", server, "--token", reader])
        }
    }
}

extension CLIEndToEndTests {
    func testBIOSStatusThroughCLI() async throws {
        let sources = store.paths.root.appendingPathComponent("cli-bios", isDirectory: true)
        try FileManager.default.createDirectory(at: sources, withIntermediateDirectories: true)
        try Data(count: 524_288).write(to: sources.appendingPathComponent("scph5501.bin"))

        try await withServer { server in
            let auth = ["--server", server, "--token", self.adminToken!]
            try await self.expectExit(0, ["bios", "status", "--json"] + auth)
            let before = try SupersEmuJSON.decoder().decode([BIOSStatus].self, from: self.stdout)
            XCTAssertEqual(before.count, KnownBIOS.all.count)
            XCTAssertTrue(before.allSatisfy { $0.state == .missing })

            try await self.expectExit(0, ["library", "import", sources.path] + auth)
            try await self.expectExit(0, ["bios", "status"] + auth)
            XCTAssertEqual(self.capture.out.first?.hasPrefix("SYSTEM"), true)
            XCTAssertTrue(self.capture.out.contains { $0.contains("scph5501.bin") && $0.contains("wrong-hash") }, "\(self.capture.out)")
            XCTAssertTrue(self.capture.out.contains { $0.contains("bios_CD_U.bin") && $0.contains("missing") })
            XCTAssertTrue(self.capture.out.last?.hasPrefix("Missing required BIOS: scph5501.bin, bios_CD_U.bin") == true)
        }
    }
}
