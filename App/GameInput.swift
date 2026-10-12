import GameController
#if os(macOS)
import AppKit
#endif

/// Merges on-screen touch controls, GameController pads (MFi/Xbox/PlayStation/8BitDo), raw HID pads on macOS
/// and the keyboard. Everything maps by position through the console layout and the saved remappings.
/// Player 1 gets touch, keyboard and the first pad; further pads are players 2-4.
@MainActor
final class GameInput {
    var layout = ConsoleLayout.forSystem("snes")
    var gameID: String?
    /// On-screen controls; always use the console defaults.
    var touchState = PadState()

    private let hub = ControllerHub.shared
    private let store = InputMappingStore.shared

    #if os(macOS)
    /// Keyboard input on macOS, scoped to the owning player window. Keys sit on fixed pad positions.
    static let keyCodeMap: [UInt16: PadInput] = [
        126: .dpadUp, 125: .dpadDown, 123: .dpadLeft, 124: .dpadRight,
        6: .south, 7: .east, 0: .west, 1: .north, 12: .l1, 13: .r1, 14: .l2, 15: .r2,
        34: .rightStickUp, 40: .rightStickDown, 38: .rightStickLeft, 37: .rightStickRight,
        36: .start, 76: .start, 48: .select, 60: .select, 53: .home,
    ]
    private var keyboardPressed: Set<PadInput> = []
    private var keyMonitor: Any?
    private var observers: [NSObjectProtocol] = []

    /// The player window this input belongs to; keys from other windows are ignored.
    weak var window: NSWindow? {
        didSet {
            guard window !== oldValue else { return }
            releaseAll()
            observers.removeAll { NotificationCenter.default.removeObserver($0); return true }
            let center = NotificationCenter.default
            observers.append(center.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.releaseAll() }
            })
            if let window {
                observers.append(center.addObserver(forName: NSWindow.didResignKeyNotification, object: window, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.releaseAll() }
                })
            }
        }
    }

    init() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp, .flagsChanged]) { [weak self] event in
            MainActor.assumeIsolated {
                guard let self, let window = self.window, event.window === window,
                      let input = Self.keyCodeMap[event.keyCode] else { return event }
                let isCommand = event.modifierFlags.contains(.command)
                switch event.type {
                case .keyDown:
                    if isCommand { return event }
                    self.keyboardPressed.insert(input)
                case .keyUp:
                    self.keyboardPressed.remove(input)
                    if isCommand { return event }
                case .flagsChanged:
                    if event.modifierFlags.contains(.shift) { self.keyboardPressed.insert(input) }
                    else { self.keyboardPressed.remove(input) }
                    return event
                default:
                    return event
                }
                return nil
            }
        }
    }

    func releaseAll() {
        keyboardPressed = []
    }

    deinit {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        observers.forEach { NotificationCenter.default.removeObserver($0) }
    }

    private var keyboardState: PadState { PadState(pressed: keyboardPressed) }
    #else
    // On macOS the AppKit monitor handles keyboards; GCKeyboard keeps keys stuck when they're released in another app.
    private var keyboardState: PadState { PadState(pressed: Self.hardwareKeyboardPressed()) }

    static func hardwareKeyboardPressed() -> Set<PadInput> {
        var pressed: Set<PadInput> = []
        guard let keyboard = GCKeyboard.coalesced?.keyboardInput else { return pressed }
        let mapping: [(GCKeyCode, PadInput)] = [
            (.upArrow, .dpadUp), (.downArrow, .dpadDown), (.leftArrow, .dpadLeft), (.rightArrow, .dpadRight),
            (.keyZ, .south), (.keyX, .east), (.keyA, .west), (.keyS, .north),
            (.keyQ, .l1), (.keyW, .r1), (.keyE, .l2), (.keyR, .r2),
            (.keyI, .rightStickUp), (.keyK, .rightStickDown), (.keyJ, .rightStickLeft), (.keyL, .rightStickRight),
            (.returnOrEnter, .start), (.rightShift, .select), (.tab, .select), (.escape, .home),
        ]
        for (key, input) in mapping where keyboard.button(forKeyCode: key)?.isPressed == true {
            pressed.insert(input)
        }
        return pressed
    }
    #endif

    /// What each port's core input should be this frame.
    func outputs() -> [PadOutput] {
        var ports = Array(repeating: PadOutput(), count: Int(SEInputPortCount))
        ports[0] = merge(InputMapper.output(for: touchState, layout: layout, bindings: layout.defaults),
                         InputMapper.output(for: keyboardState, layout: layout, bindings: bindings(ControllerType.keyboard)))
        for (port, controller) in hub.controllers.prefix(ports.count).enumerated() {
            let state = hub.state(of: controller, console: layout.system)
            ports[port] = merge(ports[port], InputMapper.output(for: state, layout: layout, bindings: bindings(controller.type)))
        }
        return ports
    }

    /// Player 1's RetroPad buttons (disc picker and chords).
    func currentButtons() -> SEJoypadButtons {
        SEJoypadButtons(rawValue: outputs()[0].buttons)
    }

    /// Every physical control held right now, by position; drives menus, hotkeys and remapping capture.
    func physicalState() -> PadState {
        var state = keyboardState
        sourceStates().dropFirst().forEach { state.merge($0) }
        return state
    }

    /// The keyboard first, then each controller, kept apart so chords only count when one player holds them.
    func sourceStates() -> [PadState] {
        [keyboardState] + hub.controllers.map { hub.state(of: $0, console: layout.system) }
    }

    private func bindings(_ controllerType: String) -> [String: PadInput] {
        store.bindings(for: layout, controllerType: controllerType, gameID: gameID)
    }

    private func merge(_ a: PadOutput, _ b: PadOutput) -> PadOutput {
        func stronger(_ x: SIMD2<Int16>, _ y: SIMD2<Int16>) -> SIMD2<Int16> {
            abs(Int(x.x)) + abs(Int(x.y)) >= abs(Int(y.x)) + abs(Int(y.y)) ? x : y
        }
        return PadOutput(buttons: a.buttons | b.buttons, leftStick: stronger(a.leftStick, b.leftStick),
                         rightStick: stronger(a.rightStick, b.rightStick))
    }
}
