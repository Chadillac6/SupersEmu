import CryptoKit
import Foundation
import SupersEmuKit

actor BundledCheatLibrary {
    static let shared = BundledCheatLibrary()

    private lazy var catalog: BundledCheatCatalog? = {
        guard let url = Bundle.main.url(forResource: "GameGenieCatalog", withExtension: "json"),
              let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return nil }
        return try? JSONDecoder().decode(BundledCheatCatalog.self, from: data)
    }()
    private var bySystem: [SystemID: [String: [BundledCheat]]] = [:]

    func matches(gameID: String, system: SystemID, romURL: URL) -> [BundledCheat] {
        guard BundledCheatCatalog.supports(system) else { return [] }
        if let cached = bySystem[system]?[gameID] { return cached }
        guard let catalog, let rom = try? Data(contentsOf: romURL, options: .mappedIfSafe) else { return [] }
        let matches = catalog.resolve(system: system, rom: rom) { Insecure.SHA1.hash(data: $0).hexString }
            .map { BundledCheat(gameID: gameID, match: $0) }
        bySystem[system, default: [:]][gameID] = matches
        return matches
    }
}

struct BundledCheat: Identifiable, Sendable {
    let id: UUID
    let match: BundledCheatCatalog.Match

    init(gameID: String, match: BundledCheatCatalog.Match) {
        self.match = match
        let key = ["SupersEmu.GameGenie", gameID] + match.codes
        var bytes = Array(SHA256.hash(data: Data(key.joined(separator: "\n").utf8)).prefix(16))
        bytes[6] = (bytes[6] & 0x0F) | 0x80
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        id = UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                         bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
    }

    private static let selectionCode = "SupersEmu:bundled"

    static func isSelection(_ record: CheatRecord) -> Bool {
        record.format == .unknown && record.code == selectionCode
    }

    func selection(gameID: String, enabled: Bool) -> CheatRecord {
        CheatRecord(id: id, gameID: gameID, label: String(match.label.prefix(120)),
                    code: Self.selectionCode, format: .unknown, enabled: enabled)
    }
}
