import Foundation
import SupersEmuKit

/// How a generic USB pad's HID buttons, hat and axes land on physical positions.
struct HIDPreset: Identifiable, Equatable, Sendable {
    enum Source: String, Sendable {
        /// From RetroArch's joypad autoconfig or SDL's controller database; not checked on hardware by us.
        case community
        /// Our best guess; nobody has confirmed the IDs or the button order.
        case unverified
        case generic
    }
    enum AxisRole: Equatable, Sendable {
        case leftX, leftY, rightX, rightY
        /// Pads whose d-pad reports as an X/Y axis pair (no hat).
        case dpadX, dpadY
    }

    let id: String
    let name: String
    /// Console the pad was built for; picks between presets that share IDs.
    let console: SystemID?
    let vendorID: Int?
    let productID: Int?
    /// Lowercased product-string fragments that identify the pad when IDs are shared.
    let nameHints: [String]
    let source: Source
    /// 1-based HID button usage -> position.
    let buttons: [Int: PadInput]
    let axes: [UInt16: AxisRole]

    var isVerified: Bool { source == .community }

    /// HID Y axes grow downwards; PadState sticks are +y up.
    func state(from report: HIDGamepadReport) -> PadState {
        var state = PadState()
        for number in report.buttons {
            guard let input = buttons[number] else { continue }
            switch input {
            case .rightStickUp: state.rightStick.y = 1
            case .rightStickDown: state.rightStick.y = -1
            case .rightStickLeft: state.rightStick.x = -1
            case .rightStickRight: state.rightStick.x = 1
            case .leftStickUp: state.leftStick.y = 1
            case .leftStickDown: state.leftStick.y = -1
            case .leftStickLeft: state.leftStick.x = -1
            case .leftStickRight: state.leftStick.x = 1
            case .unbound: break
            default: state.pressed.insert(input)
            }
        }
        if let hat = report.hat {
            if [7, 0, 1].contains(hat) { state.pressed.insert(.dpadUp) }
            if [1, 2, 3].contains(hat) { state.pressed.insert(.dpadRight) }
            if [3, 4, 5].contains(hat) { state.pressed.insert(.dpadDown) }
            if [5, 6, 7].contains(hat) { state.pressed.insert(.dpadLeft) }
        }
        for (usage, value) in report.axes {
            let deadzoned = abs(value) < Self.deadzone ? 0 : value
            switch axes[usage] {
            case .leftX: state.leftStick.x = deadzoned
            case .leftY: state.leftStick.y = -deadzoned
            case .rightX: state.rightStick.x = deadzoned
            case .rightY: state.rightStick.y = -deadzoned
            case .dpadX:
                if value < -0.5 { state.pressed.insert(.dpadLeft) }
                if value > 0.5 { state.pressed.insert(.dpadRight) }
            case .dpadY:
                if value < -0.5 { state.pressed.insert(.dpadUp) }
                if value > 0.5 { state.pressed.insert(.dpadDown) }
            case nil: break
            }
        }
        return state
    }

    static let deadzone: Float = 0.15

    // Button numbers below are RetroArch autoconfig indices + 1 (HID button usages are 1-based).
    // See docs/specs/controllers.md for sources and what is unverified.

    /// DragonRise 0079:0006. RetroArch: "Retrolink N64" (udev name "Retrolink Nintento 64 Classic USB").
    static let retrolinkN64 = HIDPreset(
        id: "retrolink-n64", name: "Retrolink N64", console: .n64, vendorID: 0x0079, productID: 0x0006,
        nameHints: ["64"], source: .community,
        buttons: [1: .rightStickUp, 2: .rightStickRight, 3: .rightStickDown, 4: .rightStickLeft,
                  5: .l1, 6: .r1, 7: .south, 8: .l2, 9: .west, 10: .start],
        axes: [HIDUsage.x: .leftX, HIDUsage.y: .leftY])

    /// DragonRise 0079:0011. RetroArch and SDL: "Retrolink SNES Controller", d-pad on X/Y.
    static let retrolinkSNES = HIDPreset(
        id: "retrolink-snes", name: "Retrolink SNES", console: .snes, vendorID: 0x0079, productID: 0x0011,
        nameHints: ["snes", "super"], source: .community,
        buttons: [1: .north, 2: .east, 3: .south, 4: .west, 5: .l1, 6: .r1, 9: .select, 10: .start],
        axes: [HIDUsage.x: .dpadX, HIDUsage.y: .dpadY])

    /// Unverified: no public database lists the Retrolink Genesis 6-button pad. Assumed to share the
    /// DragonRise 0079:0011 board with the SNES pad, with a Genesis button order (A B C X Y Z, Mode, Start).
    static let retrolinkGenesis = HIDPreset(
        id: "retrolink-genesis", name: "Retrolink Genesis 6-button", console: .genesis, vendorID: 0x0079, productID: 0x0011,
        nameHints: ["genesis", "sega", "mega"], source: .unverified,
        buttons: [1: .west, 2: .south, 3: .east, 4: .l1, 5: .north, 6: .r1, 9: .select, 10: .start],
        axes: [HIDUsage.x: .dpadX, HIDUsage.y: .dpadY])

    /// Unknown pads: common DirectInput order, hat or X/Y d-pad, Z/Rz right stick. Remap from Controls.
    static let generic = HIDPreset(
        id: "generic", name: "Generic USB gamepad", console: nil, vendorID: nil, productID: nil,
        nameHints: [], source: .generic,
        buttons: [1: .south, 2: .east, 3: .west, 4: .north, 5: .l1, 6: .r1, 7: .l2, 8: .r2,
                  9: .select, 10: .start, 11: .l3, 12: .r3, 13: .home],
        axes: [HIDUsage.x: .leftX, HIDUsage.y: .leftY, HIDUsage.z: .rightX, HIDUsage.rz: .rightY,
               HIDUsage.rx: .rightX, HIDUsage.ry: .rightY])

    static let all = [retrolinkN64, retrolinkSNES, retrolinkGenesis, generic]

    static func preset(id: String) -> HIDPreset? { all.first { $0.id == id } }

    /// Picks the preset for a pad: the user's saved choice, then IDs narrowed by product name, then the
    /// console being played, then the first ID match. Unknown IDs get `generic`.
    static func match(vendorID: Int, productID: Int, productName: String?, userChoice: String?, console: SystemID?) -> HIDPreset {
        if let userChoice, let chosen = preset(id: userChoice) { return chosen }
        let candidates = all.filter { $0.vendorID == vendorID && $0.productID == productID }
        guard !candidates.isEmpty else { return generic }
        let name = productName?.lowercased() ?? ""
        if let named = candidates.first(where: { $0.nameHints.contains(where: name.contains) }) { return named }
        if let console, let forConsole = candidates.first(where: { $0.console == console || ($0.console?.isSegaFamily == true && console.isSegaFamily) }) {
            return forConsole
        }
        return candidates[0]
    }

    static func controllerType(vendorID: Int, productID: Int) -> String {
        String(format: "hid:%04x:%04x", vendorID, productID)
    }
}
