import XCTest

/// Synthetic descriptors and reports. No real controller is attached on the CI/VM Mac.
final class HIDReportTests: XCTestCase {
    /// DragonRise 0079:0011 layout per the fixed descriptor in Linux hid-dr.c: 3 constant bytes, X and Y
    /// (8-bit), 4 padding bits, 10 one-bit buttons, 10 constant bits.
    private let dragonRiseSNES: [UInt8] = [
        0x05, 0x01, 0x09, 0x04, 0xA1, 0x01,
        0xA1, 0x02,
        0x75, 0x08, 0x95, 0x03, 0x15, 0x00, 0x26, 0xFF, 0x00, 0x81, 0x01,  // 3 constant bytes
        0x75, 0x08, 0x95, 0x02, 0x09, 0x30, 0x09, 0x31, 0x81, 0x02,        // X, Y
        0x75, 0x04, 0x95, 0x01, 0x81, 0x01,                                // padding
        0x75, 0x01, 0x95, 0x0A, 0x25, 0x01, 0x05, 0x09, 0x19, 0x01, 0x29, 0x0A, 0x81, 0x02,  // buttons 1-10
        0x75, 0x01, 0x95, 0x0A, 0x81, 0x01,                                // padding
        0xC0, 0xC0,
    ]

    /// Typical DragonRise 0079:0006 twin-stick board (Retrolink N64): report ID 1, X Y Z Rz, 4-bit hat, 12 buttons.
    private let twinStick: [UInt8] = [
        0x05, 0x01, 0x09, 0x04, 0xA1, 0x01, 0x85, 0x01,
        0x15, 0x00, 0x26, 0xFF, 0x00, 0x75, 0x08, 0x95, 0x04,
        0x09, 0x30, 0x09, 0x31, 0x09, 0x32, 0x09, 0x35, 0x81, 0x02,
        0x15, 0x00, 0x25, 0x07, 0x35, 0x00, 0x46, 0x3B, 0x01, 0x65, 0x14, 0x75, 0x04, 0x95, 0x01,
        0x09, 0x39, 0x81, 0x42,
        0x65, 0x00, 0x05, 0x09, 0x19, 0x01, 0x29, 0x0C, 0x15, 0x00, 0x25, 0x01, 0x75, 0x01, 0x95, 0x0C, 0x81, 0x02,
        0xC0,
    ]

    func testParsesElementsAndOffsets() {
        let descriptor = HIDReportDescriptor(dragonRiseSNES)
        XCTAssertFalse(descriptor.usesReportIDs)
        let x = descriptor.elements.first { $0.usage == HIDUsage.x }
        XCTAssertEqual(x?.bitOffset, 24)
        XCTAssertEqual(x?.bitSize, 8)
        let buttons = descriptor.elements.filter { $0.usagePage == HIDUsage.button }
        XCTAssertEqual(buttons.map(\.usage), Array(1...10))
        XCTAssertEqual(buttons.first?.bitOffset, 44)
    }

    func testDecodesButtonsAndAxisDpad() throws {
        let descriptor = HIDReportDescriptor(dragonRiseSNES)
        // X = 0 (left), Y = 0xFF (down); buttons start at bit 44: button 2 is byte 5 bit 5, button 10 is byte 6 bit 5.
        let report: [UInt8] = [0x01, 0x7F, 0x7F, 0x00, 0xFF, 0x20, 0x20, 0x00]
        let decoded = try XCTUnwrap(descriptor.decode(report))
        XCTAssertEqual(decoded.buttons, [2, 10])
        XCTAssertEqual(decoded.axes[HIDUsage.x], -1)
        XCTAssertEqual(decoded.axes[HIDUsage.y], 1)

        let state = HIDPreset.retrolinkSNES.state(from: decoded)
        XCTAssertEqual(state.pressed, [.east, .start, .dpadLeft, .dpadDown])
    }

    func testDecodesHatAndReportID() throws {
        let descriptor = HIDReportDescriptor(twinStick)
        XCTAssertTrue(descriptor.usesReportIDs)
        // ID 1; X right, Y up, Z/Rz centred; hat 2 (right) in the low nibble; buttons 1 (C-Up), 7 (A), 8 (Z).
        let report: [UInt8] = [0x01, 0xFF, 0x00, 0x80, 0x80, 0x12, 0x0C, 0x00]
        let decoded = try XCTUnwrap(descriptor.decode(report))
        XCTAssertEqual(decoded.hat, 2)
        XCTAssertEqual(decoded.buttons, [1, 7, 8])
        XCTAssertNil(descriptor.decode([0x02, 0, 0, 0, 0, 0, 0, 0]), "unknown report IDs are ignored")

        let state = HIDPreset.retrolinkN64.state(from: decoded)
        XCTAssertEqual(state.pressed, [.dpadRight, .south, .l2])
        XCTAssertEqual(state.leftStick.x, 1)
        XCTAssertEqual(state.leftStick.y, 1, "HID Y grows down; PadState is +y up")
        XCTAssertEqual(state.rightStick.y, 1, "C-Up is right stick up")
    }

    func testCentredHatAndDeadzone() throws {
        let decoded = try XCTUnwrap(HIDReportDescriptor(twinStick).decode([0x01, 0x82, 0x7C, 0x80, 0x80, 0x0F, 0x00]))
        XCTAssertNil(decoded.hat, "8 (out of range) means centred")
        let state = HIDPreset.generic.state(from: decoded)
        XCTAssertEqual(state, PadState())
    }

    func testSignedAxes() throws {
        let descriptor: [UInt8] = [
            0x05, 0x01, 0x09, 0x05, 0xA1, 0x01,
            0x16, 0x00, 0x80, 0x26, 0xFF, 0x7F, 0x75, 0x10, 0x95, 0x01, 0x09, 0x30, 0x81, 0x02,
            0xC0,
        ]
        let parsed = HIDReportDescriptor(descriptor)
        XCTAssertEqual(parsed.elements.first?.logicalMin, -32768)
        XCTAssertEqual(parsed.decode([0x00, 0x80])?.axes[HIDUsage.x], -1)
        XCTAssertEqual(parsed.decode([0xFF, 0x7F])?.axes[HIDUsage.x], 1)
    }

    func testPresetMatching() {
        XCTAssertEqual(HIDPreset.match(vendorID: 0x0079, productID: 0x0006, productName: "Generic   USB  Joystick  ",
                                       userChoice: nil, console: "snes").id, "retrolink-n64")
        XCTAssertEqual(HIDPreset.match(vendorID: 0x0079, productID: 0x0011, productName: "USB Gamepad ",
                                       userChoice: nil, console: "segacd").id, "retrolink-genesis")
        XCTAssertEqual(HIDPreset.match(vendorID: 0x0079, productID: 0x0011, productName: "USB Gamepad ",
                                       userChoice: nil, console: "snes").id, "retrolink-snes")
        XCTAssertEqual(HIDPreset.match(vendorID: 0x0079, productID: 0x0011, productName: "SEGA Genesis pad",
                                       userChoice: nil, console: "snes").id, "retrolink-genesis")
        XCTAssertEqual(HIDPreset.match(vendorID: 0x0079, productID: 0x0011, productName: nil,
                                       userChoice: "generic", console: "genesis").id, "generic")
        XCTAssertEqual(HIDPreset.match(vendorID: 0x1234, productID: 0x5678, productName: "Mystery pad",
                                       userChoice: nil, console: "n64").id, "generic")
        XCTAssertEqual(HIDPreset.retrolinkGenesis.source, .unverified)
    }
}
