import GameController

/// Merges on-screen touch controls, MFi/Xbox/PlayStation/8BitDo controllers and the keyboard.
/// Face buttons map by position (SNES layout: B bottom, A right, Y left, X top).
final class GameInput {
    var touchButtons: SEJoypadButtons = []

    func currentButtons() -> SEJoypadButtons {
        var buttons = touchButtons
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
