import SupersEmuKit
import SwiftUI

/// Branding for the Home screen: one value per console, plus SupersEmu's own for "All". Logos are bundled official
/// marks (docs/specs/branding-assets.md); swap a theme by editing its entry.
struct SystemTheme: Identifiable, Equatable {
    enum LogoStyle: Equatable {
        /// Readable as-is on the theme background.
        case original
        /// Dark or low-contrast marks sit on a white plate.
        case plate
        /// Single-colour marks drawn in white.
        case light
    }

    let id: String
    let system: SystemID?
    let chip: String
    let logo: String?
    let logoStyle: LogoStyle
    let accent: Color
    let background: [Color]
    /// Brand colours shown as a bar under the selector.
    let stripe: [Color]

    static let all = SystemTheme(id: "all", system: nil, chip: "All", logo: nil, logoStyle: .original, accent: Color(hex: 0x8B5CF6),
                                 background: [Color(hex: 0x1E1240), Color(hex: 0x0B0A1A)],
                                 stripe: [Brand.Colors.red])

    static let systems: [SystemID: SystemTheme] = [
        .snes: make(.snes, "SNES", .original, accent: 0x8C7FD6, background: [0x2A2350, 0x0E0C1A],
                    stripe: [0xE4262D, 0xF7C72B, 0x2AA84A, 0x2463B5]),
        .gb: make(.gb, "GB", .plate, accent: 0x9BBC0F, background: [0x23401A, 0x0B140A], stripe: [0x0F380F, 0x306230, 0x8BAC0F, 0x9BBC0F]),
        .gbc: make(.gbc, "GBC", .plate, accent: 0x00A3AD, background: [0x2D1B4E, 0x0D0A18],
                   stripe: [0xE5004F, 0x5B4FD2, 0x7DBE2F, 0xF2B90F, 0x00A3AD]),
        .gba: make(.gba, "GBA", .original, accent: 0x6F63F2, background: [0x1C1760, 0x08061F], stripe: [0x3A2EC4, 0x8F87F5]),
        .genesis: make(.genesis, "Genesis", .original, accent: 0x1A8FE3, background: [0x00337A, 0x000B1F], stripe: [0x0060A8, 0x0089CF]),
        .segacd: make(.segacd, "Sega CD", .original, accent: 0x3D8BFD, background: [0x2B2F36, 0x0A0B0D],
                      stripe: [0xC0C4CC, 0x0089CF]),
        .sega32x: make(.sega32x, "32X", .plate, accent: 0xE0242E, background: [0x3A0A0E, 0x0C0203], stripe: [0xB5121B, 0xF5F5F5]),
        .psx: make(.psx, "PS1", .light, accent: 0x3B82F6, background: [0x45474D, 0x141518],
                   stripe: [0xE60012, 0xF2B100, 0x00A651, 0x0070D1]),
        .n64: make(.n64, "N64", .plate, accent: 0x2E6BE6, background: [0x10226B, 0x05081C],
                   stripe: [0xE10F00, 0xF5B700, 0x00953B, 0x0047BB]),
    ]

    static func theme(for system: SystemID?) -> SystemTheme {
        system.flatMap { systems[$0] } ?? all
    }

    private static func make(_ system: SystemID, _ chip: String, _ logoStyle: LogoStyle, accent: UInt32, background: [UInt32],
                             stripe: [UInt32]) -> SystemTheme {
        SystemTheme(id: system.rawValue, system: system, chip: chip, logo: "logo-\(system.rawValue)", logoStyle: logoStyle,
                    accent: Color(hex: accent), background: background.map { Color(hex: $0) }, stripe: stripe.map { Color(hex: $0) })
    }
}

/// The console's official logo, or the SupersEmu wordmark for "All".
struct ThemeLogo: View {
    let theme: SystemTheme
    var height: CGFloat = 40

    var body: some View {
        if let logo = theme.logo {
            logoImage(logo)
                .frame(height: height)
                .accessibilityLabel(theme.system?.displayName ?? theme.chip)
        } else {
            BrandLockup()
                .scaleEffect(height / 40)
                .frame(height: height)
        }
    }
}

extension ThemeLogo {
    @ViewBuilder func logoImage(_ name: String) -> some View {
        switch theme.logoStyle {
        case .original:
            Image(name).resizable().scaledToFit()
        case .light:
            Image(name).renderingMode(.template).resizable().scaledToFit().foregroundStyle(Brand.Colors.ink)
        case .plate:
            Image(name).resizable().scaledToFit()
                .padding(.horizontal, height * 0.3).padding(.vertical, height * 0.15)
                .background(.white, in: RoundedRectangle(cornerRadius: height * 0.22))
                .overlay {
                    RoundedRectangle(cornerRadius: height * 0.22)
                        .stroke(Brand.Colors.line, lineWidth: 1)
                }
        }
    }
}

extension Color {
    init(hex: UInt32) {
        self.init(red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255, blue: Double(hex & 0xFF) / 255)
    }
}
