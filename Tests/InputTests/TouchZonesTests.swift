import XCTest

final class TouchZonesTests: XCTestCase {
    func testDPadEightDirectionsAndDeadZone() {
        let dpad = TouchZone(id: "DPad", frame: CGRect(x: 0, y: 0, width: 100, height: 100), kind: .dpad)
        let center = CGPoint(x: 50, y: 50)
        let cases: [(CGPoint, Set<String>)] = [
            (CGPoint(x: 90, y: 50), ["Right"]),
            (CGPoint(x: 78, y: 22), ["Up", "Right"]),
            (CGPoint(x: 50, y: 10), ["Up"]),
            (CGPoint(x: 22, y: 22), ["Up", "Left"]),
            (CGPoint(x: 10, y: 50), ["Left"]),
            (CGPoint(x: 22, y: 78), ["Down", "Left"]),
            (CGPoint(x: 50, y: 90), ["Down"]),
            (CGPoint(x: 78, y: 78), ["Down", "Right"]),
        ]
        for (point, expected) in cases {
            XCTAssertEqual(TouchZones.controls(at: point, zones: [dpad]), expected)
        }
        XCTAssertTrue(TouchZones.controls(at: center, zones: [dpad]).isEmpty)
        XCTAssertTrue(TouchZones.controls(at: CGPoint(x: 0, y: 0), zones: [dpad]).isEmpty)
    }

    func testButtonAcceptsTouchJustAboveTopEdge() {
        let button = TouchZone(id: "A", frame: CGRect(x: 100, y: 100, width: 40, height: 40), kind: .button)

        XCTAssertEqual(TouchZones.controls(at: CGPoint(x: 120, y: 90), zones: [button]), ["A"])
    }

    func testNearestButtonWinsWhenInflatedRectsOverlap() {
        let first = TouchZone(id: "B", frame: CGRect(x: 0, y: 0, width: 40, height: 40), kind: .button)
        let second = TouchZone(id: "A", frame: CGRect(x: 30, y: 0, width: 40, height: 40), kind: .button)

        XCTAssertEqual(TouchZones.controls(at: CGPoint(x: 45, y: 20), zones: [first, second]), ["A"])
    }

    func testSlidingFromBToAChangesThePressedSet() {
        let buttons = [
            TouchZone(id: "B", frame: CGRect(x: 0, y: 0, width: 40, height: 40), kind: .button),
            TouchZone(id: "A", frame: CGRect(x: 60, y: 0, width: 40, height: 40), kind: .button),
        ]

        XCTAssertEqual(TouchZones.controls(at: CGPoint(x: 20, y: 20), zones: buttons), ["B"])
        XCTAssertEqual(TouchZones.controls(at: CGPoint(x: 80, y: 20), zones: buttons), ["A"])
    }

    func testSimultaneousTouchesUnionTheirControls() {
        let zones = [
            TouchZone(id: "Up", frame: CGRect(x: 0, y: 0, width: 40, height: 40), kind: .button),
            TouchZone(id: "A", frame: CGRect(x: 60, y: 0, width: 40, height: 40), kind: .button),
        ]

        XCTAssertEqual(
            TouchZones.controls(for: [CGPoint(x: 20, y: 20), CGPoint(x: 80, y: 20)], zones: zones),
            ["Up", "A"]
        )
    }
}
