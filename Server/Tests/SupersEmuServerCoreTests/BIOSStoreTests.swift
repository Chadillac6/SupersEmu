import CryptoKit
import Foundation
import SupersEmuKit
import XCTest

/// Client BIOS sync into the core system directory, with synthetic (non-BIOS) bytes.
final class BIOSStoreTests: XCTestCase {
    var directory: URL!
    var store: BIOSStore { BIOSStore(directory: directory) }

    override func setUp() {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("system-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
    }

    static func bios(_ bytes: Data, _ filename: String, _ system: SystemID, required: Bool = true) -> BIOSFileInfo {
        BIOSFileInfo(id: SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined(),
                     filename: filename, system: system, region: "US", required: required)
    }

    func testSyncWritesCanonicalNamesAndSatisfiesSystems() async throws {
        let psx = Data("synthetic psx bios".utf8), segacd = Data("synthetic sega cd bios".utf8)
        let list = [Self.bios(psx, "scph5501.bin", .psx), Self.bios(segacd, "bios_CD_U.bin", .segacd)]
        let served = [list[0].id: psx, list[1].id: segacd]
        XCTAssertFalse(BIOSStore.isSatisfied(.psx, by: store.installed()))
        let result = try await store.sync(list) { try XCTUnwrap(served[$0.id]) }
        XCTAssertEqual(result.installed, list)
        XCTAssertEqual(result.failed, [])
        XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent("scph5501.bin")), psx)
        XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent("bios_CD_U.bin")), segacd)
        let installed = store.installed()
        XCTAssertTrue(BIOSStore.isSatisfied(.psx, by: installed))
        XCTAssertTrue(BIOSStore.isSatisfied(.segacd, by: installed))
        XCTAssertTrue(BIOSStore.isSatisfied(.snes, by: []), "cartridge systems never need a BIOS")
    }

    func testWrongHashIsNeverWritten() async throws {
        let info = Self.bios(Data("expected".utf8), "scph5501.bin", .psx)
        let result = try await store.sync([info]) { _ in Data("tampered".utf8) }
        XCTAssertEqual(result.failed, [info])
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("scph5501.bin").path))
        XCTAssertFalse(BIOSStore.isSatisfied(.psx, by: store.installed()))
    }

    func testIntactFilesAreNotRefetchedAndCorruptionIsDetected() async throws {
        let bytes = Data("synthetic".utf8)
        let info = Self.bios(bytes, "bios_CD_U.bin", .segacd)
        _ = try await store.sync([info]) { _ in bytes }
        let fetches = Counter()
        _ = try await store.sync([info]) { _ in fetches.increment(); return bytes }
        XCTAssertEqual(fetches.value, 0)
        // A same-size flip on disk no longer verifies, so the next sync replaces it.
        try Data("synthetiK".utf8).write(to: directory.appendingPathComponent("bios_CD_U.bin"))
        XCTAssertEqual(store.installed(), [])
        _ = try await store.sync([info]) { _ in fetches.increment(); return bytes }
        XCTAssertEqual(fetches.value, 1)
        XCTAssertEqual(store.installed(), [info])
    }

    func testRemovesOnlyFilesItSyncedWhenServerDropsThem() async throws {
        let bytes = Data("synthetic".utf8)
        _ = try await store.sync([Self.bios(bytes, "scph5501.bin", .psx)]) { _ in bytes }
        let userFile = directory.appendingPathComponent("user-placed.bin")
        try Data("keep".utf8).write(to: userFile)
        let result = try await store.sync([]) { _ in XCTFail("nothing to fetch"); return Data() }
        XCTAssertEqual(result.installed, [])
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("scph5501.bin").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: userFile.path))
    }

    func testUserPlacedFilesAreNeverReplacedOrRemoved() async throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let bytes = Data("synthetic".utf8)
        let matching = Self.bios(bytes, "scph5501.bin", .psx)
        try bytes.write(to: directory.appendingPathComponent("scph5501.bin"))
        let userOther = Data("user's own dump".utf8)
        try userOther.write(to: directory.appendingPathComponent("bios_CD_U.bin"))
        let segacd = Self.bios(Data("server sega cd".utf8), "bios_CD_U.bin", .segacd)
        let result = try await store.sync([matching, segacd]) { _ in XCTFail("nothing should be fetched"); return Data() }
        XCTAssertEqual(result.installed, [matching], "a matching user file counts as installed")
        XCTAssertEqual(result.failed, [segacd])
        XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent("bios_CD_U.bin")), userOther, "never overwritten")
        XCTAssertEqual(store.installed(), [matching])
        _ = try await store.sync([]) { _ in Data() }
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.appendingPathComponent("scph5501.bin").path), "never deleted")
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.appendingPathComponent("bios_CD_U.bin").path))
    }

    func testFailedReplacementKeepsPreviousCopy() async throws {
        let old = Data("revision A".utf8)
        let oldInfo = Self.bios(old, "scph5501.bin", .psx)
        _ = try await store.sync([oldInfo]) { _ in old }
        let newInfo = Self.bios(Data("revision B".utf8), "scph5501.bin", .psx)
        let result = try await store.sync([newInfo]) { _ in throw URLError(.notConnectedToInternet) }
        XCTAssertEqual(result.failed, [newInfo])
        XCTAssertEqual(result.installed, [oldInfo])
        XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent("scph5501.bin")), old)
        XCTAssertEqual(store.installed(), [oldInfo], "still playable offline")
        let new = Data("revision B".utf8)
        _ = try await store.sync([newInfo]) { _ in new }
        XCTAssertEqual(store.installed(), [newInfo])
        XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent("scph5501.bin")), new)
    }

    func testRejectsUnsafeFilenamesAndIDs() async throws {
        let bytes = Data("synthetic".utf8)
        var badID = Self.bios(bytes, "scph5501.bin", .psx)
        badID.id = "../../etc"
        let traversal = Self.bios(bytes, "../escape.bin", .psx)
        let nested = Self.bios(bytes, "dir/scph5501.bin", .psx)
        let result = try await store.sync([badID, traversal, nested]) { _ in bytes }
        XCTAssertEqual(result.installed, [])
        XCTAssertEqual(result.failed.count, 3)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.deletingLastPathComponent().appendingPathComponent("escape.bin").path))
    }

    func testRequiredFileWinsCanonicalNameClash() async throws {
        let required = Data("required".utf8), optional = Data("optional".utf8)
        let list = [Self.bios(optional, "scph5501.bin", .psx, required: false), Self.bios(required, "scph5501.bin", .psx)]
        let served = [list[0].id: optional, list[1].id: required]
        let result = try await store.sync(list) { try XCTUnwrap(served[$0.id]) }
        XCTAssertEqual(result.installed, [list[1]])
        XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent("scph5501.bin")), required)
    }

    func testDiscCountFromFiles() {
        let summary = GameSummary(id: "g", title: "G", system: .psx, year: nil, genre: nil, coverPath: nil, totalSize: 0)
        let files = [
            GameFileInfo(id: "a", filename: "G.m3u", role: .m3u, size: 10, discNumber: nil),
            GameFileInfo(id: "b", filename: "G (Disc 1).cue", role: .cue, size: 20, discNumber: 1),
            GameFileInfo(id: "c", filename: "G (Disc 1).bin", role: .disc, size: 300, discNumber: 1),
            GameFileInfo(id: "d", filename: "G (Disc 2).cue", role: .cue, size: 20, discNumber: 2),
            GameFileInfo(id: "e", filename: "G (Disc 2).bin", role: .disc, size: 400, discNumber: 2),
            GameFileInfo(id: "f", filename: "G (Disc 3).cue", role: .cue, size: 20, discNumber: 3),
        ]
        let detail = GameDetail(game: summary, summary: nil, files: files)
        XCTAssertEqual(detail.discCount, 3)
        XCTAssertEqual(detail.totalFileSize, 770)
        let unnumbered = GameDetail(game: summary, summary: nil, files: files.map { var f = $0; f.discNumber = nil; return f })
        XCTAssertEqual(unnumbered.discCount, 3, "falls back to one disc per cue sheet")
    }
}

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int { lock.withLock { count } }
    func increment() { lock.withLock { count += 1 } }
}
