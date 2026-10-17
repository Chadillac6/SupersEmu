import Foundation

enum N64Preset: String, CaseIterable, Identifiable {
    case standard
    case faster
    case balanced
    case fastest

    static let defaultKey = "n64DefaultPreset"
    static let perGameKey = "n64PresetByGame"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .standard: "Standard"
        case .faster: "Faster"
        case .balanced: "Balanced"
        case .fastest: "Fastest"
        }
    }

    var coreOptionOverrides: [String: String] {
        switch self {
        case .standard:
            [:]
        case .faster:
            [
                "mupen64plus-43screensize": "320x240",
                "mupen64plus-EnableCopyDepthToRDRAM": "Off",
            ]
        case .balanced:
            [
                "mupen64plus-43screensize": "320x240",
                "mupen64plus-CountPerOp": "3",
                "mupen64plus-EnableCopyColorToRDRAM": "Async",
                "mupen64plus-EnableCopyDepthToRDRAM": "Software",
                "mupen64plus-EnableLODEmulation": "True",
            ]
        case .fastest:
            [
                "mupen64plus-43screensize": "320x240",
                "mupen64plus-EnableCopyDepthToRDRAM": "Off",
                "mupen64plus-EnableCopyColorToRDRAM": "Off",
                "mupen64plus-EnableLODEmulation": "False",
                "mupen64plus-CountPerOp": "3",
            ]
        }
    }

    static func defaultPreset(from defaults: UserDefaults = .standard) -> N64Preset {
        defaults.string(forKey: defaultKey).flatMap(N64Preset.init(rawValue:)) ?? .balanced
    }

    static func preset(forGameID gameID: String, from defaults: UserDefaults = .standard) -> N64Preset? {
        let saved = defaults.dictionary(forKey: perGameKey) as? [String: String]
        return saved?[gameID].flatMap(N64Preset.init(rawValue:))
    }

    static func selectedPreset(forGameID gameID: String, from defaults: UserDefaults = .standard) -> N64Preset {
        preset(forGameID: gameID, from: defaults) ?? defaultPreset(from: defaults)
    }

    static func setDefaultPreset(_ preset: N64Preset, in defaults: UserDefaults = .standard) {
        defaults.set(preset.rawValue, forKey: defaultKey)
    }

    static func setPreset(_ preset: N64Preset?, forGameID gameID: String, in defaults: UserDefaults = .standard) {
        var saved = defaults.dictionary(forKey: perGameKey) as? [String: String] ?? [:]
        if let preset {
            saved[gameID] = preset.rawValue
        } else {
            saved.removeValue(forKey: gameID)
        }
        defaults.set(saved, forKey: perGameKey)
    }
}
