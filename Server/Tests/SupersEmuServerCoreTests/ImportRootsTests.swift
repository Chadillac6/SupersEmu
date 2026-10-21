import Foundation
import SupersEmuKit
@testable import SupersEmuServerCore
import XCTest

final class ImportRootsTests: XCTestCase {
    var folders: [URL] = []
    var stores: [ServerStore] = []

    override func tearDown() async throws {
        for url in folders + stores.map(\.paths.root) { try? FileManager.default.removeItem(at: url) }
    }

    func folder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("se-roots-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        folders.append(url)
        return url
    }

    func makeStore(importRoots: [URL]) throws -> (ServerStore, LibraryImporter) {
        let store = try ServerStore.inMemory(importRoots: importRoots)
        stores.append(store)
        return (store, LibraryImporter(store: store))
    }

    @discardableResult
    func write(_ data: Data, _ name: String, in dir: URL) throws -> URL {
        let url = dir.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url)
        return url
    }

    func testImportsFromAnAllowedRoot() async throws {
        let roms = try folder()
        let (_, importer) = try makeStore(importRoots: [roms])
        try write(ROMFixtures.snes(seed: 1), "Games/Allowed.sfc", in: roms)
        let report = try await importer.importPaths([roms.appendingPathComponent("Games").path], auth: nil)
        XCTAssertEqual(report.imported.count, 1)
        XCTAssertEqual(report.unsupported, [])
    }

    func testRejectsPathsOutsideTheImportRoots() async throws {
        let roms = try folder(), elsewhere = try folder()
        let (_, importer) = try makeStore(importRoots: [roms])
        let file = try write(ROMFixtures.snes(seed: 2), "Outside.sfc", in: elsewhere)
        let report = try await importer.importPaths([file.path, elsewhere.path, "/etc/hosts"], auth: nil)
        XCTAssertEqual(report.imported.count, 0)
        XCTAssertEqual(report.needsReview.count, 0)
        XCTAssertEqual(report.unsupported.count, 3)
        XCTAssertTrue(report.unsupported.allSatisfy { $0.contains("--import-root") }, "\(report.unsupported)")
    }

    func testDataRootIsNeverImportableEvenInsideAnImportRoot() async throws {
        // The default test store allows the whole temporary folder, which contains the store's own root.
        let (store, importer) = try makeStore(importRoots: [FileManager.default.temporaryDirectory])
        let secret = try write(Data("secret".utf8), "admin.token", in: store.paths.root)
        try write(ROMFixtures.snes(seed: 3), "users/x/Nested.sfc", in: store.paths.root)
        let report = try await importer.importPaths([secret.path, store.paths.root.path,
                                                     store.paths.root.appendingPathComponent("users").path,
                                                     store.paths.root.path + "/users/../admin.token"], auth: nil)
        XCTAssertEqual(report.imported.count, 0)
        XCTAssertEqual(report.needsReview.count, 0)
        XCTAssertEqual(report.unsupported.count, 4)
        XCTAssertTrue(report.unsupported.allSatisfy { $0.contains("data, library") }, "\(report.unsupported)")
    }

    func testSymlinksCantEscapeAnImportRoot() async throws {
        let roms = try folder()
        let (store, importer) = try makeStore(importRoots: [roms])
        let secret = try write(Data("secret".utf8), "admin.token", in: store.paths.root)
        let fm = FileManager.default
        try fm.createSymbolicLink(at: roms.appendingPathComponent("token.sfc"), withDestinationURL: secret)
        try fm.createSymbolicLink(at: roms.appendingPathComponent("data"), withDestinationURL: store.paths.root)
        try fm.createDirectory(at: roms.appendingPathComponent("Mixed"), withIntermediateDirectories: true)
        try fm.createSymbolicLink(at: roms.appendingPathComponent("Mixed/token.sfc"), withDestinationURL: secret)
        try write(ROMFixtures.snes(seed: 4), "Mixed/Real.sfc", in: roms)

        let report = try await importer.importPaths([roms.appendingPathComponent("token.sfc").path,
                                                     roms.appendingPathComponent("data").path,
                                                     roms.appendingPathComponent("data/admin.token").path,
                                                     roms.appendingPathComponent("Mixed").path], auth: nil)
        XCTAssertEqual(report.imported.map(\.title).count, 1, "only the real file in Mixed imports")
        XCTAssertEqual(report.needsReview.count, 0)
        XCTAssertEqual(report.unsupported.count, 3, "\(report.unsupported)")
    }

    func testHiddenFoldersInsideAnImportRootAreRejected() async throws {
        let home = try folder()
        let (_, importer) = try makeStore(importRoots: [home])
        let key = try write(Data("key".utf8), ".ssh/id_ed25519", in: home)
        let report = try await importer.importPaths([key.path, home.appendingPathComponent(".ssh").path], auth: nil)
        XCTAssertEqual(report.needsReview.count, 0)
        XCTAssertEqual(report.unsupported.count, 2)
    }

    func testIncomingReplacedBySymlinkGrantsNothing() async throws {
        let (store, importer) = try makeStore(importRoots: [])
        let secret = try write(Data("secret".utf8), "admin.token", in: store.paths.root)
        try FileManager.default.removeItem(at: store.paths.incoming)
        try FileManager.default.createSymbolicLink(at: store.paths.incoming, withDestinationURL: store.paths.root)
        let report = try await importer.importPaths([store.paths.incoming.appendingPathComponent("admin.token").path, secret.path], auth: nil)
        XCTAssertEqual(report.needsReview.count, 0)
        XCTAssertEqual(report.unsupported.count, 2, "\(report.unsupported)")
    }

    func testHiddenFilesInIncomingAreRejected() async throws {
        let (store, importer) = try makeStore(importRoots: [])
        let hidden = try write(ROMFixtures.snes(seed: 7), ".staging/Hidden.sfc", in: store.paths.incoming)
        let report = try await importer.importPaths([hidden.path], auth: nil)
        XCTAssertEqual(report.imported.count, 0)
        XCTAssertTrue(report.unsupported.first?.contains("hidden") == true, "\(report.unsupported)")
    }

    func testDanglingSymlinkIsNotFound() async throws {
        let roms = try folder()
        let (_, importer) = try makeStore(importRoots: [roms])
        try FileManager.default.createSymbolicLink(at: roms.appendingPathComponent("gone.sfc"),
                                                   withDestinationURL: URL(fileURLWithPath: "/no/such/target.sfc"))
        let report = try await importer.importPaths([roms.appendingPathComponent("gone.sfc").path], auth: nil)
        XCTAssertEqual(report.unsupported.count, 1)
        XCTAssertTrue(report.unsupported[0].contains("not found"), "\(report.unsupported)")
    }

    func testIncomingIsAlwaysAllowedButItsSymlinksAreChecked() async throws {
        let elsewhere = try folder()
        let (store, importer) = try makeStore(importRoots: [])
        let inIncoming = try write(ROMFixtures.snes(seed: 5), "Dropped.sfc", in: store.paths.incoming)
        let outside = try write(ROMFixtures.snes(seed: 6), "Outside.sfc", in: elsewhere)
        let direct = try await importer.importPaths([inIncoming.path, outside.path], auth: nil)
        XCTAssertEqual(direct.imported.count, 1)
        XCTAssertEqual(direct.unsupported.count, 1)

        let secret = try write(Data("secret".utf8), "admin.token", in: store.paths.root)
        try FileManager.default.createSymbolicLink(at: store.paths.incoming.appendingPathComponent("token.sfc"), withDestinationURL: secret)
        let scan = try await importer.scanIncoming(auth: nil)
        XCTAssertEqual(scan.needsReview.count, 0)
        XCTAssertTrue(scan.unsupported.contains { $0.hasPrefix("token.sfc:") }, "\(scan.unsupported)")
    }
}
