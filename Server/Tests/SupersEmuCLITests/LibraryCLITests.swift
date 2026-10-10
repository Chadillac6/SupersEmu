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
            XCTAssertEqual(report.unsupported.count, 1)

            try await self.expectExit(0, ["library", "import", sources.path] + auth)
            XCTAssertEqual(self.capture.out.last, "Imported 0, 1 already in library, 1 need review, 1 unsupported")

            try await self.expectExit(0, ["library", "list"] + auth)
            XCTAssertEqual(self.capture.out.first?.hasPrefix("ID"), true)
            XCTAssertTrue(self.capture.out.contains { $0.hasSuffix("Hello World") })

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
