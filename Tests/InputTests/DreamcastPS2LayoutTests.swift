import XCTest
import SupersEmuKit

final class DreamcastPS2LayoutTests: XCTestCase {
    private let dreamcast = ConsoleLayout.forSystem(.dreamcast)
    private let ps2 = ConsoleLayout.forSystem(.ps2)

    func testNewSystemsHaveTheirOwnFamilies() {
        XCTAssertEqual(SystemID.dreamcast.controlFamily, .dreamcast)
        XCTAssertEqual(SystemID.ps2.controlFamily, .ps2)
        XCTAssertFalse(SystemID.dreamcast.isSegaFamily, "HID presets for Genesis pads shouldn't apply to Dreamcast")
    }

    func testDreamcastFaceButtonsAndTriggersMatchFlycast() {
        // Flycast reads RetroPad B/A/Y/X as Dreamcast A/B/X/Y and L2/R2 as the triggers.
        let state = PadState(pressed: [.south, .east, .west, .north, .l2, .r2, .start])
        let output = InputMapper.output(for: state, layout: dreamcast, bindings: dreamcast.defaults)
        let expected: [RetroButton] = [.b, .a, .y, .x, .l2, .r2, .start]
        XCTAssertEqual(output.buttons, expected.reduce(0) { $0 | $1.mask })
        XCTAssertEqual(dreamcast.control("A")?.output, .button(.b))
        XCTAssertEqual(dreamcast.control("Y")?.output, .button(.x))
        XCTAssertNil(dreamcast.control("Select"), "the Dreamcast pad has no Select")
    }

    func testDreamcastStickIsAnalogAndSeparateFromTheDpad() {
        let output = InputMapper.output(for: PadState(leftStick: [1, 0.5]), layout: dreamcast, bindings: dreamcast.defaults)
        XCTAssertEqual(output.leftStick, SIMD2(32767, -16384))
        XCTAssertEqual(output.buttons, 0, "the stick doesn't also press the d-pad")
        let dpad = InputMapper.output(for: PadState(pressed: [.dpadUp]), layout: dreamcast, bindings: dreamcast.defaults)
        XCTAssertEqual(dpad.buttons, RetroButton.up.mask)
        XCTAssertEqual(dpad.leftStick, .zero)
    }

    func testPS2IsAFullDualShock2() {
        let ids = Set(ps2.controls.map(\.id))
        for id in ["Up", "Down", "Left", "Right", "Cross", "Circle", "Square", "Triangle", "L1", "R1", "L2", "R2", "L3", "R3",
                   "Select", "Start", "Left Stick Up", "Left Stick Right", "Right Stick Up", "Right Stick Left"] {
            XCTAssertTrue(ids.contains(id), id)
        }
        let state = PadState(pressed: [.south, .east, .west, .north, .l1, .r1, .l2, .r2, .l3, .r3, .select, .start],
                             leftStick: [-1, 0], rightStick: [0, 1])
        let output = InputMapper.output(for: state, layout: ps2, bindings: ps2.defaults)
        let expected: [RetroButton] = [.b, .a, .y, .x, .l, .r, .l2, .r2, .l3, .r3, .select, .start]
        XCTAssertEqual(output.buttons, expected.reduce(0) { $0 | $1.mask })
        XCTAssertEqual(output.leftStick, SIMD2(-32767, 0))
        XCTAssertEqual(output.rightStick, SIMD2(0, -32767), "libretro +y is down")
    }

    func testKeyboardArrowsDriveTheStickAndTFGHTheDpad() {
        let mappings = InputMappings()
        for (layout, stick) in [(dreamcast, "Stick"), (ps2, "Left Stick")] {
            let bindings = mappings.bindings(for: layout, controllerType: ControllerType.keyboard, gameID: nil)
            XCTAssertEqual(bindings["\(stick) Up"], .dpadUp)
            XCTAssertEqual(bindings["Up"], .leftStickUp)
            let arrows = InputMapper.output(for: PadState(pressed: [.dpadRight]), layout: layout, bindings: bindings)
            XCTAssertEqual(arrows.leftStick, SIMD2(32767, 0))
            XCTAssertEqual(arrows.buttons, 0)
            let tfgh = InputMapper.output(for: PadState(pressed: [.leftStickDown]), layout: layout, bindings: bindings)
            XCTAssertEqual(tfgh.buttons, RetroButton.down.mask)
            XCTAssertEqual(tfgh.leftStick, .zero)
        }
        let pad = mappings.bindings(for: dreamcast, controllerType: "gc:Gamepad:8BitDo", gameID: nil)
        XCTAssertEqual(pad["Up"], .dpadUp, "gamepads keep the console defaults")
    }

    func testControlsPickerListsNewConsolesAndHidesPS2OnIOS() {
        XCTAssertEqual(ConsoleLayout.systems, [.snes, .genesis, .n64, .psx, .dreamcast, .ps2, .gba, .gb, .gbc, .segacd, .sega32x])
        XCTAssertEqual(Set(ConsoleLayout.systems), Set(SystemID.allCases), "every console is in the picker")
        XCTAssertEqual(ConsoleLayout.systems(on: .mac), ConsoleLayout.systems.filter { $0 != .ps2 || DevicePlatform.hasPS2Core })
        XCTAssertFalse(ConsoleLayout.systems(on: .iOS).contains(.ps2))
        XCTAssertTrue(ConsoleLayout.systems(on: .iOS).contains(.dreamcast))
    }

    func testAvailabilityRule() {
        for system in SystemID.allCases {
            let expected: SystemAvailability = system == .ps2 && !DevicePlatform.hasPS2Core ? .hidden : .available
            XCTAssertEqual(system.availability(on: .mac), expected, "\(system) on Mac")
        }
        XCTAssertEqual(SystemID.dreamcast.availability(on: .iOS), .beta)
        XCTAssertTrue(SystemID.dreamcast.isShown(on: .iOS))
        XCTAssertTrue(SystemID.dreamcast.isBeta(on: .iOS))
        XCTAssertEqual(SystemID.ps2.availability(on: .iOS), .hidden)
        XCTAssertFalse(SystemID.ps2.isShown(on: .iOS))
        for system in SystemID.allCases where ![.dreamcast, .ps2].contains(system) {
            XCTAssertEqual(system.availability(on: .iOS), .available, "\(system) on iOS")
        }
        #if os(macOS)
        XCTAssertEqual(DevicePlatform.current, .mac)
        #else
        XCTAssertEqual(DevicePlatform.current, .iOS)
        XCTAssertFalse(DevicePlatform.hasPS2Core, "LRPS2 is Mac-only")
        #endif
    }

    func testDreamcastTouchControlsFitA402PointPhone() {
        let required = TouchControlSizing.requiredPortraitWidth(system: .dreamcast)
        let scale = TouchControlSizing.portraitScale(availableWidth: 402, requiredWidth: required)
        XCTAssertGreaterThanOrEqual(scale, 1)
        XCTAssertLessThanOrEqual(required * scale, 402 - 24 + 0.001)
    }
}
