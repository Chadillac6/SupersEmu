import XCTest
import SupersEmuKit

/// The offline banner's "N more are unavailable" must count exactly the games Home hides offline.
final class OfflineUnavailableCountTests: XCTestCase {
    func testPS2OnlyLibraryHasNothingUnavailableOnIOS() {
        let library = LibraryShelves.visible([cloudOnly("ps2-a", .ps2), cloudOnly("ps2-b", .ps2)], on: .iOS)

        XCTAssertEqual(LibraryShelves.offlineUnavailableCount(library), 0)
        assertMatchesHome(library)
    }

    func testPS2OnlyLibraryCountsOnMacWithThePS2Core() {
        let library = LibraryShelves.visible([cloudOnly("ps2-a", .ps2), cloudOnly("ps2-b", .ps2)], on: .mac)

        XCTAssertEqual(LibraryShelves.offlineUnavailableCount(library), DevicePlatform.hasPS2Core ? 2 : 0)
        assertMatchesHome(library)
    }

    func testLocallyCopiedServerGamesAreNotUnavailable() {
        let library = LibraryShelves.visible([localCopy("snes", .snes), localCopy("gba", .gba)], on: .iOS)

        XCTAssertEqual(LibraryShelves.offlineUnavailableCount(library), 0)
        assertMatchesHome(library)
    }

    func testMixedLibraryCountsOnlyCloudOnlyGamesThisDeviceShows() {
        let library = LibraryShelves.visible([
            cloudOnly("ps2", .ps2),
            cloudOnly("snes", .snes),
            cloudOnly("dreamcast", .dreamcast),
            downloaded("gba", .gba),
            localCopy("n64", .n64),
            localOnly("genesis", .genesis),
        ], on: .iOS)

        XCTAssertEqual(LibraryShelves.offlineUnavailableCount(library), 2, "SNES and Dreamcast need the server")
        assertMatchesHome(library)
    }

    func testDuplicateEntriesCountOnce() {
        let library = LibraryShelves.visible([cloudOnly("snes", .snes), cloudOnly("snes", .snes)], on: .iOS)

        XCTAssertEqual(LibraryShelves.offlineUnavailableCount(library), 1)
        assertMatchesHome(library)
    }

    private func assertMatchesHome(_ library: [LibraryItem], file: StaticString = #filePath, line: UInt = #line) {
        let shownOffline = LibraryShelves.home(library, system: nil, online: false).allGames.count
        let shownOnline = LibraryShelves.home(library, system: nil, online: true).allGames.count
        XCTAssertEqual(LibraryShelves.offlineUnavailableCount(library), shownOnline - shownOffline,
                       "Offline banner count should be the games Home hides offline", file: file, line: line)
    }

    private func cloudOnly(_ id: String, _ system: SystemID) -> LibraryItem {
        item(id, system, source: .server, isDownloaded: false, playable: false)
    }

    private func downloaded(_ id: String, _ system: SystemID) -> LibraryItem {
        item(id, system, source: .server, isDownloaded: true, playable: true)
    }

    /// A server game this device also imported, playable from the local file without downloading.
    private func localCopy(_ id: String, _ system: SystemID) -> LibraryItem {
        item(id, system, source: .server, isDownloaded: false, playable: true, hasLocalCopy: true)
    }

    private func localOnly(_ id: String, _ system: SystemID) -> LibraryItem {
        item(id, system, source: .local, isDownloaded: true, playable: true)
    }

    private func item(_ id: String, _ system: SystemID, source: LibraryItem.Source, isDownloaded: Bool,
                      playable: Bool, hasLocalCopy: Bool = false) -> LibraryItem {
        let game = Game(id: id, title: id, fileURL: URL(fileURLWithPath: "/tmp/\(id)"), console: system.rawValue,
                        hasResumePoint: false)
        return LibraryItem(id: id, title: id, console: system.rawValue, system: system, year: nil, genre: nil,
                           coverPath: nil, size: 0, addedAt: nil, source: source, isDownloaded: isDownloaded,
                           playable: playable ? game : nil, lastPlayed: nil, hasLocalCopy: hasLocalCopy)
    }
}
