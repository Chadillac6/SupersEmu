import Foundation
import simd

/// A physical control on a gamepad, named by position (south = bottom face button) rather than the printed label.
enum PadInput: String, Codable, CaseIterable, Sendable {
    case dpadUp, dpadDown, dpadLeft, dpadRight
    case south, east, west, north
    case l1, r1, l2, r2, l3, r3
    case start, select, home
    case leftStickUp, leftStickDown, leftStickLeft, leftStickRight
    case rightStickUp, rightStickDown, rightStickLeft, rightStickRight
    case unbound

    var label: String {
        switch self {
        case .dpadUp: "D-pad Up"
        case .dpadDown: "D-pad Down"
        case .dpadLeft: "D-pad Left"
        case .dpadRight: "D-pad Right"
        case .south: "Bottom button"
        case .east: "Right button"
        case .west: "Left button"
        case .north: "Top button"
        case .l1: "Left shoulder"
        case .r1: "Right shoulder"
        case .l2: "Left trigger"
        case .r2: "Right trigger"
        case .l3: "Left stick press"
        case .r3: "Right stick press"
        case .start: "Start / Menu"
        case .select: "Select / Options"
        case .home: "Home / Guide"
        case .leftStickUp: "Left stick Up"
        case .leftStickDown: "Left stick Down"
        case .leftStickLeft: "Left stick Left"
        case .leftStickRight: "Left stick Right"
        case .rightStickUp: "Right stick Up"
        case .rightStickDown: "Right stick Down"
        case .rightStickLeft: "Right stick Left"
        case .rightStickRight: "Right stick Right"
        case .unbound: "Not set"
        }
    }

    var isLeftStick: Bool { [.leftStickUp, .leftStickDown, .leftStickLeft, .leftStickRight].contains(self) }
    var isRightStick: Bool { [.rightStickUp, .rightStickDown, .rightStickLeft, .rightStickRight].contains(self) }
    var isStick: Bool { isLeftStick || isRightStick }
}

/// One controller's state this frame. Sticks are -1...1 with +x right and +y up.
struct PadState: Equatable, Sendable {
    var pressed: Set<PadInput> = []
    var leftStick: SIMD2<Float> = .zero
    var rightStick: SIMD2<Float> = .zero

    /// 0...1: 1 or 0 for buttons, the deflection toward that direction for sticks.
    func value(of input: PadInput) -> Float {
        switch input {
        case .leftStickUp: max(0, leftStick.y)
        case .leftStickDown: max(0, -leftStick.y)
        case .leftStickLeft: max(0, -leftStick.x)
        case .leftStickRight: max(0, leftStick.x)
        case .rightStickUp: max(0, rightStick.y)
        case .rightStickDown: max(0, -rightStick.y)
        case .rightStickLeft: max(0, -rightStick.x)
        case .rightStickRight: max(0, rightStick.x)
        case .unbound: 0
        default: pressed.contains(input) ? 1 : 0
        }
    }

    mutating func merge(_ other: PadState) {
        pressed.formUnion(other.pressed)
        if simd_length(other.leftStick) > simd_length(leftStick) { leftStick = other.leftStick }
        if simd_length(other.rightStick) > simd_length(rightStick) { rightStick = other.rightStick }
    }
}

/// libretro RetroPad button IDs (RETRO_DEVICE_ID_JOYPAD_*), matching SEJoypadButtons bit positions.
enum RetroButton: Int, Codable, Sendable {
    case b = 0, y, select, start, up, down, left, right, a, x, l, r, l2, r2, l3, r3

    var mask: UInt32 { 1 << UInt32(rawValue) }
}

/// What the core sees for one port: RetroPad buttons plus analog sticks in libretro's range (+y down).
struct PadOutput: Equatable, Sendable {
    var buttons: UInt32 = 0
    var leftStick: SIMD2<Int16> = .zero
    var rightStick: SIMD2<Int16> = .zero

    func contains(_ button: RetroButton) -> Bool { buttons & button.mask != 0 }
}
