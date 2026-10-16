import Foundation
import XCTest

final class DiagnosticsLogTests: XCTestCase {
    func testConsecutiveCoreLinesAreCollapsed() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let log = try DiagnosticsLog(title: "Mario Tennis", directory: directory)

        log.appendCoreLog(level: 2, message: "same warning", detailedCoreLogging: false)
        log.appendCoreLog(level: 2, message: "same warning", detailedCoreLogging: false)
        log.appendCoreLog(level: 2, message: "same warning", detailedCoreLogging: false)
        log.stop()

        let contents = try String(contentsOf: log.url, encoding: .utf8)
        XCTAssertTrue(contents.contains("core [WARN] same warning"))
        XCTAssertTrue(contents.contains("core (repeated 2 times)"))
        XCTAssertEqual(contents.components(separatedBy: "core [WARN] same warning").count - 1, 1)
    }

    func testCoreLogsAreCappedAtFiveThousandLines() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let log = try DiagnosticsLog(title: "Cap Test", directory: directory)

        for line in 0..<5_100 {
            log.appendCoreLog(level: 3, message: "line \(line)", detailedCoreLogging: false)
        }
        log.stop()

        let contents = try String(contentsOf: log.url, encoding: .utf8)
        let coreLines = contents.split(separator: "\n").filter { $0.hasPrefix("core ") }
        XCTAssertEqual(coreLines.count, 5_000)
        XCTAssertTrue(contents.contains("core [ERROR] line 4999"))
        XCTAssertFalse(contents.contains("core [ERROR] line 5000"))
    }

    func testRetentionKeepsNewestTwentyLogs() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let now = Date()
        for index in 0..<21 {
            let url = directory.appendingPathComponent(String(format: "%02d.log", index))
            FileManager.default.createFile(atPath: url.path, contents: Data())
            try FileManager.default.setAttributes(
                [.modificationDate: now.addingTimeInterval(TimeInterval(index))],
                ofItemAtPath: url.path)
        }

        DiagnosticsLog.retainNewestLogs(in: directory)

        let retained = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        XCTAssertEqual(retained.count, 20)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("00.log").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.appendingPathComponent("20.log").path))
    }

    private func makeDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}
