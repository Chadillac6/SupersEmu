import Foundation

/// Maps a console (`SystemID` raw value from SupersEmuKit) or ROM file extension to the
/// statically linked libretro core that runs it.
enum CoreRegistry {
    struct Core: Equatable {
        let id: String
        let systems: [String]
        let extensions: Set<String>
    }

    static let cores: [Core] = [
        Core(id: SECoreIDSnes9x, systems: ["snes"], extensions: ["sfc", "smc"]),
        Core(id: SECoreIDGambatte, systems: ["gb", "gbc"], extensions: ["gb", "gbc", "dmg"]),
        Core(id: SECoreIDMGBA, systems: ["gba"], extensions: ["gba"]),
        Core(id: SECoreIDGenesisPlusGX, systems: ["genesis"], extensions: ["md", "gen", "smd", "bin", "mdx"]),
        // Sega CD discs: `.cue`/`.chd`/`.iso` aren't claimed by extension (PS1 uses them too), so the
        // console decides. Needs bios_CD_U/E/J.bin in the system directory.
        Core(id: SECoreIDGenesisPlusGX, systems: ["segacd"], extensions: []),
        Core(id: SECoreIDPicoDrive, systems: ["sega32x"], extensions: ["32x"]),
    ]

    /// Every ROM extension some linked core can run (for library import filters).
    static let supportedExtensions: Set<String> = cores.reduce(into: []) { $0.formUnion($1.extensions) }

    static func core(forSystem system: String) -> Core? {
        cores.first { $0.systems.contains(system.lowercased()) }
    }

    static func core(forExtension ext: String) -> Core? {
        cores.first { $0.extensions.contains(ext.lowercased()) }
    }

    /// Core for a ROM: by file extension, then by console name, else Snes9x.
    static func coreID(for romURL: URL, console: String? = nil) -> String {
        (core(forExtension: romURL.pathExtension) ?? console.flatMap { core(forSystem: $0) })?.id
            ?? SECoreIDSnes9x
    }
}
