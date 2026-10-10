import GameController
#if os(macOS)
import AppKit
#endif

/// Merges on-screen touch controls, MFi/Xbox/PlayStation/8BitDo controllers and the keyboard.
/// Face buttons map by position (SNES layout: B bottom, A right, Y left, X top).
final class GameInput {
    var touchButtons: SEJoypadButtons = []

    #if os(macOS)
    /// Keyboard input on macOS, scoped to the owning player window.
    private static let keyCodeMap: [UInt16: SEJoypadButtons] = [
        126: .up, 125: .down, 123: .left, 124: .right,
        6: .b, 7: .a, 0: .y, 1: .x, 12: .l, 13: .r,
        36: .start, 76: .start, 48: .select, 60: .select,
    ]
    private var appKitButtons: SEJoypadButtons = []
    private var keyMonitor: Any?
    private var observers: [NSObjectProtocol] = []

    /// The player window this input belongs to; keys from other windows are ignored.
    weak var window: NSWindow? {
        didSet {
            guard window !== oldValue else { return }
            releaseAll()
            observers.removeAll { NotificationCenter.default.removeObserver($0); return true }
            let center = NotificationCenter.default
            observers.append(center.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { [weak self] _ in self?.releaseAll() })
            if let window {
                observers.append(center.addObserver(forName: NSWindow.didResignKeyNotification, object: window, queue: .main) { [weak self] _ in self?.releaseAll() })
            }
        }
    }

    init() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp, .flagsChanged]) { [weak self] event in
            guard let self, let window = self.window, event.window === window,
                  let button = Self.keyCodeMap[event.keyCode] else { return event }
            let isCommand = event.modifierFlags.contains(.command)
            switch event.type {
            case .keyDown:
                if isCommand { return event }
                self.appKitButtons.insert(button)
            case .keyUp:
                self.appKitButtons.remove(button)
                if isCommand { return event }
            case .flagsChanged:
                if event.modifierFlags.contains(.shift) { self.appKitButtons.insert(button) }
                else { self.appKitButtons.remove(button) }
                return event
            default:
                return event
            }
            return nil
        }
    }

    func releaseAll() {
        appKitButtons = []
    }

    deinit {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        observers.forEach { NotificationCenter.default.removeObserver($0) }
    }
    #endif

    func currentButtons() -> SEJoypadButtons {
        var buttons = touchButtons
        #if os(macOS)
        buttons.formUnion(appKitButtons)
        #endif
        if let pad = GCController.current?.extendedGamepad {
            let stick = pad.leftThumbstick
            if pad.dpad.up.isPressed || stick.yAxis.value > 0.5 { buttons.insert(.up) }
            if pad.dpad.down.isPressed || stick.yAxis.value < -0.5 { buttons.insert(.down) }
            if pad.dpad.left.isPressed || stick.xAxis.value < -0.5 { buttons.insert(.left) }
            if pad.dpad.right.isPressed || stick.xAxis.value > 0.5 { buttons.insert(.right) }
            if pad.buttonA.isPressed { buttons.insert(.b) }
            if pad.buttonB.isPressed { buttons.insert(.a) }
            if pad.buttonX.isPressed { buttons.insert(.y) }
            if pad.buttonY.isPressed { buttons.insert(.x) }
            if pad.leftShoulder.isPressed { buttons.insert(.l) }
            if pad.rightShoulder.isPressed { buttons.insert(.r) }
            if pad.buttonMenu.isPressed { buttons.insert(.start) }
            if pad.buttonOptions?.isPressed == true { buttons.insert(.select) }
        }
        #if !os(macOS)
        // On macOS the AppKit monitor handles keyboards; GCKeyboard keeps keys stuck when they're released in another app.
        if let keyboard = GCKeyboard.coalesced?.keyboardInput {
            let mapping: [(GCKeyCode, SEJoypadButtons)] = [
                (.upArrow, .up), (.downArrow, .down), (.leftArrow, .left), (.rightArrow, .right),
                (.keyZ, .b), (.keyX, .a), (.keyA, .y), (.keyS, .x),
                (.keyQ, .l), (.keyW, .r), (.returnOrEnter, .start), (.rightShift, .select), (.tab, .select),
            ]
            for (key, button) in mapping where keyboard.button(forKeyCode: key)?.isPressed == true {
                buttons.insert(button)
            }
        }
        #endif
        return buttons
    }
}
