import Foundation

/// A BIOS/firmware dump a disc core needs (docs/specs/disc-games.md). Matched by MD5, whatever the file is called.
///
/// Hashes are the ones the libretro core docs list:
/// - Beetle PSX: https://docs.libretro.com/library/beetle_psx/#bios
/// - Genesis Plus GX: https://docs.libretro.com/library/genesis_plus_gx/#bios
/// (the same dumps are in libretro-database `dat/System.dat`).
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

    public init(filename: String, system: SystemID, region: String, required: Bool, md5: String, size: Int64) {
        self.filename = filename; self.system = system; self.region = region; self.required = required; self.md5 = md5; self.size = size
    }

    public static let all: [KnownBIOS] = [
        KnownBIOS(filename: "scph5500.bin", system: .psx, region: "JP", required: false, md5: "8dd7d5296a650fac7319bce665a6a53c", size: 524_288),
        KnownBIOS(filename: "scph5501.bin", system: .psx, region: "US", required: true, md5: "490f666e1afb15b7362b406ed1cea246", size: 524_288),
        KnownBIOS(filename: "scph5502.bin", system: .psx, region: "EU", required: false, md5: "32736f17079d0b2b7024407c39bd3050", size: 524_288),
        KnownBIOS(filename: "bios_CD_U.bin", system: .segacd, region: "US", required: true, md5: "2efd74e3232ff260e371b99f84024f7f", size: 131_072),
        KnownBIOS(filename: "bios_CD_E.bin", system: .segacd, region: "EU", required: false, md5: "e66fa1dc5820d254611fdcdba0662372", size: 131_072),
        KnownBIOS(filename: "bios_CD_J.bin", system: .segacd, region: "JP", required: false, md5: "278a9397d192149e84e820ac621a8edd", size: 131_072),
    ]
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
