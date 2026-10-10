import GameController
#if os(macOS)
import AppKit
#endif

/// Merges on-screen touch controls, MFi/Xbox/PlayStation/8BitDo controllers and the keyboard.
/// Face buttons map by position (SNES layout: B bottom, A right, Y left, X top).
final class GameInput {
    var touchButtons: SEJoypadButtons = []

    #if os(macOS)
    /// AppKit fallback for keyboards GameController doesn't report (e.g. remote/virtual keyboards).
    private static let keyCodeMap: [UInt16: SEJoypadButtons] = [
        126: .up, 125: .down, 123: .left, 124: .right,
        6: .b, 7: .a, 0: .y, 1: .x, 12: .l, 13: .r,
        36: .start, 76: .start, 48: .select, 60: .select,
    ]
    private var appKitButtons: SEJoypadButtons = []
    private var keyMonitor: Any?

    init() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp, .flagsChanged]) { [weak self] event in
            guard let self, let button = Self.keyCodeMap[event.keyCode],
                  !event.modifierFlags.contains(.command) else { return event }
            switch event.type {
            case .keyDown: self.appKitButtons.insert(button)
            case .keyUp: self.appKitButtons.remove(button)
            case .flagsChanged:
                if event.modifierFlags.contains(.shift) { self.appKitButtons.insert(button) }
                else { self.appKitButtons.remove(button) }
            default: break
            }
            return nil
        }
    }

    deinit {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
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
        return buttons
    }
}
