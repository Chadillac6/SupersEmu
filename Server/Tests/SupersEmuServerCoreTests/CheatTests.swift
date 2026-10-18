import Foundation
import GRDB
import Hummingbird
import HummingbirdTesting
import SupersEmuKit
@testable import SupersEmuServerCore
import XCTest

final class CheatCodecTests: XCTestCase {
    func testSNESGameGenieMatchesSnes9xDecoder() {
        // Expected values come from Snes9x's own S9xGameGenieToRaw (Vendor/cores/snes9x/cheats2.cpp).
        XCTAssertEqual(CheatCodec.parse("C2C3-CF0D", system: .snes), .valid(format: .snesGameGenie, normalized: "C2C3-CF0D", address: 0x80A2E5, value: 0xAD))
        XCTAssertEqual(CheatCodec.parse("DD32-6DAD", system: .snes), .valid(format: .snesGameGenie, normalized: "DD32-6DAD", address: 0x00E2D3, value: 0x00))
        XCTAssertEqual(CheatCodec.parse("1234-5678", system: .snes), .valid(format: .snesGameGenie, normalized: "1234-5678", address: 0xEEED20, value: 0x6D))
    }

    func testNormalizesLowercaseSpacesAndMissingDash() {
        XCTAssertEqual(CheatCodec.parse(" c2c3cf0d ", system: .snes).normalized, "C2C3-CF0D")
        XCTAssertTrue(CheatCodec.parse("c2c3 cf0d", system: .snes).isValid)
        XCTAssertEqual(CheatCodec.parse("rfaaa6vr", system: .genesis).normalized, "RFAA-A6VR")
        XCTAssertEqual(CheatCodec.parse("000000", system: .gb).normalized, "000-000")
        XCTAssertEqual(CheatCodec.parse("000000000", system: .gbc).normalized, "000-000-000")
        XCTAssertEqual(CheatCodec.parse("01001234", system: .gb).normalized, "01001234")
        XCTAssertEqual(CheatCodec.parse("12345678abcdef01", system: .gba).normalized, "12345678 ABCDEF01")
        XCTAssertEqual(CheatCodec.parse("12345678abcd", system: .n64).normalized, "12345678 ABCD")
        XCTAssertEqual(CheatCodec.normalize("12345678abcd,12345678ABCDEF01", system: .gba),
                       "12345678 ABCD\n12345678 ABCDEF01")
    }

    func testSNESInvalidCodesExplainWhy() {
        guard case .invalid(let reason) = CheatCodec.parse("C2C3-CFOD", system: .snes) else { return XCTFail() }
        XCTAssertTrue(reason.contains("\"O\""), reason)
        guard case .invalid(let short) = CheatCodec.parse("C2C3-CF0", system: .snes) else { return XCTFail() }
        XCTAssertTrue(short.contains("Wrong length"), short)
        guard case .invalid = CheatCodec.parse("", system: .snes) else { return XCTFail() }
    }

    func testGenesisGameGenie() {
        guard case .valid(let format, let code, _, _) = CheatCodec.parse("RFAA-A6VR", system: .genesis) else { return XCTFail() }
        XCTAssertEqual(format, .genesisGameGenie)
        XCTAssertEqual(code, "RFAA-A6VR")
        // I, O, Q and U are not in the Genesis alphabet.
        guard case .invalid = CheatCodec.parse("RFAA-A6VO", system: .genesis) else { return XCTFail() }
    }

    func testWrongSystemAndActionReplayAreUnsupportedNotInvalid() {
        guard case .unsupported(let detected, _, _) = CheatCodec.parse("RFAA-A6VR", system: .snes) else { return XCTFail() }
        XCTAssertEqual(detected, .genesisGameGenie)
        XCTAssertEqual(CheatCodec.parse("7E0DBE:05", system: .snes),
                       .valid(format: .proActionReplay, normalized: "7E0DBE:05", address: 0x7E0DBE, value: 0x05))
        XCTAssertEqual(CheatCodec.parse("FFFE18:0009", system: .genesis),
                       .valid(format: .proActionReplay, normalized: "FFFE18:0009", address: 0xFFFE18, value: 0x0009))
        XCTAssertEqual(CheatCodec.parse("FFFE18:0009", system: .sega32x),
                       .valid(format: .proActionReplay, normalized: "FFFE18:0009", address: 0xFFFE18, value: 0x0009))
        XCTAssertEqual(CheatCodec.parse("FFFE18:0009", system: .segacd),
                       .valid(format: .proActionReplay, normalized: "FFFE18:0009", address: 0xFFFE18, value: 0x0009))
        let discReason = "Game Genie codes patch a cartridge, and Sega CD games run from a disc. Use Pro Action Replay codes (XXXXXX:XXXX)."
        XCTAssertEqual(CheatCodec.parse("RFAA-A6VR", system: .segacd),
                       .unsupported(detected: .genesisGameGenie, normalized: "RFAA-A6VR", reason: discReason))
        XCTAssertEqual(CheatCodec.parse("7E0DBE05", system: .snes).normalized, "7E0D-BE05")
    }

    func testMultilineCodesOnlyForGBAPSXAndN64() {
        XCTAssertEqual(Set(SystemID.allCases.filter(CheatCodec.allowsMultiline)), [.gba, .psx, .n64])
    }

    func testEverySystemHasCheatFormats() {
        XCTAssertTrue(SystemID.allCases.allSatisfy(CheatCodec.supportsCheats))
        XCTAssertEqual(CheatCodec.formats(for: .snes), [.snesGameGenie, .proActionReplay])
        XCTAssertEqual(CheatCodec.formats(for: .genesis), [.genesisGameGenie, .proActionReplay])
        XCTAssertEqual(CheatCodec.formats(for: .sega32x), [.genesisGameGenie, .proActionReplay])
        XCTAssertEqual(CheatCodec.formats(for: .segacd), [.proActionReplay])
        XCTAssertEqual(CheatCodec.formats(for: .gb), [.gbGameGenie, .gbGameShark])
        XCTAssertEqual(CheatCodec.formats(for: .gbc), [.gbGameGenie, .gbGameShark])
        XCTAssertEqual(CheatCodec.formats(for: .gba), [.gbaCode, .gbaCodeBreaker])
        XCTAssertEqual(CheatCodec.formats(for: .psx), [.psxGameShark])
        XCTAssertEqual(CheatCodec.formats(for: .n64), [.n64GameShark])
        guard case .invalid = CheatCodec.parse("C2C3-CF0D", system: .gba) else { return XCTFail() }
    }

    func testGameBoyFormatsAndGameSharkTypes() {
        XCTAssertEqual(CheatCodec.parse("000-000", system: .gb),
                       .valid(format: .gbGameGenie, normalized: "000-000", address: 0x7000, value: 0))
        XCTAssertEqual(CheatCodec.parse("000-000-000", system: .gbc),
                       .valid(format: .gbGameGenie, normalized: "000-000-000", address: 0x7000, value: 0))
        XCTAssertEqual(CheatCodec.parse("01001234", system: .gb),
                       .valid(format: .gbGameShark, normalized: "01001234", address: 0x1234, value: 0))
        XCTAssertEqual(CheatCodec.parse("00123456", system: .gbc),
                       .unsupported(detected: .gbGameShark, normalized: "00123456",
                                    reason: "Only GameShark codes starting with 01 work for Game Boy."))
        guard case .invalid = CheatCodec.parse("000-00Z", system: .gb) else { return XCTFail() }
    }

    func testGBACodesAndLineNormalization() {
        XCTAssertEqual(CheatCodec.parse("12345678 89abcdef", system: .gba),
                       .valid(format: .gbaCode, normalized: "12345678 89ABCDEF", address: 0x12345678, value: 0xCDEF))
        XCTAssertEqual(CheatCodec.parse("12345678 abcd", system: .gba),
                       .valid(format: .gbaCodeBreaker, normalized: "12345678 ABCD", address: 0x12345678, value: 0xABCD))
        XCTAssertEqual(CheatCodec.parse("12345678abcd,12345678abcdef01", system: .gba).normalized,
                       "12345678 ABCD\n12345678 ABCDEF01")
    }

    func testPS1AndN64GameSharkCodesAndLimits() {
        XCTAssertEqual(CheatCodec.parse("8009c6e4 03e7", system: .psx),
                       .valid(format: .psxGameShark, normalized: "8009C6E4 03E7", address: 0x8009C6E4, value: 0x03E7))
        guard case .unsupported(.psxGameShark, _, let psxReason) = CheatCodec.parse("0009C6E4 03E7", system: .psx) else {
            return XCTFail()
        }
        XCTAssertTrue(psxReason.contains("0x00"), psxReason)
        XCTAssertEqual(CheatCodec.parse("8009C6E403E7", system: .n64),
                       .valid(format: .n64GameShark, normalized: "8009C6E4 03E7", address: 0x8009C6E4, value: 0x03E7))
        XCTAssertEqual(CheatCodec.coreCode("8009C6E4 03E7\n8009C6E6 0001"), "8009C6E4 03E7 8009C6E6 0001")
        guard case .invalid(let reason) = CheatCodec.parse(String(repeating: "A", count: 241), system: .n64) else {
            return XCTFail()
        }
        XCTAssertTrue(reason.contains("240"), reason)
    }

    func testBatchTakesNamesFromTheLineAndFallsBackToNumbers() {
        let text = """
        Infinite lives C2C3-CF0D
        DD32-6DAD - Start with 9 lives

        1234-5678
        C2C3-CFOD Broken
        DD32-6DAD+C2C3-CF0D Combo
        """
        let entries = CheatCodec.parseBatch(text, system: .snes, existingCount: 2)
        XCTAssertEqual(entries.map(\.label), ["Infinite lives", "Start with 9 lives", "Cheat 5", "Broken", "Combo", "Combo"])
        XCTAssertEqual(entries.map(\.include), [true, true, true, false, true, true])
        XCTAssertEqual(entries[3].result.isValid, false)
        XCTAssertEqual(entries.map { $0.result.normalized }, ["C2C3-CF0D", "DD32-6DAD", "1234-5678", nil, "DD32-6DAD", "C2C3-CF0D"])
    }

    func testLineBasedBatchGroupsLabelsAndKeepsBareCodesSeparate() {
        let grouped = CheatCodec.parseBatch("""
        Infinite lives
        8009C6E4 03E7
        8009C6E6 0001
        8009C6E8 0002
        """, system: .n64)
        XCTAssertEqual(grouped.count, 1)
        XCTAssertEqual(grouped[0].label, "Infinite lives")
        XCTAssertEqual(grouped[0].result.normalized, "8009C6E4 03E7\n8009C6E6 0001\n8009C6E8 0002")

        let bare = CheatCodec.parseBatch("8009C6E403E7\n8009C6E60001\n8009C6E80002", system: .n64)
        XCTAssertEqual(bare.count, 3)
        XCTAssertEqual(bare.map(\.label), ["Cheat 1", "Cheat 2", "Cheat 3"])
        XCTAssertEqual(bare.map { $0.result.normalized }, ["8009C6E4 03E7", "8009C6E6 0001", "8009C6E8 0002"])
        XCTAssertTrue(bare.allSatisfy { $0.result.isValid })

        let manyBare = CheatCodec.parseBatch(
            Array(repeating: "8009C6E4 03E7", count: 17).joined(separator: "\n"),
            system: .n64)
        XCTAssertEqual(manyBare.count, 17)
        XCTAssertTrue(manyBare.allSatisfy { $0.result.isValid })

        let inline = CheatCodec.parseBatch("8009C6E4 03E7 Infinite lives", system: .n64)
        XCTAssertEqual(inline.count, 1)
        XCTAssertEqual(inline[0].label, "Infinite lives")
        XCTAssertEqual(inline[0].result.normalized, "8009C6E4 03E7")

        let labeledGroups = CheatCodec.parseBatch(
            "Infinite lives\r\n8009C6E4 03E7\r\n8009C6E6 0001\r\n\r\nFast run\r\n8009C6E8 0002",
            system: .n64)
        XCTAssertEqual(labeledGroups.count, 2)
        XCTAssertEqual(labeledGroups.map(\.label), ["Infinite lives", "Fast run"])
        XCTAssertEqual(labeledGroups.map { $0.result.normalized }, ["8009C6E4 03E7\n8009C6E6 0001", "8009C6E8 0002"])

        let nextLabel = CheatCodec.parseBatch(
            "Infinite lives\n8009C6E4 03E7\nFast run\n8009C6E6 0001",
            system: .n64)
        XCTAssertEqual(nextLabel.count, 2)
        XCTAssertEqual(nextLabel.map(\.label), ["Infinite lives", "Fast run"])

        let inlineBoundary = CheatCodec.parseBatch(
            "Infinite lives\n8009C6E4 03E7\n8009C6E6 0001 Fast run",
            system: .n64)
        XCTAssertEqual(inlineBoundary.count, 2)
        XCTAssertEqual(inlineBoundary.map(\.label), ["Infinite lives", "Fast run"])
    }

    func testConditionalBatchCodesJoinCompanionLines() {
        let n64Pair = CheatCodec.parseBatch("D0000000 0001\n8009C6E4 03E7", system: .n64)
        XCTAssertEqual(n64Pair.count, 1)
        XCTAssertEqual(n64Pair.first?.label, "Cheat 1")
        XCTAssertEqual(n64Pair.first?.result.normalized, "D0000000 0001\n8009C6E4 03E7")
        XCTAssertTrue(n64Pair.first?.result.isValid == true)

        let n64Chain = CheatCodec.parseBatch(
            "D0000000 0001\nD1000000 0002\n8009C6E4 03E7",
            system: .n64)
        XCTAssertEqual(n64Chain.count, 1)
        XCTAssertEqual(n64Chain.first?.result.normalized, "D0000000 0001\nD1000000 0002\n8009C6E4 03E7")

        for type in ["D0", "D1", "D2", "D3", "50"] {
            let entries = CheatCodec.parseBatch("\(type)000000 0001\n8009C6E4 03E7", system: .n64)
            XCTAssertEqual(entries.count, 1, "N64 type \(type) should join its companion line")
            XCTAssertEqual(entries.first?.result.normalized, "\(type)000000 0001\n8009C6E4 03E7")
        }

        let namedN64Pair = CheatCodec.parseBatch("D0000000 0001 Infinite lives\n8009C6E4 03E7", system: .n64)
        XCTAssertEqual(namedN64Pair.count, 1)
        XCTAssertEqual(namedN64Pair.first?.label, "Infinite lives")
        XCTAssertEqual(namedN64Pair.first?.result.normalized, "D0000000 0001\n8009C6E4 03E7")

        let psxE0Pair = CheatCodec.parseBatch("E0000000 0001\n8009C6E4 03E7", system: .psx)
        XCTAssertEqual(psxE0Pair.count, 1)
        XCTAssertEqual(psxE0Pair.first?.result.normalized, "E0000000 0001\n8009C6E4 03E7")
        XCTAssertTrue(psxE0Pair.first?.result.isValid == true)

        let psxC2Pair = CheatCodec.parseBatch("C2000000 0001\n8009C6E4 03E7", system: .psx)
        XCTAssertEqual(psxC2Pair.count, 1)
        XCTAssertEqual(psxC2Pair.first?.result.normalized, "C2000000 0001\n8009C6E4 03E7")
        XCTAssertTrue(psxC2Pair.first?.result.isValid == true)

        for type in ["D0", "D1", "D2", "D3", "E0", "E1", "E2", "E3", "50", "C2"] {
            let entries = CheatCodec.parseBatch("\(type)000000 0001\n8009C6E4 03E7", system: .psx)
            XCTAssertEqual(entries.count, 1, "PSX type \(type) should join its companion line")
            XCTAssertEqual(entries.first?.result.normalized, "\(type)000000 0001\n8009C6E4 03E7")
            XCTAssertTrue(entries.first?.result.isValid == true)
        }

        let separated = CheatCodec.parseBatch("D0000000 0001\n\n8009C6E4 03E7", system: .n64)
        XCTAssertEqual(separated.count, 2)
        XCTAssertEqual(separated.map { $0.result.normalized }, ["D0000000 0001", "8009C6E4 03E7"])

        let trailingConditional = CheatCodec.parseBatch("D0000000 0001", system: .n64)
        XCTAssertEqual(trailingConditional.count, 1)
        XCTAssertEqual(trailingConditional.first?.result, CheatCodec.parse("D0000000 0001", system: .n64))
    }

    func testLabeledGBAGroupCombinesLinesButBareLinesStaySeparate() {
        let labeled = CheatCodec.parseBatch("""
        Infinite lives
        80000000 00000001
        80000004 00000002
        """, system: .gba)
        XCTAssertEqual(labeled.count, 1)
        XCTAssertEqual(labeled.first?.label, "Infinite lives")
        XCTAssertEqual(labeled.first?.result.normalized, "80000000 00000001\n80000004 00000002")
        XCTAssertTrue(labeled.first?.result.isValid == true)

        let bare = CheatCodec.parseBatch("80000000 00000001\n80000004 00000002", system: .gba)
        XCTAssertEqual(bare.count, 2)
    }

    func testNewCheatsDefaultToEnabledAndUnknownFormatsDecode() throws {
        let cheat = CheatRecord(gameID: "abc", label: "Lives", code: "C2C3-CF0D", format: .snesGameGenie)
        XCTAssertTrue(cheat.enabled)
        var json = String(decoding: try SupersEmuJSON.encoder().encode(cheat), as: UTF8.self)
        json = json.replacingOccurrences(of: "\"snesGameGenie\"", with: "\"codeBreaker\"")
        json = json.replacingOccurrences(of: "{", with: "{\"futureField\":1,")
        let decoded = try SupersEmuJSON.decoder().decode(CheatRecord.self, from: Data(json.utf8))
        XCTAssertEqual(decoded.format, .unknown)
        XCTAssertEqual(decoded.code, "C2C3-CF0D")
    }
}

final class CheatMergeTests: XCTestCase {
    let t0 = Date(timeIntervalSince1970: 1_000)

    let id = UUID()
    func base() -> CheatRecord { CheatRecord(id: id, gameID: "g", label: "Lives", code: "C2C3-CF0D", format: .snesGameGenie, now: t0) }

    func testDifferentFieldsChangedOnTwoDevicesKeepBoth() {
        var phone = base(), mac = base()
        phone.setLabel("Infinite lives", at: t0 + 10)
        mac.setEnabled(false, at: t0 + 20)
        let merged = CheatMerge.merge(phone, mac)
        XCTAssertEqual(merged.label, "Infinite lives")
        XCTAssertFalse(merged.enabled)
        XCTAssertEqual(CheatMerge.merge(mac, phone), merged)
    }

    func testSameFieldLaterEditWinsAndTiesGoToIncoming() {
        var phone = base(), mac = base()
        phone.setLabel("Phone", at: t0 + 30)
        mac.setLabel("Mac", at: t0 + 20)
        XCTAssertEqual(CheatMerge.merge(phone, mac).label, "Phone")
        XCTAssertEqual(CheatMerge.merge(mac, phone).label, "Phone")
        mac.setLabel("Mac", at: t0 + 30)
        XCTAssertEqual(CheatMerge.merge(phone, mac).label, "Mac")
    }

    func testDeleteBeatsEarlierEditsButLosesToLaterOnes() {
        var deleted = base(), edited = base()
        deleted.markDeleted(at: t0 + 50)
        edited.setEnabled(false, at: t0 + 40)
        XCTAssertTrue(CheatMerge.merge(edited, deleted).deleted)
        XCTAssertTrue(CheatMerge.merge(deleted, edited).deleted)
        edited.setLabel("Revived", at: t0 + 60)
        let revived = CheatMerge.merge(deleted, edited)
        XCTAssertFalse(revived.deleted)
        XCTAssertEqual(revived.label, "Revived")
    }

    func testMergeIsIdempotent() {
        var a = base()
        a.setLabel("x", at: t0 + 5)
        XCTAssertEqual(CheatMerge.merge(a, a), a)
    }

    func testUnknownIncomingFormatPreservesKnownFormatOnlyWhenCodeMatches() {
        var current = base()
        var oldServerEcho = base()
        oldServerEcho.format = .unknown
        oldServerEcho.codeUpdatedAt = t0 + 5
        let sameCode = CheatMerge.merge(current, oldServerEcho)
        XCTAssertEqual(sameCode.code, current.code)
        XCTAssertEqual(sameCode.format, .snesGameGenie)

        var newCode = oldServerEcho
        newCode.setCode("000-000", format: .gbGameGenie, at: t0 + 10)
        let changedCode = CheatMerge.merge(current, newCode)
        XCTAssertEqual(changedCode.code, "000-000")
        XCTAssertEqual(changedCode.format, .gbGameGenie)
    }
}

final class CheatRoutesTests: XCTestCase {
    var store: ServerStore!
    var chad: UserInfo!
    var iPhone: (deviceID: String, token: String)!
    var mac: (deviceID: String, token: String)!
    let game = String(repeating: "ab", count: 32)
    let other = String(repeating: "cd", count: 32)

    override func setUp() async throws {
        store = try ServerStore.inMemory()
        chad = try store.createUser(displayName: "Chad", role: .admin)
        iPhone = try store.createDeviceToken(userID: chad.id, deviceName: "Chad's iPhone")
        mac = try store.createDeviceToken(userID: chad.id, deviceName: "Chad's Mac")
    }

    func app() -> some ApplicationProtocol {
        let router = Router(context: SERequestContext.self)
        registerCheatRoutes(router.group("v1").add(middleware: TokenAuthMiddleware(store: store)), store: store)
        return Application(router: router)
    }

    func bearer(_ token: String) -> HTTPFields { [.authorization: "Bearer \(token)"] }

    func put(_ client: some TestClientProtocol, _ cheat: CheatRecord, token: String, game: String? = nil,
             expect status: HTTPResponse.Status = .ok) async throws -> CheatRecord? {
        let body = try SupersEmuJSON.encoder().encode(cheat)
        return try await client.execute(uri: "/v1/cheats/\(game ?? cheat.gameID)/\(cheat.id.uuidString)", method: .put,
                                        headers: bearer(token), body: ByteBuffer(bytes: body)) { response in
            XCTAssertEqual(response.status, status, String(buffer: response.body))
            return response.status == .ok ? try SupersEmuJSON.decoder().decode(CheatRecord.self, from: Data(buffer: response.body)) : nil
        }
    }

    func changes(_ client: some TestClientProtocol, since: Int, token: String) async throws -> CheatListResponse {
        try await client.execute(uri: "/v1/cheats?since=\(since)", method: .get, headers: bearer(token)) { response in
            XCTAssertEqual(response.status, .ok)
            return try SupersEmuJSON.decoder().decode(CheatListResponse.self, from: Data(buffer: response.body))
        }
    }

    func cheat(_ label: String, game: String? = nil) -> CheatRecord {
        CheatRecord(gameID: game ?? self.game, label: label, code: "C2C3-CF0D", format: .snesGameGenie, now: CheatRecord.now())
    }

    func testPutIsIdempotentAndSinceFilters() async throws {
        try await app().test(.router) { client in
            let lives = self.cheat("Lives")
            let first = try await self.put(client, lives, token: self.iPhone.token)!
            XCTAssertEqual(first.revision, 1)
            let replay = try await self.put(client, lives, token: self.iPhone.token)!
            XCTAssertEqual(replay.revision, 1, "replaying the same upload must not create a new revision")
            let second = try await self.put(client, self.cheat("Moon jump", game: self.other), token: self.mac.token)!
            XCTAssertEqual(second.revision, 2)

            let all = try await self.changes(client, since: 0, token: self.mac.token)
            XCTAssertEqual(all.cheats.map(\.label), ["Lives", "Moon jump"])
            XCTAssertEqual(all.revision, 2)
            let newer = try await self.changes(client, since: 1, token: self.mac.token)
            XCTAssertEqual(newer.cheats.map(\.label), ["Moon jump"])
            let none = try await self.changes(client, since: 2, token: self.mac.token)
            XCTAssertTrue(none.cheats.isEmpty)

            try await client.execute(uri: "/v1/cheats/\(self.game)", method: .get, headers: self.bearer(self.mac.token)) { response in
                let list = try SupersEmuJSON.decoder().decode(CheatListResponse.self, from: Data(buffer: response.body))
                XCTAssertEqual(list.cheats.map(\.label), ["Lives"], "per-game list only has that game's cheats")
            }
        }
    }

    func testPutLongMultilineCodeRoundTripsThroughList() async throws {
        let code = [
            "8009C6E4 03E7",
            "8009C6E6 0001",
            "8009C6E8 0002",
            "8009C6EA 0003",
            "8009C6EC 0004",
            "8009C6EE 0005",
            "8009C6F0 0006",
        ].joined(separator: "\n")
        XCTAssertGreaterThan(code.utf8.count, 64)
        XCTAssertLessThanOrEqual(code.utf8.count, CheatCodec.maxCodeLength)
        try await app().test(.router) { client in
            var long = self.cheat("Long N64 code")
            long.code = code
            long.format = .n64GameShark
            let saved = try await self.put(client, long, token: self.iPhone.token)!
            XCTAssertEqual(saved.code, code)

            try await client.execute(uri: "/v1/cheats/\(self.game)", method: .get, headers: self.bearer(self.mac.token)) { response in
                XCTAssertEqual(response.status, .ok)
                let list = try SupersEmuJSON.decoder().decode(CheatListResponse.self, from: Data(buffer: response.body))
                XCTAssertEqual(list.cheats.map(\.code), [code])
            }
        }
    }

    func testFieldLevelMergeAcrossDevicesAndTombstones() async throws {
        try await app().test(.router) { client in
            let start = CheatRecord.now()
            let original = CheatRecord(gameID: self.game, label: "Lives", code: "C2C3-CF0D", format: .snesGameGenie, now: start)
            _ = try await self.put(client, original, token: self.iPhone.token)
            var phone = original, macCopy = original
            phone.setLabel("Infinite lives", at: start + 10)
            macCopy.setEnabled(false, at: start + 20)
            _ = try await self.put(client, phone, token: self.iPhone.token)
            let merged = try await self.put(client, macCopy, token: self.mac.token)!
            XCTAssertEqual(merged.label, "Infinite lives")
            XCTAssertFalse(merged.enabled)

            var deleted = merged
            deleted.markDeleted(at: start + 30)
            let tomb = try await self.put(client, deleted, token: self.iPhone.token)!
            XCTAssertTrue(tomb.deleted)
            let changes = try await self.changes(client, since: merged.revision, token: self.mac.token)
            XCTAssertEqual(changes.cheats.map(\.deleted), [true], "tombstones reach other devices")

            // An edit made before the delete (a device that was offline) doesn't resurrect it.
            var stale = original
            stale.setLabel("Old edit", at: start + 25)
            let afterStale = try await self.put(client, stale, token: self.mac.token)!
            XCTAssertTrue(afterStale.deleted)
        }
    }

    func testUsersAreIsolated() async throws {
        let sam = try store.createUser(displayName: "Sam", role: .admin)
        let samPhone = try store.createDeviceToken(userID: sam.id, deviceName: "Sam's iPhone")
        try await app().test(.router) { client in
            let lives = self.cheat("Chad only")
            _ = try await self.put(client, lives, token: self.iPhone.token)
            let samSees = try await self.changes(client, since: 0, token: samPhone.token)
            XCTAssertTrue(samSees.cheats.isEmpty)
            // The same cheat id under another user is a separate row; it never edits Chad's.
            var hijack = lives
            hijack.setLabel("Sam's edit", at: CheatRecord.now() + 100)
            _ = try await self.put(client, hijack, token: samPhone.token)
            let chadSees = try await self.changes(client, since: 0, token: self.mac.token)
            XCTAssertEqual(chadSees.cheats.map(\.label), ["Chad only"])
        }
    }

    func testRejectsBadInputAndNonDeviceWriters() async throws {
        let apiToken = try store.createAPIToken(ownerUserID: chad.id, name: "bot", scopes: [.savesRead, .libraryRead])
        try await app().test(.router) { client in
            var long = self.cheat("Long")
            long.code = String(repeating: "A", count: 241)
            _ = try await self.put(client, long, token: self.iPhone.token, expect: .badRequest)
            _ = try await self.put(client, self.cheat("Mismatch"), token: self.iPhone.token, game: self.other, expect: .badRequest)
            _ = try await self.put(client, self.cheat("Bot"), token: apiToken.token, expect: .forbidden)
            let moved = self.cheat("Moved")
            _ = try await self.put(client, moved, token: self.iPhone.token)
            var otherGame = moved
            otherGame.gameID = self.other
            _ = try await self.put(client, otherGame, token: self.iPhone.token, expect: .conflict)
        }
    }

    func testMigrationLeavesSavesAlone() throws {
        let saveTables = try store.db.read { db in try db.tableExists("save_revisions") }
        XCTAssertTrue(saveTables)
        let columns = try store.db.read { db in try db.columns(in: "cheats").map(\.name) }
        XCTAssertTrue(columns.contains("updated_by_device"))
    }
}

final class CheatSyncEngineTests: XCTestCase {
    var store: ServerStore!
    var chad: UserInfo!
    var scratch: URL!
    let game = String(repeating: "ef", count: 32)

    override func setUp() async throws {
        scratch = FileManager.default.temporaryDirectory.appendingPathComponent("cheat-sync-\(UUID().uuidString)", isDirectory: true)
        store = try ServerStore.inMemory()
        chad = try store.createUser(displayName: "Chad", role: .admin)
    }

    override func tearDown() async throws { try? FileManager.default.removeItem(at: scratch) }

    func withServer(_ body: @escaping @Sendable (URL) async throws -> Void) async throws {
        let app = buildApplication(store: store, configuration: .init())
        try await app.test(.live) { client in try await body(URL(string: "http://localhost:\(client.port!)")!) }
    }

    func engine(_ name: String, server: URL?) throws -> (CheatSyncEngine, TestProvider, APIClient?) {
        let client = try server.map { APIClient(baseURL: $0, token: try store.createDeviceToken(userID: chad.id, deviceName: name).token) }
        let provider = TestProvider(client)
        return (CheatSyncEngine(directory: scratch.appendingPathComponent(name, isDirectory: true), provider: provider), provider, client)
    }

    func testOfflineEditsQueueThenSyncToAnotherDevice() async throws {
        try await withServer { url in
            let (phone, phoneProvider, saved) = try self.engine("phone", server: url)
            phoneProvider.set(nil)
            let lives = CheatRecord(gameID: self.game, label: "Lives", code: "C2C3-CF0D", format: .snesGameGenie)
            try await phone.save([lives])
            let status = await phone.sync()
            XCTAssertEqual(status, .deviceOnly)
            let pendingCount = await phone.pendingCount
            XCTAssertEqual(pendingCount, 1)

            phoneProvider.set(saved)
            guard case .synced = await phone.sync() else { return XCTFail("phone sync failed") }
            let pendingAfter = await phone.pendingCount
            XCTAssertEqual(pendingAfter, 0)

            let (mac, _, _) = try self.engine("mac", server: url)
            guard case .synced = await mac.sync() else { return XCTFail("mac sync failed") }
            var onMac = await mac.cheats(for: self.game)
            XCTAssertEqual(onMac.map(\.label), ["Lives"])
            XCTAssertEqual(onMac.first?.enabled, true)

            onMac[0].setEnabled(false, at: CheatRecord.now() + 5)
            try await mac.save(onMac)
            _ = await mac.sync()
            _ = await phone.sync()
            let onPhone = await phone.cheats(for: self.game)
            XCTAssertEqual(onPhone.first?.enabled, false, "on/off syncs across devices")

            try await phone.delete(lives.id, gameID: self.game)
            _ = await phone.sync()
            _ = await mac.sync()
            let macAfterDelete = await mac.cheats(for: self.game)
            XCTAssertTrue(macAfterDelete.isEmpty)
        }
    }

    func testLongMultilineCodeSyncsAcrossDevices() async throws {
        try await withServer { url in
            let (phone, _, _) = try self.engine("long-phone", server: url)
            let code = [
                "8009C6E4 03E7",
                "8009C6E6 0001",
                "8009C6E8 0002",
                "8009C6EA 0003",
                "8009C6EC 0004",
                "8009C6EE 0005",
                "8009C6F0 0006",
            ].joined(separator: "\n")
            XCTAssertGreaterThan(code.utf8.count, 64)
            let n64 = CheatRecord(gameID: self.game, label: "Long N64 code", code: code, format: .n64GameShark)
            try await phone.save([n64])
            guard case .synced = await phone.sync() else { return XCTFail("phone sync failed") }

            let (mac, _, _) = try self.engine("long-mac", server: url)
            guard case .synced = await mac.sync() else { return XCTFail("mac sync failed") }
            let onMac = await mac.cheats(for: self.game)
            XCTAssertEqual(onMac.map(\.code), [code])
            XCTAssertEqual(onMac.first?.format, .n64GameShark)
        }
    }

    func testPersistsAcrossRelaunchAndIsolatesGames() async throws {
        let dir = scratch.appendingPathComponent("relaunch", isDirectory: true)
        let first = CheatSyncEngine(directory: dir, provider: nil)
        let lives = CheatRecord(gameID: game, label: "Lives", code: "C2C3-CF0D", format: .snesGameGenie)
        var off = CheatRecord(gameID: game, label: "Off", code: "DD32-6DAD", format: .snesGameGenie)
        off.setEnabled(false)
        try await first.save([lives, off])
        let relaunched = CheatSyncEngine(directory: dir, provider: nil)
        let loaded = await relaunched.cheats(for: game)
        XCTAssertEqual(loaded.map(\.label).sorted(), ["Lives", "Off"])
        XCTAssertEqual(loaded.first { $0.label == "Off" }?.enabled, false)
        let otherGame = await relaunched.cheats(for: String(repeating: "01", count: 32))
        XCTAssertTrue(otherGame.isEmpty)
        // Each game is its own file, written atomically (no temp files left behind).
        let files = try FileManager.default.contentsOfDirectory(atPath: dir.path).sorted()
        XCTAssertEqual(files, ["\(game).json", "sync-state.json"])
        do {
            try await relaunched.save([CheatRecord(gameID: "../escape", label: "x", code: "C2C3-CF0D", format: .snesGameGenie)])
            XCTFail("unsafe game id accepted")
        } catch {}
    }

    func testOlderServerWithoutCheatRoutesStaysDeviceOnly() async throws {
        let router = Router(context: SERequestContext.self)
        registerSaveRoutes(router.group("v1").add(middleware: TokenAuthMiddleware(store: store)), store: store)
        let token = try store.createDeviceToken(userID: chad.id, deviceName: "old").token
        try await Application(router: router).test(.live) { client in
            let provider = TestProvider(APIClient(baseURL: URL(string: "http://localhost:\(client.port!)")!, token: token))
            let engine = CheatSyncEngine(directory: self.scratch.appendingPathComponent("old", isDirectory: true), provider: provider)
            try await engine.save([CheatRecord(gameID: self.game, label: "Lives", code: "C2C3-CF0D", format: .snesGameGenie)])
            let status = await engine.sync()
            XCTAssertEqual(status, .serverTooOld)
            let local = await engine.cheats(for: self.game)
            XCTAssertEqual(local.count, 1, "cheats stay usable on the device")
        }
    }
}

extension CheatRoutesTests {
    func testRevisionNeverGoesBackAfterTombstonesExpire() throws {
        let cheats = CheatStore(store: store)
        let old = Date().addingTimeInterval(-100 * 24 * 3600)
        var expired = CheatRecord(gameID: game, label: "Old", code: "C2C3-CF0D", format: .snesGameGenie, now: CheatRecord.now(old))
        _ = try cheats.put(userID: chad.id, deviceID: iPhone.deviceID, expired)
        expired.markDeleted(at: CheatRecord.now(old.addingTimeInterval(5)))
        let tomb = try cheats.put(userID: chad.id, deviceID: iPhone.deviceID, expired)
        let fresh = cheat("New")
        let next = try cheats.put(userID: chad.id, deviceID: iPhone.deviceID, fresh)
        XCTAssertGreaterThan(next.revision, tomb.revision)
        let feed = try cheats.changes(userID: chad.id, since: tomb.revision)
        XCTAssertEqual(feed.cheats.map(\.id), [fresh.id])
        XCTAssertEqual(feed.revision, next.revision)
    }

    func testFeedLeavesOutGamesThePlayerHid() async throws {
        let kid = try store.createUser(displayName: "Kid", role: .player)
        let game = self.game, other = self.other
        try await store.db.write { db in
            for id in [game, other] {
                try db.execute(sql: "INSERT INTO games (id, title, system, created_at) VALUES (?, ?, 'snes', ?)", arguments: [id, id, Date()])
            }
            try db.execute(sql: "INSERT INTO user_hidden_games (user_id, game_id) VALUES (?, ?)", arguments: [kid.id, other])
        }
        let cheats = CheatStore(store: store)
        _ = try cheats.put(userID: kid.id, deviceID: nil, cheat("Seen"))
        _ = try cheats.put(userID: kid.id, deviceID: nil, cheat("Hidden", game: other))
        let kidDevice = try store.createDeviceToken(userID: kid.id, deviceName: "Kid's iPad")
        try await app().test(.router) { client in
            let feed = try await self.changes(client, since: 0, token: kidDevice.token)
            XCTAssertEqual(feed.cheats.map(\.label), ["Seen"])
            let unhide = try await self.store.db.write { db in
                let previouslyHidden: Set<String> = [other]
                try db.execute(sql: "DELETE FROM user_hidden_games WHERE user_id = ?", arguments: [kid.id])
                try CheatStore.republish(db, userID: kid.id, gameIDs: previouslyHidden)
            }
            _ = unhide
            let after = try await self.changes(client, since: feed.revision, token: kidDevice.token)
            XCTAssertEqual(after.cheats.map(\.label), ["Hidden"])
        }
    }
}

final class CheatReviewFixTests: XCTestCase {
    let game = String(repeating: "12", count: 32)

    func testNamedUndashedGenesisCodeInBatch() {
        let entries = CheatCodec.parseBatch("Infinite lives RFAAA6VR", system: .genesis)
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries.first?.label, "Infinite lives")
        XCTAssertEqual(entries.first?.result.normalized, "RFAA-A6VR")
        XCTAssertEqual(entries.first?.result.isValid, true)
        let named = CheatCodec.parseBatch("CHEATERS RFAA-A6VR", system: .genesis)
        XCTAssertEqual(named.first?.label, "CHEATERS")
        XCTAssertEqual(named.first?.result.normalized, "RFAA-A6VR")
        let plusLabel = CheatCodec.parseBatch("C2C3CF0D + 9 lives", system: .snes)
        XCTAssertEqual(plusLabel.map(\.result.normalized), ["C2C3-CF0D"])
        XCTAssertEqual(plusLabel.first?.label, "+ 9 lives")
        let joined = CheatCodec.parseBatch("Max power C2C3-CF0D+D4A1-0FA4", system: .snes)
        XCTAssertEqual(joined.count, 2)
    }

    func testNamedUndashedGameBoyCodesInBatch() {
        let sixDigit = CheatCodec.parseBatch("Infinite lives 000000", system: .gb)
        XCTAssertEqual(sixDigit.count, 1)
        XCTAssertEqual(sixDigit.first?.label, "Infinite lives")
        XCTAssertEqual(sixDigit.first?.result.normalized, "000-000")
        XCTAssertEqual(sixDigit.first?.result.format, .gbGameGenie)
        XCTAssertTrue(sixDigit.first?.result.isValid == true)

        let nineDigit = CheatCodec.parseBatch("Infinite lives 123456789", system: .gb)
        XCTAssertEqual(nineDigit.count, 1)
        XCTAssertEqual(nineDigit.first?.label, "Infinite lives")
        XCTAssertEqual(nineDigit.first?.result.normalized, "123-456-789")
        XCTAssertEqual(nineDigit.first?.result.format, .gbGameGenie)
        XCTAssertTrue(nineDigit.first?.result.isValid == true)

        let gameShark = CheatCodec.parseBatch("Infinite lives 01001234", system: .gb)
        XCTAssertEqual(gameShark.count, 1)
        XCTAssertEqual(gameShark.first?.label, "Infinite lives")
        XCTAssertEqual(gameShark.first?.result.normalized, "01001234")
        XCTAssertEqual(gameShark.first?.result.format, .gbGameShark)
        XCTAssertTrue(gameShark.first?.result.isValid == true)
    }

    func testSameSecondDeleteThenEditRevivesAndEditThenDeleteSticks() {
        let t = CheatRecord.now()
        var record = CheatRecord(gameID: game, label: "A", code: "C2C3-CF0D", format: .snesGameGenie, now: t)
        record.setEnabled(false, at: t)
        var deleted = record
        deleted.markDeleted(at: t)
        XCTAssertTrue(CheatMerge.merge(record, deleted).deleted)
        XCTAssertEqual(deleted.deletedAt, t)
        var otherDevice = record
        otherDevice.setLabel("Later", at: t.addingTimeInterval(1))
        XCTAssertFalse(CheatMerge.merge(deleted, otherDevice).deleted)
        var revived = deleted
        revived.setLabel("B", at: t)
        let merged = CheatMerge.merge(deleted, revived)
        XCTAssertFalse(merged.deleted)
        XCTAssertEqual(merged.label, "B")
    }
}

extension CheatSyncEngineTests {
    func testSaveFailsWhenTheUploadQueueCannotBeWritten() async throws {
        let dir = scratch.appendingPathComponent("blocked", isDirectory: true)
        let blocker = dir.appendingPathComponent("sync-state.json", isDirectory: true)
        try FileManager.default.createDirectory(at: blocker, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: blocker.appendingPathComponent("keep"))
        let engine = CheatSyncEngine(directory: dir, provider: nil)
        do {
            try await engine.save([CheatRecord(gameID: game, label: "A", code: "C2C3-CF0D", format: .snesGameGenie)])
            XCTFail("save should report that the upload couldn't be queued")
        } catch {}
    }
}
