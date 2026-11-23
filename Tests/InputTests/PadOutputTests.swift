import XCTest

final class PadOutputTests: XCTestCase {
    func testDiscPickerCanReadAnAssignedPadWhenPlayerOneIsEmpty() {
        let laterPlayer = PadOutput(buttons: RetroButton.down.mask | RetroButton.start.mask)
        let previous = Array(repeating: PadOutput(), count: 4)
        let ports = [PadOutput(), PadOutput(), laterPlayer, PadOutput()]
        XCTAssertEqual(PadOutput.newlyPressedButtons(from: previous, to: ports), laterPlayer.buttons)
    }

    func testSecondPadCanPressSelectWhileFirstPadAlreadyHoldsIt() {
        let select = PadOutput(buttons: RetroButton.select.mask)
        let previous = [select, PadOutput()]
        let current = [select, select]
        XCTAssertEqual(PadOutput.newlyPressedButtons(from: previous, to: current), select.buttons)
        XCTAssertEqual(PadOutput.newlyPressedButtons(from: current, to: current), 0)
    }
}
