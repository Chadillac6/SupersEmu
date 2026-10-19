import XCTest
import SupersEmuKit

final class TouchControlSizingTests: XCTestCase {
    func testSNESPortraitScaleFits402PointWidth() {
        let requiredWidth = TouchControlSizing.requiredPortraitWidth(system: .snes)
        let scale = TouchControlSizing.portraitScale(availableWidth: 402, requiredWidth: requiredWidth)

        XCTAssertTrue((0.75...1.3).contains(scale))
        XCTAssertLessThanOrEqual(requiredWidth * scale, 402 - 24)
    }

    func testPortraitScaleCapsAt1Point3For750PointWidth() {
        let requiredWidth = TouchControlSizing.requiredPortraitWidth(system: .snes)

        XCTAssertEqual(TouchControlSizing.portraitScale(availableWidth: 750, requiredWidth: requiredWidth), 1.3)
    }

    func testPortraitControlsFitAllSystemsAt402Points() {
        for system in SystemID.allCases {
            let requiredWidth = TouchControlSizing.requiredPortraitWidth(system: system)
            let scale = TouchControlSizing.portraitScale(availableWidth: 402, requiredWidth: requiredWidth)

            XCTAssertTrue(
                requiredWidth * scale <= 402 - 24 + 0.001 || scale == 0.75,
                "\(system) controls should fit at 402 points or use the minimum scale"
            )
        }
    }
}
