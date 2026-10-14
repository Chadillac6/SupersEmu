import XCTest

final class SaveSlotNavigatorTests: XCTestCase {
    func testEmptySlotSouthSavesImmediately() {
        var navigator = SaveSlotNavigator()
        navigator.row = 1
        XCTAssertEqual(navigator.handle([.south], occupied: [true, false, true]), .save(2))
    }

    func testOccupiedActionsAskForConfirmation() {
        for action in [SaveSlotAction.load, .overwrite, .delete] {
            var navigator = SaveSlotNavigator()
            XCTAssertNil(navigator.activate(row: 0, action: action, occupied: [true, false, false]))
            XCTAssertEqual(navigator.confirmation, SaveSlotConfirmation(action: action, slot: 1))
        }
    }

    func testConfirmationNavigationNeverMovesRowsAndSouthCancelsByDefault() {
        var navigator = SaveSlotNavigator(row: 1, column: 2, confirmation: SaveSlotConfirmation(action: .delete, slot: 2))
        XCTAssertNil(navigator.handle([.dpadDown, .dpadUp], occupied: [true, true, false]))
        XCTAssertEqual(navigator.row, 1)
        XCTAssertEqual(navigator.column, 2)
        XCTAssertNil(navigator.handle([.south], occupied: [true, true, false]))
        XCTAssertNil(navigator.confirmation)
    }

    func testConfirmationRightThenSouthConfirmsAndEastCancels() {
        var navigator = SaveSlotNavigator(confirmation: SaveSlotConfirmation(action: .load, slot: 3))
        XCTAssertNil(navigator.handle([.dpadRight], occupied: [false, false, true]))
        XCTAssertEqual(navigator.handle([.south], occupied: [false, false, true]), .load(3))
        XCTAssertNil(navigator.confirmation)

        navigator.confirmation = SaveSlotConfirmation(action: .delete, slot: 1)
        XCTAssertNil(navigator.handle([.east], occupied: [true, false, false]))
        XCTAssertNil(navigator.confirmation)

        navigator.confirmation = SaveSlotConfirmation(action: .delete, slot: 1, confirmFocused: true)
        XCTAssertNil(navigator.handle([.east, .south], occupied: [true, false, false]))
        XCTAssertNil(navigator.confirmation)
    }

    func testEastClosesWithoutConfirmationAndColumnClamps() {
        var navigator = SaveSlotNavigator(row: 0, column: 2)
        XCTAssertNil(navigator.handle([.dpadDown], occupied: [true, false, true]))
        XCTAssertEqual(navigator.row, 1)
        XCTAssertEqual(navigator.column, 0)
        XCTAssertEqual(navigator.handle([.east], occupied: [true, false, true]), .close)
    }

    func testSaveActivationOnOccupiedSlotRoutesToOverwriteConfirmation() {
        var navigator = SaveSlotNavigator()
        XCTAssertNil(navigator.activate(row: 0, action: .save, occupied: [true, false, false]))
        XCTAssertEqual(navigator.confirmation, SaveSlotConfirmation(action: .overwrite, slot: 1))
    }

    func testResetPrefersEmptyOrOccupiedSlot() {
        var navigator = SaveSlotNavigator(row: 2, column: 1)
        navigator.reset(occupied: [true, false, true], preferEmpty: true)
        XCTAssertEqual(navigator.row, 1)
        navigator.reset(occupied: [false, false, true], preferEmpty: false)
        XCTAssertEqual(navigator.row, 2)
    }
}
