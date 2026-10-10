import Foundation
import SupersEmuKit

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
        // Disc games: the host passes the path (need_fullpath); a .cue's tracks sit beside it.
        Core(id: SECoreIDBeetlePSX, systems: ["psx"], extensions: ["cue", "chd", "m3u"]),
        // Sega CD discs: `.cue`/`.chd`/`.iso` aren't claimed by extension (PS1 uses them too), so the
        // console decides. Needs bios_CD_U/E/J.bin in the system directory.
        Core(id: SECoreIDGenesisPlusGX, systems: ["segacd"], extensions: []),
        Core(id: SECoreIDPicoDrive, systems: ["sega32x"], extensions: ["32x"]),
        Core(id: SECoreIDMupen64PlusNext, systems: ["n64"], extensions: ["z64", "n64", "v64"]),
    ]

    /// Sheets that reference other files (tracks, discs). Copying one alone breaks the game, so
    /// these come in through the server importer, which groups the referenced files.
    static let multiFileExtensions: Set<String> = ["cue", "m3u"]

    /// Every ROM extension some linked core can run (for library import filters).
    static let supportedExtensions: Set<String> = cores.reduce(into: []) { $0.formUnion($1.extensions) }

    static func core(forSystem system: String) -> Core? {
        cores.first { $0.systems.contains(system.lowercased()) }
    }

    static func core(forExtension ext: String) -> Core? {
        cores.first { $0.extensions.contains(ext.lowercased()) }
    }

    /// `SystemID` raw value for a console given as raw value ("segacd") or display name ("Sega CD").
    static func systemID(forConsole console: String) -> String? {
        SystemID.allCases.first { $0.rawValue == console.lowercased() || $0.displayName == console }?.rawValue
    }

    /// Core for a ROM: by known console first (`.bin`/`.cue` are ambiguous across systems), then by
    /// file extension, else Snes9x.
    static func coreID(for romURL: URL, console: String? = nil) -> String {
        (console.flatMap(systemID(forConsole:)).flatMap(core(forSystem:))
            ?? core(forExtension: romURL.pathExtension))?.id
            ?? SECoreIDSnes9x
    }
}
