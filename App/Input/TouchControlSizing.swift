import Foundation

enum TouchControlSizing {
    static func portraitScale(availableWidth: CGFloat, requiredWidth: CGFloat) -> CGFloat {
        min(1.3, max(0.75, (availableWidth - 24) / requiredWidth))
    }

    static func requiredPortraitWidth(system: String) -> CGFloat {
        let dpad: CGFloat = 156
        let pill: CGFloat = 64
        let button: CGFloat = 62
        let gap: CGFloat = 8
        switch system {
        case "n64":
            let cButtons: CGFloat = 116
            let faceButtons: CGFloat = 134
            let topRowWidth = dpad + pill + cButtons + 2 * gap
            let bottomRowWidth: CGFloat = 120 + faceButtons + gap
            return max(topRowWidth, bottomRowWidth)
        case "genesis", "segacd", "sega32x":
            let faceButtons = 3 * button + 8
            let buttonRowWidth = dpad + faceButtons + gap
            let pillRowWidth = 2 * pill + gap
            return max(buttonRowWidth, pillRowWidth)
        case "psx":
            return dpad + pill + 2 * button + 10 + 2 * gap
        case "gb", "gbc", "gba":
            return dpad + pill + 2 * button + 8 + 2 * gap
        default:
            return dpad + pill + 2 * button + 10 + 2 * gap
        }
    }
}
