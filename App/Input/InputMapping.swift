import Foundation
import Observation

/// Where a remapping applies. Precedence: console default -> controller type -> game.
enum MappingScope: Equatable, Hashable, Sendable {
    case controllerType(String)
    case game(String)
}

/// Saved remappings: `controllerOverrides[type][system][control]` and `gameOverrides[gameID][control]`.
struct InputMappings: Codable, Equatable, Sendable {
    var version = 1
    var controllerOverrides: [String: [String: [String: PadInput]]] = [:]
    var gameOverrides: [String: [String: PadInput]] = [:]
    /// The preset the user picked for a HID controller type whose IDs match more than one pad.
    var hidPresets: [String: String] = [:]

    /// Built-in controller-type defaults: the keyboard's arrow keys drive the N64 stick.
    static let builtinOverrides: [String: [String: [String: PadInput]]] = [
        ControllerType.keyboard: ["n64": [
            "Stick Up": .dpadUp, "Stick Down": .dpadDown, "Stick Left": .dpadLeft, "Stick Right": .dpadRight,
            "Up": .unbound, "Down": .unbound, "Left": .unbound, "Right": .unbound,
        ]],
    ]

    func bindings(for layout: ConsoleLayout, controllerType: String, gameID: String?) -> [String: PadInput] {
        var result = layout.defaults
        result.merge(Self.builtinOverrides[controllerType]?[layout.system] ?? [:]) { $1 }
        result.merge(controllerOverrides[controllerType]?[layout.system] ?? [:]) { $1 }
        if let gameID { result.merge(gameOverrides[gameID] ?? [:]) { $1 } }
        return result.filter { layout.control($0.key) != nil }
    }

    mutating func set(_ input: PadInput, for control: String, system: String, scope: MappingScope) {
        switch scope {
        case .controllerType(let type): controllerOverrides[type, default: [:]][system, default: [:]][control] = input
        case .game(let gameID): gameOverrides[gameID, default: [:]][control] = input
        }
    }

    mutating func reset(system: String, scope: MappingScope) {
        switch scope {
        case .controllerType(let type):
            controllerOverrides[type]?[system] = nil
            if controllerOverrides[type]?.isEmpty == true { controllerOverrides[type] = nil }
        case .game(let gameID):
            gameOverrides[gameID] = nil
        }
    }
}

enum ControllerType {
    static let keyboard = "keyboard"
    static let touch = "touch"
}

/// Turns a controller's physical state into the RetroPad state for one console.
enum InputMapper {
    static let buttonThreshold: Float = 0.5

    static func output(for state: PadState, layout: ConsoleLayout, bindings: [String: PadInput]) -> PadOutput {
        var state = state
        if layout.leftStickDrivesDpad, !bindings.values.contains(where: \.isLeftStick) {
            let stick = state.leftStick
            if stick.y > buttonThreshold { state.pressed.insert(.dpadUp) }
            if stick.y < -buttonThreshold { state.pressed.insert(.dpadDown) }
            if stick.x < -buttonThreshold { state.pressed.insert(.dpadLeft) }
            if stick.x > buttonThreshold { state.pressed.insert(.dpadRight) }
        }
        var output = PadOutput()
        var left = SIMD2<Float>.zero, right = SIMD2<Float>.zero
        for control in layout.controls {
            let input = bindings[control.id] ?? control.defaultInput
            let value = state.value(of: input)
            guard value > 0 else { continue }
            switch control.output {
            case .button(let button):
                if value >= buttonThreshold { output.buttons |= button.mask }
            case .analog(let stick, let direction):
                // libretro analog axes are +x right, +y down.
                let delta: SIMD2<Float> = switch direction {
                case .up: [0, -value]
                case .down: [0, value]
                case .left: [-value, 0]
                case .right: [value, 0]
                }
                if stick == .left { left += delta } else { right += delta }
            }
        }
        output.leftStick = quantize(left)
        output.rightStick = quantize(right)
        return output
    }

    private static func quantize(_ stick: SIMD2<Float>) -> SIMD2<Int16> {
        let clamped = simd_clamp(stick, SIMD2(repeating: -1), SIMD2(repeating: 1))
        return SIMD2(Int16((clamped.x * 32767).rounded()), Int16((clamped.y * 32767).rounded()))
    }
}

/// Remappings persisted as JSON in Application Support.
@Observable
final class InputMappingStore {
    private(set) var mappings: InputMappings
    let url: URL

    init(url: URL) {
        self.url = url
        if let data = try? Data(contentsOf: url), let decoded = try? JSONDecoder().decode(InputMappings.self, from: data) {
            mappings = decoded
        } else {
            mappings = InputMappings()
        }
    }

    func bindings(for layout: ConsoleLayout, controllerType: String, gameID: String?) -> [String: PadInput] {
        mappings.bindings(for: layout, controllerType: controllerType, gameID: gameID)
    }

    func set(_ input: PadInput, for control: String, system: String, scope: MappingScope) {
        mappings.set(input, for: control, system: system, scope: scope)
        save()
    }

    func reset(system: String, scope: MappingScope) {
        mappings.reset(system: system, scope: scope)
        save()
    }

    func setHIDPreset(_ presetID: String?, for controllerType: String) {
        mappings.hidPresets[controllerType] = presetID
        save()
    }

    private func save() {
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(mappings).write(to: url, options: .atomic)
        } catch {
            NSLog("SupersEmu: couldn't save controller mappings: \(error)")
        }
    }
}
