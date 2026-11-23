import XCTest

final class ControllerAssignmentsTests: XCTestCase {
    func testNewControllersFillOpenPortsInConnectionOrder() {
        var assignments = ControllerAssignments(portCount: 4)
        assignments.update(connectedIDs: ["a", "b"])
        XCTAssertEqual(assignments.slots, ["a", "b", nil, nil])

        assignments.update(connectedIDs: ["b", "a", "c", "d", "extra"])
        XCTAssertEqual(assignments.slots, ["a", "b", "c", "d"])
    }

    func testAssigningPadsSwapsOccupiedPortsOrMovesIntoAnEmptyPort() {
        var assignments = ControllerAssignments(portCount: 4)
        assignments.update(connectedIDs: ["a", "b"])

        assignments.assign("b", to: 0)
        XCTAssertEqual(assignments.slots, ["b", "a", nil, nil])

        assignments.assign("b", to: 3)
        XCTAssertEqual(assignments.slots, [nil, "a", nil, "b"])
    }

    func testDisconnectDoesNotShiftOtherPlayers() {
        var assignments = ControllerAssignments(portCount: 4)
        assignments.update(connectedIDs: ["a", "b", "c"])
        assignments.assign("c", to: 0)

        assignments.update(connectedIDs: ["a", "b"])
        XCTAssertEqual(assignments.slots, [nil, "b", "a", nil])

        assignments.update(connectedIDs: ["a", "b", "d"])
        XCTAssertEqual(assignments.slots, ["d", "b", "a", nil])
    }

    func testUnassignedPadStaysAvailableButIsNotAutoAssignedAgain() {
        var assignments = ControllerAssignments(portCount: 2)
        assignments.update(connectedIDs: ["a", "b", "extra"])
        assignments.assign(nil, to: 0)

        assignments.update(connectedIDs: ["a", "b", "extra"])
        XCTAssertEqual(assignments.slots, [nil, "b"])

        assignments.assign("extra", to: 1)
        XCTAssertEqual(assignments.slots, [nil, "extra"])
        assignments.assign("b", to: 0)
        XCTAssertEqual(assignments.slots, ["b", "extra"])
    }

    func testInvalidSelectionsDoNotAffectExistingAssignments() {
        var assignments = ControllerAssignments(portCount: 2)
        assignments.update(connectedIDs: ["a"])
        assignments.assign("unknown", to: 0)
        assignments.assign("a", to: 2)
        assignments.assign("a", to: 0)
        XCTAssertEqual(assignments.slots, ["a", nil])
    }
}
