import SupersEmuKit

enum DevicePlatform: Sendable {
    case mac, iOS

    /// LRPS2 is linked only into the Apple Silicon Mac app (see `CoreRegistry.macOSOnlyCores`).
    static var hasPS2Core: Bool {
        #if os(macOS) && arch(arm64)
        true
        #else
        false
        #endif
    }

    static var current: DevicePlatform {
        #if os(macOS)
        .mac
        #else
        .iOS
        #endif
    }
}

/// Whether a console's games show on a device. iPhone and iPad have no JIT, so Dreamcast runs there as a beta and
/// PS2 (Mac only) is hidden there: library, search, console chips and Controls.
enum SystemAvailability: Equatable, Sendable {
    case available, beta, hidden
}

extension SystemID {
    func availability(on platform: DevicePlatform = .current) -> SystemAvailability {
        switch (self, platform) {
        case (.ps2, .iOS): .hidden
        case (.ps2, .mac): DevicePlatform.hasPS2Core ? .available : .hidden
        case (.dreamcast, .iOS): .beta
        default: .available
        }
    }

    func isShown(on platform: DevicePlatform = .current) -> Bool { availability(on: platform) != .hidden }

    func isBeta(on platform: DevicePlatform = .current) -> Bool { availability(on: platform) == .beta }
}
