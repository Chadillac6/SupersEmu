import Foundation
import SupersEmuKit

/// One control on the emulated console's pad and where it goes in the RetroPad the core reads.
struct ConsoleControl: Identifiable, Equatable, Sendable {
    enum Output: Equatable, Sendable {
        case button(RetroButton)
        case analog(AnalogStick, StickDirection)
    }
    enum AnalogStick: Sendable { case left, right }
    enum StickDirection: Sendable { case up, down, left, right }

    let id: String
    let output: Output
    let defaultInput: PadInput
}

/// Consoles that share a pad and touch layout.
enum ControlFamily: Sendable {
    case snes, sega, n64, psx, handheld
}

extension SystemID {
    var controlFamily: ControlFamily {
        switch self {
        case .snes: .snes
        case .genesis, .segacd, .sega32x: .sega
        case .n64: .n64
        case .psx: .psx
        case .gb, .gbc, .gba: .handheld
        }
    }

    var isSegaFamily: Bool { controlFamily == .sega }
}

/// The console's controls with default positional bindings.
struct ConsoleLayout: Equatable, Sendable {
    let system: SystemID
    let title: String
    let controls: [ConsoleControl]
    /// Digital consoles also read the left stick as the d-pad unless something is bound to the stick.
    let leftStickDrivesDpad: Bool

    var defaults: [String: PadInput] {
        Dictionary(uniqueKeysWithValues: controls.map { ($0.id, $0.defaultInput) })
    }

    func control(_ id: String) -> ConsoleControl? { controls.first { $0.id == id } }

    /// Order of the Controls screen's console picker.
    static let systems: [SystemID] = [.snes, .genesis, .n64, .psx, .gba, .gb, .gbc, .segacd, .sega32x]

    static func title(for system: SystemID) -> String {
        switch system {
        case .snes: "Super Nintendo"
        case .gb: "Game Boy"
        case .gbc: "Game Boy Color"
        case .gba: "Game Boy Advance"
        case .genesis: "Genesis"
        case .segacd: "Sega CD"
        case .sega32x: "32X"
        case .psx: "PlayStation"
        case .n64: "Nintendo 64"
        }
    }

    static func forSystem(_ system: SystemID) -> ConsoleLayout {
        let title = title(for: system)
        switch system.controlFamily {
        case .handheld where system == .gba:
            return ConsoleLayout(system: system, title: title, controls: dpad + [
                button("B", .b, .south), button("A", .a, .east), button("L", .l, .l1), button("R", .r, .r1),
                button("Select", .select, .select), button("Start", .start, .start),
            ], leftStickDrivesDpad: true)
        case .handheld:
            return ConsoleLayout(system: system, title: title, controls: dpad + [
                button("B", .b, .south), button("A", .a, .east),
                button("Select", .select, .select), button("Start", .start, .start),
            ], leftStickDrivesDpad: true)
        case .sega:
            // Genesis Plus GX and PicoDrive: RetroPad Y/B/A = A/B/C, L/X/R = X/Y/Z, Select = Mode.
            return ConsoleLayout(system: system, title: title, controls: dpad + [
                button("A", .y, .west), button("B", .b, .south), button("C", .a, .east),
                button("X", .l, .l1), button("Y", .x, .north), button("Z", .r, .r1),
                button("Mode", .select, .select), button("Start", .start, .start),
            ], leftStickDrivesDpad: true)
        case .psx:
            return ConsoleLayout(system: system, title: title, controls: dpad + [
                button("Cross", .b, .south), button("Circle", .a, .east), button("Square", .y, .west), button("Triangle", .x, .north),
                button("L1", .l, .l1), button("R1", .r, .r1), button("L2", .l2, .l2), button("R2", .r2, .r2),
                button("L3", .l3, .l3), button("R3", .r3, .r3),
                button("Select", .select, .select), button("Start", .start, .start),
            ], leftStickDrivesDpad: true)
        case .n64:
            // libretro N64 cores read the stick as the left analog and the C buttons as the right analog;
            // A/B/Z sit on RetroPad B/Y/L2.
            return ConsoleLayout(system: system, title: title, controls: [
                analog("Stick Up", .left, .up, .leftStickUp), analog("Stick Down", .left, .down, .leftStickDown),
                analog("Stick Left", .left, .left, .leftStickLeft), analog("Stick Right", .left, .right, .leftStickRight),
                button("A", .b, .south), button("B", .y, .west), button("Z", .l2, .l2),
                button("L", .l, .l1), button("R", .r, .r1), button("Start", .start, .start),
                analog("C-Up", .right, .up, .rightStickUp), analog("C-Down", .right, .down, .rightStickDown),
                analog("C-Left", .right, .left, .rightStickLeft), analog("C-Right", .right, .right, .rightStickRight),
            ] + dpad, leftStickDrivesDpad: false)
        case .snes:
            return ConsoleLayout(system: system, title: title, controls: dpad + [
                button("B", .b, .south), button("A", .a, .east), button("Y", .y, .west), button("X", .x, .north),
                button("L", .l, .l1), button("R", .r, .r1),
                button("Select", .select, .select), button("Start", .start, .start),
            ], leftStickDrivesDpad: true)
        }
    }

    private static let dpad = [
        button("Up", .up, .dpadUp), button("Down", .down, .dpadDown),
        button("Left", .left, .dpadLeft), button("Right", .right, .dpadRight),
    ]

    private static func button(_ id: String, _ output: RetroButton, _ input: PadInput) -> ConsoleControl {
        ConsoleControl(id: id, output: .button(output), defaultInput: input)
    }

    private static func analog(_ id: String, _ stick: ConsoleControl.AnalogStick, _ direction: ConsoleControl.StickDirection,
                               _ input: PadInput) -> ConsoleControl {
        ConsoleControl(id: id, output: .analog(stick, direction), defaultInput: input)
    }
}
