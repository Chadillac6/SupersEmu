import GameController
import Observation
import SupersEmuKit

extension InputMappingStore {
    static let shared = InputMappingStore(url: AppPaths.root.appendingPathComponent("Controls.json"))
}

extension Notification.Name {
    static let gamepadDisconnected = Notification.Name("SupersEmuGamepadDisconnected")
    static let gamepadConnected = Notification.Name("SupersEmuGamepadConnected")
}

/// Tracks connected GameController and raw HID pads separately from their assigned player ports.
@MainActor
@Observable
final class ControllerHub {
    static let shared = ControllerHub()

    struct Controller: Identifiable, Equatable {
        enum Kind: Equatable { case gameController, hid }
        let id: String
        let name: String
        /// Mapping key shared by every pad of this model ("gc:Xbox Wireless Controller", "hid:0079:0006").
        let type: String
        let kind: Kind
    }

    private(set) var controllers: [Controller] = []
    private(set) var assignments = ControllerAssignments(portCount: Int(SEInputPortCount))
    @ObservationIgnored private var gcByID: [String: GCController] = [:]
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    #if DEBUG
    // DEBUG-only simulated controller for the iOS Simulator. SUPERSEMU_DEBUG_CONTROLLER:
    //   unset/unrecognised → nothing changes.
    //   Any recognised value hides real GCControllers (and HID pads on macOS) — needed because
    //   the iOS 26.5 Simulator reports a phantom "Gamepad" even with no pad attached.
    //   `off` → no controllers; `on` → one fake pad; `two` → two identical fake pads;
    //   <seconds> → fake pad for N s
    //   then dropped, exercising the real disconnect path (gamepadDisconnected, DisconnectPrompt).
    private enum DebugController {
        case disabled          // "off": no controllers at all
        case permanent         // "on": fake pad forever
        case pair              // "two": two fake pads of the same model
        case temporary(Date)   // "<seconds>": fake pad until the expiry date
    }
    @ObservationIgnored private let debugPad = Controller(id: "debug-pad", name: "Debug Controller", type: "gc:debug", kind: .gameController)
    @ObservationIgnored private var debugController: DebugController?
    #endif
    #if os(macOS)
    @ObservationIgnored private let hid = HIDGamepadManager()
    @ObservationIgnored private var hidByID: [String: HIDGamepad] = [:]
    #endif

    private init() {
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: .GCControllerDidConnect, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        })
        observers.append(center.addObserver(forName: .GCControllerDidDisconnect, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        })
        #if os(macOS)
        hid.onChange = { [weak self] in MainActor.assumeIsolated { self?.refresh() } }
        #endif
        #if DEBUG
        if let value = ProcessInfo.processInfo.environment["SUPERSEMU_DEBUG_CONTROLLER"] {
            switch value {
            case "on": debugController = .permanent
            case "off": debugController = .disabled
            case "two": debugController = .pair
            default:
                if let seconds = TimeInterval(value) {
                    debugController = .temporary(Date().addingTimeInterval(seconds))
                    Task { [weak self] in
                        try? await Task.sleep(for: .seconds(seconds))
                        self?.refresh()
                    }
                }  // Unrecognised values leave the override nil → unchanged behaviour.
            }
        }
        #endif
        refresh()
    }

    func controller(at port: Int) -> Controller? {
        guard assignments.slots.indices.contains(port), let id = assignments.slots[port] else { return nil }
        return controllers.first { $0.id == id }
    }

    func assignController(_ id: String?, to port: Int) {
        assignments.assign(id, to: port)
    }

    func state(of controller: Controller, console: SystemID?) -> PadState {
        switch controller.kind {
        case .gameController:
            guard let pad = gcByID[controller.id]?.extendedGamepad else { return PadState() }
            return Self.state(of: pad)
        case .hid:
            #if os(macOS)
            guard let device = hidByID[controller.id] else { return PadState() }
            return preset(for: device, console: console).state(from: device.report)
            #else
            return PadState()
            #endif
        }
    }

    #if os(macOS)
    func preset(for device: HIDGamepad, console: SystemID?) -> HIDPreset {
        HIDPreset.match(vendorID: device.vendorID, productID: device.productID, productName: device.productName,
                        userChoice: InputMappingStore.shared.mappings.hidPresets[device.controllerType], console: console)
    }

    func hidDevice(for controller: Controller) -> HIDGamepad? { hidByID[controller.id] }
    #endif

    private func refresh() {
        var next: [Controller] = []
        var gc: [String: GCController] = [:]
        #if DEBUG
        let includeReal = debugController == nil
        switch debugController {
        case .permanent:
            next.append(debugPad)
        case .pair:
            next = [debugPad, Controller(id: "debug-pad-2", name: debugPad.name, type: debugPad.type, kind: debugPad.kind)]
        case .temporary(let expiry) where Date() < expiry:
            next.append(debugPad)
        default:
            break
        }
        #else
        let includeReal = true
        #endif
        if includeReal {
            for controller in GCController.controllers() where controller.extendedGamepad != nil {
                let id = "gc-\(UInt(bitPattern: ObjectIdentifier(controller).hashValue))"
                let name = controller.vendorName ?? controller.productCategory
                gc[id] = controller
                // Home/Guide is ours (long press opens the in-game menu), not the system's.
                controller.extendedGamepad?.buttonHome?.preferredSystemGestureState = .disabled
                next.append(Controller(id: id, name: name, type: "gc:\(controller.productCategory):\(name)", kind: .gameController))
            }
        }
        gcByID = gc
        #if os(macOS)
        var hidDevices: [String: HIDGamepad] = [:]
        if includeReal {
            for device in hid.gamepads {
                let id = "hid-\(device.id)"
                hidDevices[id] = device
                next.append(Controller(id: id, name: device.productName, type: device.controllerType, kind: .hid))
            }
        }
        hidByID = hidDevices
        #endif
        let previouslyAssigned = Set(assignments.slots.compactMap { $0 })
        // Keep discovery order independent from the player slots.
        let kept = controllers.filter { old in next.contains { $0.id == old.id } }
        let added = next.filter { new in !kept.contains { $0.id == new.id } }
        let removed = controllers.filter { old in !next.contains { $0.id == old.id } }
        controllers = kept + added
        assignments.update(connectedIDs: controllers.map(\.id))
        for controller in removed where previouslyAssigned.contains(controller.id) {
            NotificationCenter.default.post(name: .gamepadDisconnected, object: controller.name)
        }
        if let id = assignments.slots.compactMap({ $0 }).first(where: { !previouslyAssigned.contains($0) }) {
            NotificationCenter.default.post(name: .gamepadConnected, object: id)
        }
    }

    static func state(of pad: GCExtendedGamepad) -> PadState {
        var state = PadState()
        let buttons: [(GCControllerButtonInput?, PadInput)] = [
            (pad.dpad.up, .dpadUp), (pad.dpad.down, .dpadDown), (pad.dpad.left, .dpadLeft), (pad.dpad.right, .dpadRight),
            (pad.buttonA, .south), (pad.buttonB, .east), (pad.buttonX, .west), (pad.buttonY, .north),
            (pad.leftShoulder, .l1), (pad.rightShoulder, .r1), (pad.leftTrigger, .l2), (pad.rightTrigger, .r2),
            (pad.leftThumbstickButton, .l3), (pad.rightThumbstickButton, .r3),
            (pad.buttonMenu, .start), (pad.buttonOptions, .select), (pad.buttonHome, .home),
        ]
        for (button, input) in buttons where button?.isPressed == true { state.pressed.insert(input) }
        state.leftStick = [pad.leftThumbstick.xAxis.value, pad.leftThumbstick.yAxis.value]
        state.rightStick = [pad.rightThumbstick.xAxis.value, pad.rightThumbstick.yAxis.value]
        return state
    }
}
