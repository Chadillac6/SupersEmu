import XCTest

final class PadOutputTests: XCTestCase {
    func testDiscPickerCanReadAnAssignedPadWhenPlayerOneIsEmpty() {
        let laterPlayer = PadOutput(buttons: RetroButton.down.mask | RetroButton.start.mask)
        let ports = [PadOutput(), PadOutput(), laterPlayer, PadOutput()]
        XCTAssertEqual(PadOutput.combinedButtons(ports), laterPlayer.buttons)
    }
}
