import Foundation
@testable import SupersEmuKit
import XCTest

final class BundledCheatCatalogTests: XCTestCase {
    private let catalogJSON = """
    {"version":1,"systems":{"gb":{"revisions":{
      "TARGET":{"family":"Game (USA)"},
      "FIRST":{"cheats":[["More lives","991-56F-E03","771-5BF"]]},
      "SECOND":{"cheats":[["More lives","991-56F-E03","771-5BF-70A"],["No compare","991-56F"]]},
      "THIRD":{"cheats":[["More lives","881-56F-E03"],["Next effect","661-5BF-70A"]]},
      "FOREIGN":{"cheats":[["Unrelated","661-56F-E03"]]}
    },"families":{"Game (USA)":["FIRST","SECOND","THIRD"]}},
    "gbc":{"revisions":{
      "FIRST":{"family":"Color Game"},
      "COLOR":{"cheats":[["More color","991-56F-E03"]]}
    },"families":{"Color Game":["COLOR"]}},
    "snes":{"revisions":{"SNES":{"cheats":[["Example","C2C3-CF0D"]]}}, "families":{}},
    "genesis":{"revisions":{"GENESIS":{"cheats":[["Example","RFAA-A6VR"]]}}, "families":{}}}}
    """

    private func cartridge() -> Data {
        var rom = Data(count: 0xC000)
        rom[0x147] = 0x03
        rom[0x156] = 0x42
        rom[0x15B] = 0x24
        return rom
    }

    private func catalog() throws -> BundledCheatCatalog {
        try JSONDecoder().decode(BundledCheatCatalog.self, from: Data(catalogJSON.utf8))
    }

    func testGameBoyCompareAndMapperEligibleBanks() throws {
        let patch = try XCTUnwrap(GameBoyGeniePatch("991-56F-E03"))
        XCTAssertEqual(patch.address, 0x156)
        XCTAssertEqual(patch.value, 0x99)
        XCTAssertEqual(patch.compare, 0x42)
        XCTAssertNil(GameBoyGeniePatch("991-56F")?.compare)

        var rom = cartridge()
        rom[0x8000] = 0x42
        XCTAssertTrue(GameBoyGeniePatch.verifies(["990-00B-E03"], in: rom))
        rom[0x156] = 0
        rom[0x8156] = 0x42
        XCTAssertFalse(GameBoyGeniePatch.verifies(["991-56F-E03"], in: rom))

        rom[0x147] = 0x22
        XCTAssertFalse(GameBoyGeniePatch.verifies(["990-00B-E03"], in: rom))
    }

    func testFallbackTriesRevisionsInOrderAndRequiresEveryComponent() throws {
        let rom = cartridge()
        let catalog = try catalog()
        let matches = catalog.resolve(system: .gb, rom: rom) { _ in "target" }
        XCTAssertEqual(matches.map(\.label), ["More lives", "Next effect"])
        XCTAssertEqual(matches.map(\.codes), [["991-56F-E03", "771-5BF-70A"], ["661-5BF-70A"]])
        XCTAssertEqual(matches.map(\.quality), [.verifiedOnROM, .verifiedOnROM])

        var changed = rom
        changed[0x15B] = 0
        let next = catalog.resolve(system: .gb, rom: changed) { _ in "TARGET" }
        XCTAssertEqual(next.map(\.codes), [["881-56F-E03"]])
        XCTAssertTrue(catalog.resolve(system: .gb, rom: rom) { _ in "unknown" }.isEmpty)
    }

    func testExactCatalogAssociationDoesNotSubstituteOtherCodes() throws {
        let matches = try catalog().resolve(system: .gb, rom: cartridge()) { _ in "FIRST" }
        XCTAssertEqual(matches.map(\.quality), [.exactROM])
        XCTAssertEqual(matches.map(\.codes), [["991-56F-E03", "771-5BF"]])
    }

    func testCopierHeaderAndInterleavedROMsUseNormalizedBytes() throws {
        let catalog = try catalog()
        let snes = Data(repeating: 0x7F, count: 1024)
        let header = Data(repeating: 0xFF, count: 512)
        XCTAssertEqual(catalog.resolve(system: .snes, rom: header + snes) { $0 == snes ? "SNES" : "" }.count, 1)

        let sega = Data([UInt8](repeating: 0x01, count: 0x2000) + [UInt8](repeating: 0x02, count: 0x2000))
        let normalized = Data(Array(repeating: [UInt8(0x02), 0x01], count: 0x2000).joined())
        XCTAssertEqual(catalog.resolve(system: .genesis, rom: header + sega) { $0 == normalized ? "GENESIS" : "" }.count, 1)
    }

    func testDualModeCartridgesTryBothGameBoyCatalogs() throws {
        var rom = cartridge()
        rom[0x143] = 0x80
        let catalog = try catalog()
        XCTAssertEqual(catalog.resolve(system: .gbc, rom: rom) { _ in "FIRST" }.map(\.quality), [.exactROM])
        XCTAssertEqual(catalog.resolve(system: .gb, rom: rom) { _ in "COLOR" }.map(\.quality), [.exactROM])
        XCTAssertEqual(catalog.resolve(system: .gbc, rom: rom) { _ in "TARGET" }.map(\.quality),
                       [.verifiedOnROM, .verifiedOnROM])
    }

    func testOversizedSegaROMIsNotHashedOrNormalized() throws {
        let catalog = try catalog()
        for (system, megabytes) in [(SystemID.genesis, 16), (.sega32x, 4)] {
            let limit = megabytes * 1024 * 1024 + 512
            XCTAssertEqual(BundledCheatCatalog.maximumROMSize(for: system), limit)
            let rom = Data(count: limit + 0x4000)
            var hashedSizes = [Int]()
            let matches = catalog.resolve(system: system, rom: rom) {
                hashedSizes.append($0.count)
                return ""
            }
            XCTAssertTrue(matches.isEmpty)
            XCTAssertTrue(hashedSizes.isEmpty, "Hashed \(hashedSizes)")
        }
    }

    func testCatalogRejectsAnEmptyCodeGroup() {
        let invalid = catalogJSON.replacingOccurrences(of: "[\"Example\",\"C2C3-CF0D\"]", with: "[\"Example\"]")
        XCTAssertThrowsError(try JSONDecoder().decode(BundledCheatCatalog.self, from: Data(invalid.utf8)))
    }

    func testRejectedCompoundIsRemovedBeforeOtherCheatsAreReapplied() {
        var calls = [[String]]()
        let outcomes = CheatApplicationOutcome.replace([["first", "bad"], ["manual"], ["other"]], system: .n64) { codes in
            calls.append(codes)
            return codes.map {
                switch $0 {
                case "bad": .rejected
                case "manual": .sent
                default: .applied
                }
            }
        }
        XCTAssertEqual(calls, [["first", "bad", "manual", "other"], ["manual", "other"]])
        XCTAssertEqual(outcomes, [.rejected, .sent, .applied])
    }

    func testLastGenesisWriteWinsAndSupersededComponentsRemainApplied() {
        let a = "001000:AB09"
        let b = "001001:AB0A"
        let c = "001002:AB0B"
        let outcomes = CheatApplicationOutcome.replace([[a], [b, c], [a]], system: .genesis) { codes in
            XCTAssertEqual(codes, [c, a])
            return [.applied, .applied]
        }
        XCTAssertEqual(outcomes, [.applied, .applied, .applied])
    }

    func testDisablingSNESCheatsRestoresByteWithNoDuplicateCoreWrites() {
        let first = "001000:09"
        let last = "7E1000:0A"
        let original: UInt8 = 0x42
        var memory = original
        var saved = [UInt8]()
        func apply(_ codes: [String]) -> [CheatApplicationOutcome] {
            XCTAssertLessThanOrEqual(codes.count, 1)
            for byte in saved { memory = byte }
            saved.removeAll()
            return codes.map { code in
                saved.append(memory)
                memory = UInt8(code.suffix(2), radix: 16)!
                return .applied
            }
        }
        XCTAssertEqual(CheatApplicationOutcome.replace([[first], [last]], system: .snes, send: apply),
                       [.applied, .applied])
        XCTAssertEqual(memory, 0x0A)
        XCTAssertEqual(CheatApplicationOutcome.replace([[first]], system: .snes, send: apply), [.applied])
        XCTAssertEqual(memory, 0x09)
        XCTAssertEqual(CheatApplicationOutcome.replace([], system: .snes, send: apply), [])
        XCTAssertEqual(memory, original)
    }

    func testRejectedCompoundLetsAnEarlierWriteTakeEffect() {
        let first = "7E1000:09"
        let last = "7E1000:0A"
        let rejected = "7E1001:0B"
        var calls = [[String]]()
        let outcomes = CheatApplicationOutcome.replace([[first], [last, rejected]], system: .snes) { codes in
            calls.append(codes)
            return codes.map { $0 == rejected ? .rejected : .applied }
        }
        XCTAssertEqual(calls, [[last, rejected], [first]])
        XCTAssertEqual(outcomes, [.applied, .rejected])
    }
}
