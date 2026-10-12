import XCTest

final class AutoStateCheckpointTests: XCTestCase {
    func testMoveAsideReplacesPreviousBackup() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let autoState = directory.appendingPathComponent("auto.state")
        let backup = URL(fileURLWithPath: autoState.path + ".before-start-over")
        try Data("old backup".utf8).write(to: backup)
        try Data("current resume point".utf8).write(to: autoState)

        try AutoStateCheckpoint.moveAside(autoState)

        XCTAssertFalse(FileManager.default.fileExists(atPath: autoState.path))
        XCTAssertEqual(try Data(contentsOf: backup), Data("current resume point".utf8))
    }

    func testMoveAsideDoesNothingWhenAutoStateDoesNotExist() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let autoState = directory.appendingPathComponent("auto.state")
        let backup = URL(fileURLWithPath: autoState.path + ".before-start-over")

        try AutoStateCheckpoint.moveAside(autoState)

        XCTAssertFalse(FileManager.default.fileExists(atPath: autoState.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: backup.path))
    }
}
