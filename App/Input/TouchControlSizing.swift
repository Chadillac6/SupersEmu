import Foundation
import SupersEmuKit

enum TouchControlSizing {
    static func portraitScale(availableWidth: CGFloat, requiredWidth: CGFloat) -> CGFloat {
        min(1.3, max(0.75, (availableWidth - 24) / requiredWidth))
    }

    static func requiredPortraitWidth(system: SystemID) -> CGFloat {
        let dpad: CGFloat = 156
        let pill: CGFloat = 64
        let button: CGFloat = 62
        let gap: CGFloat = 8
        switch system.controlFamily {
        case .n64:
            let cButtons: CGFloat = 116
            let faceButtons: CGFloat = 134
            let topRowWidth = dpad + pill + cButtons + 2 * gap
            let bottomRowWidth: CGFloat = 120 + faceButtons + gap
            return max(topRowWidth, bottomRowWidth)
        case .sega:
            let faceButtons = 3 * button + 8
            let buttonRowWidth = dpad + faceButtons + gap
            let pillRowWidth = 2 * pill + gap
            return max(buttonRowWidth, pillRowWidth)
        case .psx, .ps2:
            return dpad + pill + 2 * button + 10 + 2 * gap
        case .dreamcast:
            // Stick, L/R and the face buttons on top; the d-pad, Start and a face-button-wide gap below.
            let faceButtons = 2 * button + 10
            let stickRowWidth = 120 + pill + faceButtons + 2 * gap
            let dpadRowWidth = dpad + pill + faceButtons + 2 * gap
            return max(stickRowWidth, dpadRowWidth)
        case .handheld:
            return dpad + pill + 2 * button + 8 + 2 * gap
        case .snes:
            return dpad + pill + 2 * button + 10 + 2 * gap
        }
    }
}
