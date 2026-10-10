import GameController
import Observation

extension InputMappingStore {
    static let shared = InputMappingStore(url: AppPaths.root.appendingPathComponent("Controls.json"))
}

extension Notification.Name {
    static let gamepadDisconnected = Notification.Name("SupersEmuGamepadDisconnected")
    static let gamepadConnected = Notification.Name("SupersEmuGamepadConnected")
}

/// Every connected gamepad, GameController and (on macOS) raw HID, in connection order: the first is player 1.
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
    @ObservationIgnored private var gcByID: [String: GCController] = [:]
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
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
        refresh()
    }

    func controller(at port: Int) -> Controller? {
        controllers.indices.contains(port) ? controllers[port] : nil
    }

    func state(of controller: Controller, console: String?) -> PadState {
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
    func preset(for device: HIDGamepad, console: String?) -> HIDPreset {
        HIDPreset.match(vendorID: device.vendorID, productID: device.productID, productName: device.productName,
                        userChoice: InputMappingStore.shared.mappings.hidPresets[device.controllerType], console: console)
    }

    func hidDevice(for controller: Controller) -> HIDGamepad? { hidByID[controller.id] }
    #endif

    private func refresh() {
        var next: [Controller] = []
        var gc: [String: GCController] = [:]
        for controller in GCController.controllers() where controller.extendedGamepad != nil {
            let id = "gc-\(UInt(bitPattern: ObjectIdentifier(controller).hashValue))"
            let name = controller.vendorName ?? controller.productCategory
            gc[id] = controller
            // Home/Guide is ours (long press opens the in-game menu), not the system's.
            controller.extendedGamepad?.buttonHome?.preferredSystemGestureState = .disabled
            next.append(Controller(id: id, name: name, type: "gc:\(controller.productCategory):\(name)", kind: .gameController))
        }
        gcByID = gc
        #if os(macOS)
        var hidDevices: [String: HIDGamepad] = [:]
        for device in hid.gamepads {
            let id = "hid-\(device.id)"
            hidDevices[id] = device
            next.append(Controller(id: id, name: device.productName, type: device.controllerType, kind: .hid))
        }
        hidByID = hidDevices
        #endif
        // Keep existing players in their slots; newcomers join at the end.
        let kept = controllers.filter { old in next.contains { $0.id == old.id } }
        let added = next.filter { new in !kept.contains { $0.id == new.id } }
        let removed = controllers.filter { old in !next.contains { $0.id == old.id } }
        controllers = kept + added
        for controller in removed {
            NotificationCenter.default.post(name: .gamepadDisconnected, object: controller.name)
        }
        if !added.isEmpty { NotificationCenter.default.post(name: .gamepadConnected, object: nil) }
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
