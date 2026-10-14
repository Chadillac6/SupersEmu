import CoreGraphics
import Foundation
import ImageIO
import XCTest

final class SaveSlotStoreTests: XCTestCase {
    private var directory: URL!
    private var store: SaveSlotStore!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("save-slots-\(UUID().uuidString)", isDirectory: true)
        store = SaveSlotStore(directory: directory)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    func testSaveWritesStateMetadataScreenshotAndListsDate() throws {
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let png = try makePNG()
        try store.save(into: 1, savedAt: date, screenshotPNG: png) { try Data("one".utf8).write(to: $0) }

        XCTAssertEqual(try Data(contentsOf: store.stateURL(1)), Data("one".utf8))
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.appendingPathComponent("slot1.json").path))
        XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent("slot1.png")), png)
        XCTAssertEqual(store.slots()[0], SaveSlotInfo(slot: 1, savedAt: date, screenshotURL: directory.appendingPathComponent("slot1.png")))
    }

    func testSaveOccupiedThrowsWithoutChangingExistingSlot() throws {
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let png = try makePNG()
        try store.save(into: 1, savedAt: date, screenshotPNG: png) { try Data("old".utf8).write(to: $0) }
        let oldState = try Data(contentsOf: store.stateURL(1))
        let oldMetadata = try Data(contentsOf: directory.appendingPathComponent("slot1.json"))
        let oldPNG = try Data(contentsOf: directory.appendingPathComponent("slot1.png"))
        let oldDate = try XCTUnwrap(store.slots()[0].savedAt)

        XCTAssertThrowsError(try store.save(into: 1, savedAt: date.addingTimeInterval(60), screenshotPNG: nil) {
            try Data("new".utf8).write(to: $0)
        }) { XCTAssertEqual($0 as? SaveSlotError, .occupied(1)) }
        XCTAssertEqual(try Data(contentsOf: store.stateURL(1)), oldState)
        XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent("slot1.json")), oldMetadata)
        XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent("slot1.png")), oldPNG)
        XCTAssertEqual(store.slots()[0].savedAt, oldDate)
    }

    func testOverwriteReplacesStateDateAndScreenshot() throws {
        let oldDate = Date(timeIntervalSince1970: 1_700_000_000)
        let newDate = oldDate.addingTimeInterval(120)
        try store.save(into: 2, savedAt: oldDate, screenshotPNG: try makePNG()) {
            try Data("old".utf8).write(to: $0)
        }
        let newPNG = try makePNG(color: (0, 1, 0, 1))
        try store.overwrite(2, savedAt: newDate, screenshotPNG: newPNG) { try Data("new".utf8).write(to: $0) }

        XCTAssertEqual(try Data(contentsOf: store.stateURL(2)), Data("new".utf8))
        XCTAssertEqual(store.slots()[1].savedAt, newDate)
        XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent("slot2.png")), newPNG)
    }

    func testOverwriteMetadataStageFailureLeavesExistingSlotUntouched() throws {
        let oldDate = Date(timeIntervalSince1970: 1_700_000_000)
        let newDate = oldDate.addingTimeInterval(120)
        let oldPNG = try makePNG()
        try store.save(into: 1, savedAt: oldDate, screenshotPNG: oldPNG) {
            try Data("old".utf8).write(to: $0)
        }
        let oldState = try Data(contentsOf: store.stateURL(1))
        let screenshot = directory.appendingPathComponent("slot1.png")
        let metadataTemporary = directory.appendingPathComponent("slot1.json.tmp", isDirectory: true)
        try FileManager.default.createDirectory(at: metadataTemporary, withIntermediateDirectories: true)
        try Data("blocker".utf8).write(to: metadataTemporary.appendingPathComponent("blocker"))

        XCTAssertThrowsError(try store.overwrite(1, savedAt: newDate, screenshotPNG: try makePNG(color: (0, 1, 0, 1))) {
            try Data("new".utf8).write(to: $0)
        })

        XCTAssertEqual(try Data(contentsOf: store.stateURL(1)), oldState)
        XCTAssertEqual(store.slots()[0].savedAt, oldDate)
        XCTAssertEqual(store.slots()[0].screenshotURL, screenshot)
        XCTAssertEqual(try Data(contentsOf: screenshot), oldPNG)
    }

    func testScreenshotStageFailureKeepsStateSaveAndOmitsScreenshot() throws {
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let screenshotTemporary = directory.appendingPathComponent("slot1.png.tmp", isDirectory: true)
        try FileManager.default.createDirectory(at: screenshotTemporary, withIntermediateDirectories: true)
        try Data("blocker".utf8).write(to: screenshotTemporary.appendingPathComponent("blocker"))

        try store.save(into: 1, savedAt: date, screenshotPNG: try makePNG()) {
            try Data("new".utf8).write(to: $0)
        }

        XCTAssertEqual(try Data(contentsOf: store.stateURL(1)), Data("new".utf8))
        XCTAssertEqual(store.slots()[0].savedAt, date)
        XCTAssertNil(store.slots()[0].screenshotURL)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("slot1.png").path))
    }

    func testLegacySlotAndUnmatchedMetadataUseFileModificationDate() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let state = store.stateURL(1)
        try Data("legacy".utf8).write(to: state)
        let date = Date(timeIntervalSince1970: 1_600_000_000)
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: state.path)
        let slots = store.slots()
        XCTAssertEqual(slots[0].savedAt, date)
        XCTAssertNil(slots[0].screenshotURL)
        XCTAssertTrue(slots[1].isEmpty)
        XCTAssertTrue(slots[2].isEmpty)

        try store.save(into: 2, savedAt: date, screenshotPNG: try makePNG()) { try Data("old".utf8).write(to: $0) }
        try Data("sync-download".utf8).write(to: store.stateURL(2), options: .atomic)
        let changed = store.slots()[1]
        XCTAssertEqual(changed.savedAt, (try FileManager.default.attributesOfItem(atPath: store.stateURL(2).path)[.modificationDate]) as? Date)
        XCTAssertNil(changed.screenshotURL)
    }

    func testRecordRemoteUsesDateAndDropsStaleScreenshot() throws {
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        try store.save(into: 3, savedAt: date.addingTimeInterval(-1), screenshotPNG: try makePNG()) {
            try Data("remote".utf8).write(to: $0)
        }
        let remoteDate = date.addingTimeInterval(60)
        store.recordRemote(3, savedAt: remoteDate)
        XCTAssertEqual(store.slots()[2].savedAt, remoteDate)
        XCTAssertNil(store.slots()[2].screenshotURL)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("slot3.png").path))
    }

    func testDeleteClearsStateMetadataScreenshot() throws {
        try store.save(into: 1, savedAt: Date(), screenshotPNG: try makePNG()) {
            try Data("state".utf8).write(to: $0)
        }
        try store.delete(1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.stateURL(1).path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("slot1.json").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("slot1.png").path))
        XCTAssertTrue(store.slots()[0].isEmpty)
    }

    func testLineSlotNamesAndPNGDataRoundTrip() throws {
        XCTAssertEqual((1...3).map(SaveSlotStore.lineSlot), ["slot1", "slot2", "slot3"])
        let png = try makePNG()
        let source = try XCTUnwrap(CGImageSourceCreateWithData(png as CFData, nil))
        let decoded = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        XCTAssertEqual(decoded.width, 2)
        XCTAssertEqual(decoded.height, 2)
    }

    private func makePNG(color: (CGFloat, CGFloat, CGFloat, CGFloat) = (1, 0, 0, 1)) throws -> Data {
        let space = CGColorSpaceCreateDeviceRGB()
        let context = try XCTUnwrap(CGContext(data: nil, width: 2, height: 2, bitsPerComponent: 8, bytesPerRow: 8,
                                              space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(red: color.0, green: color.1, blue: color.2, alpha: color.3)
        context.fill(CGRect(x: 0, y: 0, width: 2, height: 2))
        return try XCTUnwrap(SaveSlotStore.pngData(from: XCTUnwrap(context.makeImage())))
    }
}
