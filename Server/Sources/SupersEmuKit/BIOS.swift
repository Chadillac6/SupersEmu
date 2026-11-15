import Foundation

/// A BIOS/firmware dump a disc core needs (docs/specs/disc-games.md). Matched by MD5, whatever the file is called.
///
/// Hashes are the ones the libretro core docs list:
/// - Beetle PSX: https://docs.libretro.com/library/beetle_psx/#bios
/// - Genesis Plus GX: https://docs.libretro.com/library/genesis_plus_gx/#bios
/// (the same dumps are in libretro-database `dat/System.dat`).
/// Dreamcast (Flycast) and PlayStation 2 (LRPS2/PCSX2) dumps are copied from libretro-database `dat/System.dat`
/// at commit bf825e3ec48d43557ad024da6a7b93e512043525 (the `MetadataCatalog.pinned` commit). Where the core looks
/// for them inside the system directory is `SystemID.biosSubdirectory`.
public struct KnownBIOS: Codable, Sendable, Equatable {
    /// Canonical filename the core looks for in the system directory.
    public var filename: String
    public var system: SystemID
    public var region: String
    /// Needed to play USA games. Other regions' BIOS files are only needed for that region's discs.
    public var required: Bool
    /// Lowercase hex MD5 of the good dump.
    public var md5: String
    public var size: Int64
    /// Shown as its own row in BIOS status. Unlisted dumps (other PS2 BIOS revisions) are still recognised and
    /// stored, and appear in status only once present.
    public var listed: Bool

    public init(filename: String, system: SystemID, region: String, required: Bool, md5: String, size: Int64, listed: Bool = true) {
        self.filename = filename; self.system = system; self.region = region; self.required = required; self.md5 = md5; self.size = size
        self.listed = listed
    }

    /// Where the core looks for this file, relative to the system directory (e.g. `dc/dc_boot.bin`).
    public var relativePath: String { system.biosRelativePath(filename) }

    public static let all: [KnownBIOS] = [
        KnownBIOS(filename: "scph5500.bin", system: .psx, region: "JP", required: false, md5: "8dd7d5296a650fac7319bce665a6a53c", size: 524_288),
        KnownBIOS(filename: "scph5501.bin", system: .psx, region: "US", required: true, md5: "490f666e1afb15b7362b406ed1cea246", size: 524_288),
        KnownBIOS(filename: "scph5502.bin", system: .psx, region: "EU", required: false, md5: "32736f17079d0b2b7024407c39bd3050", size: 524_288),
        KnownBIOS(filename: "bios_CD_U.bin", system: .segacd, region: "US", required: true, md5: "2efd74e3232ff260e371b99f84024f7f", size: 131_072),
        KnownBIOS(filename: "bios_CD_E.bin", system: .segacd, region: "EU", required: false, md5: "e66fa1dc5820d254611fdcdba0662372", size: 131_072),
        KnownBIOS(filename: "bios_CD_J.bin", system: .segacd, region: "JP", required: false, md5: "278a9397d192149e84e820ac621a8edd", size: 131_072),
        // Optional: Flycast boots most games with its built-in HLE BIOS; the real dumps improve compatibility.
        KnownBIOS(filename: "dc_boot.bin", system: .dreamcast, region: "World", required: false, md5: "e10c53c2f8b90bab96ead2d368858623", size: 2_097_152),
        KnownBIOS(filename: "dc_flash.bin", system: .dreamcast, region: "World", required: false, md5: "0a93f7940c455905bea6e392dfde92a4", size: 131_072),
        // PS2: any one revision boots games from every region, so none is individually required (`requiresBIOS` still
        // gates Play until one is installed). The three v2.30 dumps are listed; every other revision is recognised too.
        KnownBIOS(filename: "ps2-0230a-20080220.bin", system: .ps2, region: "US", required: false, md5: "21038400dc633070a78ad53090c53017", size: 4_194_304),
        KnownBIOS(filename: "ps2-0230e-20080220.bin", system: .ps2, region: "EU", required: false, md5: "dc69f0643a3030aaa4797501b483d6c4", size: 4_194_304),
        KnownBIOS(filename: "ps2-0230j-20080220.bin", system: .ps2, region: "JP", required: false, md5: "80ac46fa7e77b8ab4366e86948e54f83", size: 4_194_304),
        KnownBIOS(filename: "ps2-0100jd-20000117.bin", system: .ps2, region: "JP (dev)", required: false, md5: "32f2e4d5ff5ee11072a6bc45530f5765", size: 4_194_304, listed: false),
        KnownBIOS(filename: "ps2-0100j-20000117.bin", system: .ps2, region: "JP", required: false, md5: "acf4730ceb38ac9d8c7d8e21f2614600", size: 4_194_304, listed: false),
        KnownBIOS(filename: "ps2-0101jd-20000217.bin", system: .ps2, region: "JP (dev)", required: false, md5: "acf9968c8f596d2b15f42272082513d1", size: 4_194_304, listed: false),
        KnownBIOS(filename: "ps2-0101j-20000217.bin", system: .ps2, region: "JP", required: false, md5: "b1459d7446c69e3e97e6ace3ae23dd1c", size: 4_194_304, listed: false),
        KnownBIOS(filename: "ps2-0101xd-20000224.bin", system: .ps2, region: "Other (dev)", required: false, md5: "d3f1853a16c2ec18f3cd1ae655213308", size: 4_194_304, listed: false),
        KnownBIOS(filename: "ps2-0110ad-20000727.bin", system: .ps2, region: "US (dev)", required: false, md5: "63e6fd9b3c72e0d7b920e80cf76645cd", size: 4_194_304, listed: false),
        KnownBIOS(filename: "ps2-0110a-20000727.bin", system: .ps2, region: "US", required: false, md5: "a20c97c02210f16678ca3010127caf36", size: 4_194_304, listed: false),
        KnownBIOS(filename: "ps2-0120a-20000902.bin", system: .ps2, region: "US", required: false, md5: "8db2fbbac7413bf3e7154c1e0715e565", size: 4_194_304, listed: false),
        KnownBIOS(filename: "ps2-0120ed-20000902.bin", system: .ps2, region: "EU (dev)", required: false, md5: "91c87cb2f2eb6ce529a2360f80ce2457", size: 4_194_304, listed: false),
        KnownBIOS(filename: "ps2-0120ed-20000902-20030110.bin", system: .ps2, region: "EU (dev)", required: false, md5: "3016b3dd42148a67e2c048595ca4d7ce", size: 4_194_304, listed: false),
        KnownBIOS(filename: "ps2-0120e-20000902.bin", system: .ps2, region: "EU", required: false, md5: "b7fa11e87d51752a98b38e3e691cbf17", size: 4_194_304, listed: false),
        KnownBIOS(filename: "ps2-0120j-20001027-185015.bin", system: .ps2, region: "JP", required: false, md5: "f63bc530bd7ad7c026fcd6f7bd0d9525", size: 4_194_304, listed: false),
        KnownBIOS(filename: "ps2-0120j-20001027-191435.bin", system: .ps2, region: "JP", required: false, md5: "cee06bd68c333fc5768244eae77e4495", size: 4_194_304, listed: false),
        KnownBIOS(filename: "ps2-0150ad-20001228-20030520.bin", system: .ps2, region: "US (dev)", required: false, md5: "0bf988e9c7aaa4c051805b0fa6eb3387", size: 4_194_304, listed: false),
        KnownBIOS(filename: "ps2-0150a-20001228.bin", system: .ps2, region: "US", required: false, md5: "8accc3c49ac45f5ae2c5db0adc854633", size: 4_194_304, listed: false),
        KnownBIOS(filename: "ps2-0150ed-20001228-20030520.bin", system: .ps2, region: "EU (dev)", required: false, md5: "6f9a6feb749f0533aaae2cc45090b0ed", size: 4_194_304, listed: false),
        KnownBIOS(filename: "ps2-0150e-20001228.bin", system: .ps2, region: "EU", required: false, md5: "838544f12de9b0abc90811279ee223c8", size: 4_194_304, listed: false),
        KnownBIOS(filename: "ps2-0150jd-20010118.bin", system: .ps2, region: "JP (dev)", required: false, md5: "bb6bbc850458fff08af30e969ffd0175", size: 4_194_304, listed: false),
        KnownBIOS(filename: "ps2-0150j-20010118.bin", system: .ps2, region: "JP", required: false, md5: "815ac991d8bc3b364696bead3457de7d", size: 4_194_304, listed: false),
        KnownBIOS(filename: "ps2-0160a-20010427.bin", system: .ps2, region: "US", required: false, md5: "b107b5710042abe887c0f6175f6e94bb", size: 4_194_304, listed: false),
        KnownBIOS(filename: "ps2-0160j-20010427.bin", system: .ps2, region: "JP", required: false, md5: "ab55cceea548303c22c72570cfd4dd71", size: 4_194_304, listed: false),
        KnownBIOS(filename: "ps2-0160a-20010704.bin", system: .ps2, region: "US", required: false, md5: "18bcaadb9ff74ed3add26cdf709fff2e", size: 4_194_304, listed: false),
        KnownBIOS(filename: "ps2-0160e-20010704.bin", system: .ps2, region: "EU", required: false, md5: "491209dd815ceee9de02dbbc408c06d6", size: 4_194_304, listed: false),
        KnownBIOS(filename: "ps2-0160a-20011004.bin", system: .ps2, region: "US", required: false, md5: "7200a03d51cacc4c14fcdfdbc4898431", size: 4_194_304, listed: false),
        KnownBIOS(filename: "ps2-0160e-20011004.bin", system: .ps2, region: "EU", required: false, md5: "8359638e857c8bc18c3c18ac17d9cc3c", size: 4_194_304, listed: false),
        KnownBIOS(filename: "ps2-0160h-20010730.bin", system: .ps2, region: "Asia", required: false, md5: "352d2ff9b3f68be7e6fa7e6dd8389346", size: 4_194_304, listed: false),
        KnownBIOS(filename: "ps2-0160a-20020207.bin", system: .ps2, region: "US", required: false, md5: "d5ce2c7d119f563ce04bc04dbc3a323e", size: 4_194_304, listed: false),
        KnownBIOS(filename: "ps2-0160e-20020319.bin", system: .ps2, region: "EU", required: false, md5: "0d2228e6fd4fb639c9c39d077a9ec10c", size: 4_194_304, listed: false),
        KnownBIOS(filename: "ps2-0160j-20020426.bin", system: .ps2, region: "JP", required: false, md5: "72da56fccb8fcd77bba16d1b6f479914", size: 4_194_304, listed: false),
        KnownBIOS(filename: "ps2-0160e-20020426.bin", system: .ps2, region: "EU", required: false, md5: "5b1f47fbeb277c6be2fccdd6344ff2fd", size: 4_194_304, listed: false),
        KnownBIOS(filename: "ps2-0160h-20020426.bin", system: .ps2, region: "Asia", required: false, md5: "315a4003535dfda689752cb25f24785c", size: 4_194_304, listed: false),
        KnownBIOS(filename: "ps2-0170j-20030206.bin", system: .ps2, region: "JP", required: false, md5: "312ad4816c232a9606e56f946bc0678a", size: 4_194_304, listed: false),
        KnownBIOS(filename: "ps2-0170ed-20030227.bin", system: .ps2, region: "EU (dev)", required: false, md5: "666018ffec65c5c7e04796081295c6c7", size: 4_194_304, listed: false),
        KnownBIOS(filename: "ps2-0170e-20030227.bin", system: .ps2, region: "EU", required: false, md5: "6e69920fa6eef8522a1d688a11e41bc6", size: 4_194_304, listed: false),
        KnownBIOS(filename: "ps2-0170ad-20030325.bin", system: .ps2, region: "US (dev)", required: false, md5: "eb960de68f0c0f7f9fa083e9f79d0360", size: 4_194_304, listed: false),
        KnownBIOS(filename: "ps2-0170a-20030325.bin", system: .ps2, region: "US", required: false, md5: "8aa12ce243210128c5074552d3b86251", size: 4_194_304, listed: false),
        KnownBIOS(filename: "ps2-0180cd-20030224.bin", system: .ps2, region: "CN (dev)", required: false, md5: "240d4c5ddd4b54069bdc4a3cd2faf99d", size: 4_194_304, listed: false),
        KnownBIOS(filename: "ps2-0180j-20031028.bin", system: .ps2, region: "JP", required: false, md5: "1c6cd089e6c83da618fbf2a081eb4888", size: 4_194_304, listed: false),
        KnownBIOS(filename: "ps2-0190j-20030623.bin", system: .ps2, region: "JP", required: false, md5: "463d87789c555a4a7604e97d7db545d1", size: 4_194_304, listed: false),
        KnownBIOS(filename: "ps2-0190a-20030623.bin", system: .ps2, region: "US", required: false, md5: "35461cecaa51712b300b2d6798825048", size: 4_194_304, listed: false),
        KnownBIOS(filename: "ps2-0190e-20030623.bin", system: .ps2, region: "EU", required: false, md5: "bd6415094e1ce9e05daabe85de807666", size: 4_194_304, listed: false),
        KnownBIOS(filename: "ps2-0190h-20030623.bin", system: .ps2, region: "Asia", required: false, md5: "2e70ad008d4ec8549aada8002fdf42fb", size: 4_194_304, listed: false),
        KnownBIOS(filename: "ps2-0190r-20030623.bin", system: .ps2, region: "RU", required: false, md5: "b53d51edc7fc086685e31b811dc32aad", size: 4_194_304, listed: false),
        KnownBIOS(filename: "ps2-0190c-20030623.bin", system: .ps2, region: "CN", required: false, md5: "1b6e631b536247756287b916f9396872", size: 4_194_304, listed: false),
        KnownBIOS(filename: "ps2-0190j-20030822.bin", system: .ps2, region: "JP", required: false, md5: "00da1b177096cfd2532c8fa22b43e667", size: 4_194_304, listed: false),
        KnownBIOS(filename: "ps2-0190e-20030822.bin", system: .ps2, region: "EU", required: false, md5: "afde410bd026c16be605a1ae4bd651fd", size: 4_194_304, listed: false),
        KnownBIOS(filename: "ps2-0190a-20040329.bin", system: .ps2, region: "US", required: false, md5: "81f4336c1de607dd0865011c0447052e", size: 4_194_304, listed: false),
        KnownBIOS(filename: "ps2-0200j-20040614.bin", system: .ps2, region: "JP", required: false, md5: "0eee5d1c779aa50e94edd168b4ebf42e", size: 4_194_304, listed: false),
        KnownBIOS(filename: "ps2-0200a-20040614.bin", system: .ps2, region: "US", required: false, md5: "d333558cc14561c1fdc334c75d5f37b7", size: 4_194_304, listed: false),
        KnownBIOS(filename: "ps2-0200e-20040614.bin", system: .ps2, region: "EU", required: false, md5: "dc752f160044f2ed5fc1f4964db2a095", size: 4_194_304, listed: false),
        KnownBIOS(filename: "ps2-0200ed-20040614.bin", system: .ps2, region: "EU (dev)", required: false, md5: "63ead1d74893bf7f36880af81f68a82d", size: 4_194_304, listed: false),
        KnownBIOS(filename: "ps2-0200h-20040614.bin", system: .ps2, region: "Asia", required: false, md5: "3e3e030c0f600442fa05b94f87a1e238", size: 4_194_304, listed: false),
        KnownBIOS(filename: "ps2-0210j-20040917.bin", system: .ps2, region: "JP", required: false, md5: "1ad977bb539fc9448a08ab276a836bbc", size: 4_194_304, listed: false),
        KnownBIOS(filename: "ps2-0220j-20050620.bin", system: .ps2, region: "JP", required: false, md5: "eb4f40fcf4911ede39c1bbfe91e7a89a", size: 4_194_304, listed: false),
        KnownBIOS(filename: "ps2-0220ad-20050620.bin", system: .ps2, region: "US (dev)", required: false, md5: "9959ad7a8685cad66206e7752ca23f8b", size: 4_194_304, listed: false),
        KnownBIOS(filename: "ps2-0220a-20050620.bin", system: .ps2, region: "US", required: false, md5: "929a14baca1776b00869f983aa6e14d2", size: 4_194_304, listed: false),
        KnownBIOS(filename: "ps2-0220e-20050620.bin", system: .ps2, region: "EU", required: false, md5: "573f7d4a430c32b3cc0fd0c41e104bbd", size: 4_194_304, listed: false),
        KnownBIOS(filename: "ps2-0220h-20050620.bin", system: .ps2, region: "Asia", required: false, md5: "df63a604e8bff5b0599bd1a6c2721bd0", size: 4_194_304, listed: false),
        KnownBIOS(filename: "ps2-0220j-20060210.bin", system: .ps2, region: "JP", required: false, md5: "5b1ba4bb914406fae75ab8e38901684d", size: 4_194_304, listed: false),
        KnownBIOS(filename: "ps2-0220a-20060210.bin", system: .ps2, region: "US", required: false, md5: "cb801b7920a7d536ba07b6534d2433ca", size: 4_194_304, listed: false),
        KnownBIOS(filename: "ps2-0220e-20060210.bin", system: .ps2, region: "EU", required: false, md5: "af60e6d1a939019d55e5b330d24b1c25", size: 4_194_304, listed: false),
        KnownBIOS(filename: "ps2-0220h-20060210.bin", system: .ps2, region: "Asia", required: false, md5: "549a66d0c698635ca9fa3ab012da7129", size: 4_194_304, listed: false),
        KnownBIOS(filename: "ps2-0220j-20060905.bin", system: .ps2, region: "JP", required: false, md5: "5de9d0d730ff1e7ad122806335332524", size: 4_194_304, listed: false),
        KnownBIOS(filename: "ps2-0220ad-20060905.bin", system: .ps2, region: "US (dev)", required: false, md5: "21fe4cad111f7dc0f9af29477057f88d", size: 4_194_304, listed: false),
        KnownBIOS(filename: "ps2-0220a-20060905.bin", system: .ps2, region: "US", required: false, md5: "40c11c063b3b9409aa5e4058e984e30c", size: 4_194_304, listed: false),
        KnownBIOS(filename: "ps2-0220e-20060905.bin", system: .ps2, region: "EU", required: false, md5: "80bbb237a6af9c611df43b16b930b683", size: 4_194_304, listed: false),
        KnownBIOS(filename: "ps2-0220h-20060905.bin", system: .ps2, region: "Asia", required: false, md5: "c37bce95d32b2be480f87dd32704e664", size: 4_194_304, listed: false),
        KnownBIOS(filename: "ps2-0230h-20080220.bin", system: .ps2, region: "Asia", required: false, md5: "30d56e79d89fbddf10938fa67fe3f34e", size: 4_194_304, listed: false),
        KnownBIOS(filename: "ps2-0250e-20100415.bin", system: .ps2, region: "EU", required: false, md5: "93ea3bcee4252627919175ff1b16a1d9", size: 4_194_304, listed: false),
        KnownBIOS(filename: "ps2-0250j-20100415.bin", system: .ps2, region: "JP", required: false, md5: "d3e81e95db25f5a86a7b7474550a2155", size: 4_194_304, listed: false),
    ]
}

public extension SystemID {
    /// Folder inside the core system directory where this system's BIOS files go, or nil for the top level.
    /// The single place to change if a core expects a different layout:
    /// - Flycast reads `dc/dc_boot.bin` and `dc/dc_flash.bin` (libretro System.dat names them `dc/...`).
    /// - LRPS2/PCSX2 scans `pcsx2/bios/` for any BIOS image (System.dat names them `pcsx2/bios/...`).
    var biosSubdirectory: String? {
        switch self {
        case .dreamcast: "dc"
        case .ps2: "pcsx2/bios"
        default: nil
        }
    }

    /// The core accepts any file name in `biosSubdirectory` (LRPS2 scans the folder), so user-placed dumps are matched by content.
    var biosMatchedByContent: Bool { self == .ps2 }

    func biosRelativePath(_ filename: String) -> String {
        biosSubdirectory.map { "\($0)/\(filename)" } ?? filename
    }
}

/// One row of `supersemu bios status`: a known BIOS and whether the server has a good copy.
public struct BIOSStatus: Codable, Sendable, Equatable {
    public enum State: String, Codable, Sendable {
        case present, missing
        /// A file named like this BIOS was imported, but its hash isn't the known good dump.
        case wrongHash = "wrong-hash"
    }

    public var system: SystemID
    public var filename: String
    public var region: String
    public var required: Bool
    public var state: State
    /// SHA-256 of the stored file (present) or of the rejected file (wrong-hash).
    public var sha256: String?

    public init(system: SystemID, filename: String, region: String, required: Bool, state: State, sha256: String?) {
        self.system = system; self.filename = filename; self.region = region; self.required = required; self.state = state; self.sha256 = sha256
    }
}

extension APIClient {
    /// Verified BIOS files on the server (`library:read`).
    public func bios() async throws -> [BIOSFileInfo] { try await get("/v1/bios") }
    /// Present / missing / wrong-hash for every known BIOS (`library:read`).
    public func biosStatus() async throws -> [BIOSStatus] { try await get("/v1/bios/status") }
    /// Download path for one BIOS file; supports HTTP Range and `If-None-Match` like game files.
    public func biosPath(sha256: String) -> String { "/v1/bios/\(sha256)" }
    public func biosData(sha256: String) async throws -> Data { try await raw("GET", biosPath(sha256: sha256)) }
}
