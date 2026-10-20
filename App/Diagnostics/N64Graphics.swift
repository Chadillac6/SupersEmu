import Foundation

enum N64Quality: String, CaseIterable, Identifiable {
    case auto, good, better, best, original

    var id: String { rawValue }

    var title: String {
        switch self {
        case .auto: "Auto"
        case .good: "Good"
        case .better: "Better"
        case .best: "Best"
        case .original: "Original"
        }
    }
}

enum N64Resolution: Int, CaseIterable, Identifiable, Comparable {
    case native = 1, x2, x3, x4

    var id: Int { rawValue }

    var title: String { self == .native ? "Native (1×)" : "\(rawValue)×" }

    var standardScreenSize: String {
        switch self {
        case .native: "320x240"
        case .x2: "640x480"
        case .x3: "960x720"
        case .x4: "1280x960"
        }
    }

    var widescreenScreenSize: String {
        switch self {
        case .native: "640x360"
        case .x2: "960x540"
        case .x3: "1280x720"
        case .x4: "1920x1080"
        }
    }

    var lower: N64Resolution? { N64Resolution(rawValue: rawValue - 1) }

    static func < (lhs: N64Resolution, rhs: N64Resolution) -> Bool { lhs.rawValue < rhs.rawValue }

    /// The most Auto asks for before any slowdown is seen.
    static var deviceAuto: N64Resolution {
        #if os(macOS)
        .x3
        #else
        .x2
        #endif
    }
}

enum N64ScreenLook: String, CaseIterable, Identifiable {
    case sharp, smooth, crt

    var id: String { rawValue }

    var title: String {
        switch self {
        case .sharp: "Sharp pixels"
        case .smooth: "Smooth"
        case .crt: "CRT"
        }
    }
}

enum N64EdgeSmoothing: String, CaseIterable, Identifiable {
    case off, fxaa

    var id: String { rawValue }
    var title: String { self == .off ? "Off" : "FXAA" }
}

enum N64TextureFilter: String, CaseIterable, Identifiable {
    case standard, threePoint

    var id: String { rawValue }
    var title: String { self == .standard ? "Standard" : "N64 3-point" }
}

enum N64TextureEnhancement: String, CaseIterable, Identifiable {
    case off, smooth, xbrz

    var id: String { rawValue }

    var title: String {
        switch self {
        case .off: "Off"
        case .smooth: "Smooth"
        case .xbrz: "xBRZ"
        }
    }
}

/// N64 picture settings. Advanced values left nil follow the quality preset.
struct N64Graphics: Equatable {
    var quality: N64Quality
    var resolution: N64Resolution?
    var edgeSmoothing: N64EdgeSmoothing?
    var textureFilter: N64TextureFilter?
    var textureEnhancement: N64TextureEnhancement
    var sharp2D: Bool
    var widescreen: Bool

    enum Key {
        static let quality = "n64Graphics.quality"
        static let screenLook = "n64Graphics.screenLook"
        static let resolution = "n64Graphics.resolution"
        static let edgeSmoothing = "n64Graphics.edgeSmoothing"
        static let textureFilter = "n64Graphics.textureFilter"
        static let textureEnhancement = "n64Graphics.textureEnhancement"
        static let sharp2D = "n64Graphics.sharp2D"
        static let qualityByGame = "n64Graphics.qualityByGame"
        static let widescreenGames = "n64Graphics.widescreenGames"
        static let autoCapByGame = "n64Graphics.autoCapByGame"
    }

    /// Advanced pickers store this when they follow the preset.
    static let followsPreset = "preset"
    static let defaultQuality = N64Quality.auto
    static let defaultScreenLook = N64ScreenLook.smooth

    static func presetResolution(for quality: N64Quality, autoCap: N64Resolution = .deviceAuto) -> N64Resolution {
        switch quality {
        case .auto: autoCap
        case .good: .x2
        case .better: .x3
        case .best: .x4
        case .original: .native
        }
    }

    static func presetEdgeSmoothing(for quality: N64Quality) -> N64EdgeSmoothing {
        quality == .original ? .off : .fxaa
    }

    static func presetTextureFilter(for quality: N64Quality) -> N64TextureFilter {
        quality == .original ? .standard : .threePoint
    }

    func effectiveResolution(autoCap: N64Resolution) -> N64Resolution {
        resolution ?? Self.presetResolution(for: quality, autoCap: autoCap)
    }

    /// Auto lowers itself only when the resolution comes from the Auto preset.
    var isAutoResolution: Bool { quality == .auto && resolution == nil }

    func coreOptionOverrides(autoCap: N64Resolution) -> [String: String] {
        let resolution = effectiveResolution(autoCap: autoCap)
        var options: [String: String] = [:]
        if widescreen {
            options["mupen64plus-aspect"] = "16:9 adjusted"
            options["mupen64plus-169screensize"] = resolution.widescreenScreenSize
        } else {
            options["mupen64plus-aspect"] = "4:3"
            options["mupen64plus-43screensize"] = resolution.standardScreenSize
        }
        if (edgeSmoothing ?? Self.presetEdgeSmoothing(for: quality)) == .fxaa {
            options["mupen64plus-FXAA"] = "1"
        }
        if (textureFilter ?? Self.presetTextureFilter(for: quality)) == .threePoint {
            options["mupen64plus-BilinearMode"] = "3point"
        }
        switch textureEnhancement {
        case .off: break
        case .smooth: options["mupen64plus-txFilterMode"] = "Smooth filtering 2"
        case .xbrz: options["mupen64plus-txEnhancementMode"] = "4xBRZ"
        }
        if sharp2D {
            options["mupen64plus-EnableNativeResTexrects"] = "Optimized"
        }
        return options
    }

    // MARK: - Storage

    static func load(forGameID gameID: String? = nil, from defaults: UserDefaults = .standard) -> N64Graphics {
        let globalQuality = defaults.string(forKey: Key.quality).flatMap(N64Quality.init(rawValue:)) ?? defaultQuality
        let gameQuality = gameID.flatMap { quality(forGameID: $0, from: defaults) }
        return N64Graphics(
            quality: gameQuality ?? globalQuality,
            resolution: defaults.string(forKey: Key.resolution).flatMap(Int.init).flatMap(N64Resolution.init(rawValue:)),
            edgeSmoothing: defaults.string(forKey: Key.edgeSmoothing).flatMap(N64EdgeSmoothing.init(rawValue:)),
            textureFilter: defaults.string(forKey: Key.textureFilter).flatMap(N64TextureFilter.init(rawValue:)),
            textureEnhancement: defaults.string(forKey: Key.textureEnhancement)
                .flatMap(N64TextureEnhancement.init(rawValue:)) ?? .off,
            sharp2D: defaults.bool(forKey: Key.sharp2D),
            widescreen: gameID.map { isWidescreen(forGameID: $0, from: defaults) } ?? false)
    }

    static func screenLook(from defaults: UserDefaults = .standard) -> N64ScreenLook {
        defaults.string(forKey: Key.screenLook).flatMap(N64ScreenLook.init(rawValue:)) ?? defaultScreenLook
    }

    static func quality(forGameID gameID: String, from defaults: UserDefaults = .standard) -> N64Quality? {
        (defaults.dictionary(forKey: Key.qualityByGame) as? [String: String])?[gameID].flatMap(N64Quality.init(rawValue:))
    }

    static func setQuality(_ quality: N64Quality?, forGameID gameID: String, in defaults: UserDefaults = .standard) {
        var saved = defaults.dictionary(forKey: Key.qualityByGame) as? [String: String] ?? [:]
        saved[gameID] = quality?.rawValue
        defaults.set(saved, forKey: Key.qualityByGame)
    }

    static func isWidescreen(forGameID gameID: String, from defaults: UserDefaults = .standard) -> Bool {
        defaults.stringArray(forKey: Key.widescreenGames)?.contains(gameID) ?? false
    }

    static func setWidescreen(_ widescreen: Bool, forGameID gameID: String, in defaults: UserDefaults = .standard) {
        var games = Set(defaults.stringArray(forKey: Key.widescreenGames) ?? [])
        if widescreen { games.insert(gameID) } else { games.remove(gameID) }
        defaults.set(games.sorted(), forKey: Key.widescreenGames)
    }

    /// Auto's ceiling for a game: the device default, lowered each time the game couldn't keep full speed.
    static func autoCap(forGameID gameID: String, from defaults: UserDefaults = .standard) -> N64Resolution {
        let saved = (defaults.dictionary(forKey: Key.autoCapByGame) as? [String: Int])?[gameID]
            .flatMap(N64Resolution.init(rawValue:))
        return min(saved ?? .deviceAuto, .deviceAuto)
    }

    /// Lowers Auto one step for this game. Returns the new resolution, or nil when it's already native.
    @discardableResult
    static func lowerAutoCap(forGameID gameID: String, in defaults: UserDefaults = .standard) -> N64Resolution? {
        guard let lower = autoCap(forGameID: gameID, from: defaults).lower else { return nil }
        var saved = defaults.dictionary(forKey: Key.autoCapByGame) as? [String: Int] ?? [:]
        saved[gameID] = lower.rawValue
        defaults.set(saved, forKey: Key.autoCapByGame)
        return lower
    }

    static func resetAutoCaps(in defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: Key.autoCapByGame)
    }
}
