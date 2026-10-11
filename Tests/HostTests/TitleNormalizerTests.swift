import SupersEmuKit
import XCTest

final class TitleNormalizerTests: XCTestCase {
    func testStripsHashPrefixBeforeNormalizingFilename() {
        XCTAssertEqual(
            TitleNormalizer.title(fromFilename: "\(String(repeating: "a", count: 64))--Chrono Trigger (USA).sfc"),
            "Chrono Trigger")
    }

    func testKeepsHexLikeGameTitle() {
        XCTAssertEqual(TitleNormalizer.title(fromFilename: "1942 (USA).sfc"), "1942")
    }
}
