import CryptoKit
import Foundation
import GRDB
import SupersEmuKit
@testable import SupersEmuServerCore
import XCTest
import zlib

/// Synthetic Dreamcast / PS2 images: only the structures detection reads (IP.BIN, ISO 9660 SYSTEM.CNF, CHD metadata,
/// CSO blocks, ROMDIR), never commercial data.
enum DCPS2Fixtures {
    /// Raw MODE1/2352 (or 2048-byte) Dreamcast data track with `SEGA SEGAKATANA` IP.BIN at sector 0.
    static func dreamcastTrack(seed: UInt8, sectorSize: Int = 2352, sectors: Int = 20) -> Data {
        var bytes = [UInt8](repeating: 0, count: sectors * sectorSize)
        let offset = sectorSize == 2352 ? 16 : 0
        if sectorSize == 2352 { bytes.replaceSubrange(1..<11, with: [UInt8](repeating: 0xFF, count: 10)) }
        bytes.replaceSubrange(offset..<offset + 32, with: Array("SEGA SEGAKATANA SEGA ENTERPRISES".utf8))
        bytes[(sectors - 1) * sectorSize] = seed
        return Data(bytes)
    }

    /// A minimal ISO 9660 image (2048-byte sectors) whose root holds `SYSTEM.CNF`, plus the PlayStation licence
    /// string in the system area so the licence alone would say PS1.
    static func iso(systemCNF: String, seed: UInt8, sectors: Int = 24) -> Data {
        var bytes = [UInt8](repeating: 0, count: sectors * 2048)
        let licence = Array(DiscFixtures.licence.utf8)
        bytes.replaceSubrange(4 * 2048..<4 * 2048 + licence.count, with: licence)
        func le32(_ value: Int, at offset: Int) { for i in 0..<4 { bytes[offset + i] = UInt8((value >> (8 * i)) & 0xFF) } }
        func record(at offset: Int, lba: Int, size: Int, flags: UInt8, name: [UInt8]) -> Int {
            let length = (33 + name.count + 1) & ~1
            bytes[offset] = UInt8(length)
            le32(lba, at: offset + 2)
            le32(size, at: offset + 10)
            bytes[offset + 25] = flags
            bytes[offset + 32] = UInt8(name.count)
            bytes.replaceSubrange(offset + 33..<offset + 33 + name.count, with: name)
            return length
        }
        let pvd = 16 * 2048
        bytes[pvd] = 1
        bytes.replaceSubrange(pvd + 1..<pvd + 6, with: Array("CD001".utf8))
        bytes[pvd + 6] = 1
        _ = record(at: pvd + 156, lba: 18, size: 2048, flags: 2, name: [0])
        var offset = 18 * 2048
        offset += record(at: offset, lba: 18, size: 2048, flags: 2, name: [0])
        offset += record(at: offset, lba: 18, size: 2048, flags: 2, name: [1])
        let cnf = Array(systemCNF.utf8)
        _ = record(at: offset, lba: 19, size: cnf.count, flags: 0, name: Array("SYSTEM.CNF;1".utf8))
        bytes.replaceSubrange(19 * 2048..<19 * 2048 + cnf.count, with: cnf)
        bytes[20 * 2048] = seed
        return Data(bytes)
    }

    static func ps2ISO(seed: UInt8) -> Data { iso(systemCNF: "BOOT2 = cdrom0:\\SLUS_200.00;1\r\nVER = 1.00\r\nVMODE = NTSC\r\n", seed: seed) }
    static func ps1ISO(seed: UInt8) -> Data { iso(systemCNF: "BOOT = cdrom:\\SLUS_000.00;1\r\nTCB = 4\r\n", seed: seed) }

    /// The image in raw MODE2/2352 sectors (sync, header, subheader, then 2048 bytes of user data at 24).
    static func raw2352(_ iso: Data) -> Data {
        var out = Data()
        for start in stride(from: 0, to: iso.count, by: 2048) {
            var sector = [UInt8](repeating: 0, count: 2352)
            sector.replaceSubrange(1..<11, with: [UInt8](repeating: 0xFF, count: 10))
            sector[15] = 2
            sector.replaceSubrange(24..<2072, with: iso[start..<start + 2048])
            out += sector
        }
        return out
    }

    /// CISO v1 with 2048-byte blocks: even blocks raw-deflated, odd blocks stored (high index bit).
    static func cso(_ iso: Data) -> Data {
        let blocks = iso.count / 2048
        var header = [UInt8](repeating: 0, count: 24)
        header.replaceSubrange(0..<4, with: Array("CISO".utf8))
        header[4] = 24
        for i in 0..<8 { header[8 + i] = UInt8((iso.count >> (8 * i)) & 0xFF) }
        header[17] = 0x08 // 2048
        header[20] = 1
        var body = Data(), index: [UInt32] = []
        let dataStart = 24 + (blocks + 1) * 4
        for block in 0..<blocks {
            let plain = iso[block * 2048..<(block + 1) * 2048]
            let stored = block % 2 == 1
            index.append(UInt32(dataStart + body.count) | (stored ? 0x8000_0000 : 0))
            body += stored ? Data(plain) : deflateRaw(Data(plain))
        }
        index.append(UInt32(dataStart + body.count))
        var table = Data()
        for value in index { for i in 0..<4 { table.append(UInt8((value >> (8 * UInt32(i))) & 0xFF)) } }
        return Data(header) + table + body
    }

    static func deflateRaw(_ input: Data) -> Data {
        var stream = z_stream()
        deflateInit2_(&stream, Z_BEST_COMPRESSION, Z_DEFLATED, -15, 8, Z_DEFAULT_STRATEGY, zlibVersion(), Int32(MemoryLayout<z_stream>.size))
        defer { deflateEnd(&stream) }
        var input = input
        var output = Data(count: input.count + 1024)
        input.withUnsafeMutableBytes { inRaw in
            output.withUnsafeMutableBytes { outRaw in
                stream.next_in = inRaw.bindMemory(to: Bytef.self).baseAddress
                stream.avail_in = uInt(inRaw.count)
                stream.next_out = outRaw.bindMemory(to: Bytef.self).baseAddress
                stream.avail_out = uInt(outRaw.count)
                _ = deflate(&stream, Z_FINISH)
            }
        }
        return output.prefix(Int(stream.total_out))
    }

    /// CHD v5 header plus a metadata chain with `tags`; no hunks (detection never decompresses).
    static func chd(tags: [String], rawSHA1: [UInt8] = [UInt8](repeating: 0, count: 20), logicalBytes: UInt64 = 0, seed: UInt8 = 0) -> Data {
        var header = [UInt8](repeating: 0, count: 124)
        header.replaceSubrange(0..<8, with: Array("MComprHD".utf8))
        func be(_ value: UInt64, at offset: Int, _ count: Int) { for i in 0..<count { header[offset + i] = UInt8((value >> (8 * UInt64(count - 1 - i))) & 0xFF) } }
        be(124, at: 8, 4)
        be(5, at: 12, 4)
        be(logicalBytes, at: 32, 8)
        be(tags.isEmpty ? 0 : 124, at: 48, 8)
        header.replaceSubrange(64..<84, with: rawSHA1)
        header[120] = seed
        var meta = Data()
        for (i, tag) in tags.enumerated() {
            let payload = Array("TRACK:\(i + 1)".utf8)
            let next: UInt64 = i == tags.count - 1 ? 0 : UInt64(124 + meta.count + 16 + payload.count)
            var entry = Array(tag.utf8.prefix(4))
            entry += [0x01, 0, 0, UInt8(payload.count)]
            entry += (0..<8).map { UInt8((next >> (8 * UInt64(7 - $0))) & 0xFF) }
            meta += entry + payload
        }
        return Data(header) + meta
    }

    /// 4 MB image with a ROMDIR (`RESET`, `ROMDIR`, `EXTINFO`, `ROMVER`) and the given `ROMVER`.
    static func ps2BIOS(romver: String = "0230AC20080220", seed: UInt8 = 1) -> Data {
        var bytes = [UInt8](repeating: 0, count: 4_194_304)
        let entries: [(String, Int)] = [("RESET", 0x2700), ("ROMDIR", 0x40), ("EXTINFO", 0x10), ("ROMVER", 0x10)]
        for (i, (name, size)) in entries.enumerated() {
            let base = 0x2700 + i * 16
            bytes.replaceSubrange(base..<base + name.utf8.count, with: Array(name.utf8))
            for b in 0..<4 { bytes[base + 12 + b] = UInt8((size >> (8 * b)) & 0xFF) }
        }
        bytes.replaceSubrange(0x2750..<0x2750 + 14, with: Array(romver.utf8))
        bytes[0x10000] = seed
        return Data(bytes)
    }

    /// ELF32 little-endian MIPS header; `flags` 0x20924001 is what the PS2 SDK (R5900) emits.
    static func elf(machine: UInt16 = 8, flags: UInt32 = 0x2092_4001, seed: UInt8 = 1) -> Data {
        var bytes = [UInt8](repeating: 0, count: 256)
        bytes.replaceSubrange(0..<4, with: [0x7F, 0x45, 0x4C, 0x46])
        bytes[4] = 1; bytes[5] = 1; bytes[6] = 1
        bytes[18] = UInt8(machine & 0xFF); bytes[19] = UInt8(machine >> 8)
        for i in 0..<4 { bytes[36 + i] = UInt8((flags >> (8 * UInt32(i))) & 0xFF) }
        bytes[200] = seed
        return Data(bytes)
    }

    /// `.gdi` sheet: track 1 data, track 2 audio, track 3 data (the high-density area).
    static func gdi(_ names: [String], quoted: Bool = false) -> Data {
        var lines = ["\(names.count)"]
        let lbas = [0, 756, 45000]
        for (i, name) in names.enumerated() {
            let type = i == 1 ? 0 : 4
            lines.append("\(i + 1) \(i < lbas.count ? lbas[i] : 45000 + i * 1000) \(type) 2352 \(quoted ? "\"\(name)\"" : name) 0")
        }
        return Data((lines.joined(separator: "\r\n") + "\r\n").utf8)
    }
}

extension LibraryTests {
    // MARK: Detection units

    func testDreamcastAndPS2HeaderDetection() throws {
        XCTAssertEqual(SystemDetector.detectDisc(header: DCPS2Fixtures.dreamcastTrack(seed: 1)), .dreamcast)
        XCTAssertEqual(SystemDetector.detectDisc(header: DCPS2Fixtures.dreamcastTrack(seed: 1, sectorSize: 2048)), .dreamcast)
        // The header alone can't tell a PS2 disc from PS1 (both carry the licence); SYSTEM.CNF does.
        let ps2 = DCPS2Fixtures.ps2ISO(seed: 1), ps1 = DCPS2Fixtures.ps1ISO(seed: 1)
        XCTAssertEqual(SystemDetector.detectDisc(header: ps2), .psx)
        XCTAssertEqual(SystemDetector.detectDisc(header: ps2, file: try write(ps2, "units/ps2.iso")), .ps2)
        XCTAssertEqual(SystemDetector.detectDisc(header: ps1, file: try write(ps1, "units/ps1.iso")), .psx)
        let raw = DCPS2Fixtures.raw2352(ps2)
        XCTAssertEqual(SystemDetector.detectDisc(header: raw, file: try write(raw, "units/ps2.bin")), .ps2, "MODE2/2352 CD tracks too")
        let segaCD = DiscFixtures.segaCDTrack(seed: 1), psx = DiscFixtures.psxTrack(seed: 1)
        XCTAssertEqual(SystemDetector.detectDisc(header: segaCD, file: try write(segaCD, "units/scd.bin")), .segacd)
        XCTAssertEqual(SystemDetector.detectDisc(header: psx, file: try write(psx, "units/psx.bin")), .psx, "PS1 discs without an ISO 9660 tree keep the licence check")
        XCTAssertEqual(DiscProbe.playStationSystem(systemCNF: "boot2=cdrom0:\\A;1"), .ps2)
        XCTAssertNil(DiscProbe.playStationSystem(systemCNF: "VMODE = PAL"))

        func detect(_ name: String, _ data: Data) -> SystemDetector.Result {
            SystemDetector.detect(filename: name, header: data.prefix(SystemDetector.headerLength), size: Int64(data.count))
        }
        XCTAssertEqual(detect("hello.elf", DCPS2Fixtures.elf()), .system(.ps2))
        XCTAssertEqual(detect("linux.elf", DCPS2Fixtures.elf(machine: 3, flags: 0)), .needsReview(.init("ELF executable isn't a PS2 (MIPS R5900) program", .ambiguous)))
        XCTAssertEqual(detect("psp.elf", DCPS2Fixtures.elf(flags: 0x10A2_3001)), .needsReview(.init("ELF executable isn't a PS2 (MIPS R5900) program", .ambiguous)))
        XCTAssertEqual(detect("junk.elf", Data(count: 64)), .needsReview(.init("Not an ELF executable (no \\x7FELF header)", .ambiguous)))
        XCTAssertEqual(detect("track03.bin", DCPS2Fixtures.dreamcastTrack(seed: 1)),
                       .needsReview(.init("Dreamcast disc track without its .gdi or .cue sheet", .missingFiles)))
    }

    func testGDISheetParsing() throws {
        let gdi = try XCTUnwrap(CueSheet(gdi: Data("\u{FEFF}3\r\n1 0 4 2352 track01.bin 0\r\n2 756 0 2352 \"Track 02.raw\" 0\r\n3 45000 4 2352 track03.bin 0\r\n".utf8)))
        XCTAssertEqual(gdi.files.map(\.name), ["track01.bin", "Track 02.raw", "track03.bin"])
        XCTAssertEqual(gdi.files.map(\.isData), [true, false, true])
        XCTAssertEqual(String(decoding: gdi.normalized, as: UTF8.self), "3\n1 0 4 2352 track01.bin 0\n2 756 0 2352 \"track 02.raw\" 0\n3 45000 4 2352 track03.bin 0\n")
        let rewritten = String(decoding: gdi.rewritten(names: [1: "Disc 2 - track01.bin"]), as: UTF8.self)
        XCTAssertTrue(rewritten.contains("1 0 4 2352 \"Disc 2 - track01.bin\" 0"), rewritten)
        let reparsed = try XCTUnwrap(CueSheet(gdi: Data(rewritten.utf8)))
        XCTAssertEqual(reparsed.files.first?.name, "Disc 2 - track01.bin")
        XCTAssertNil(CueSheet(gdi: Data("3\n1 0 4 2352 track01.bin 0\n".utf8)), "every declared track must be listed")
        XCTAssertNil(CueSheet(gdi: Data("not a gdi".utf8)))
        XCTAssertNil(CueSheet(gdi: Data("1\n1 0 4 2352 track01.bin\n".utf8)), "the offset column is required")
    }

    // MARK: Import

    func testGDIImportsWithAllTracksAsOneDreamcastGame() async throws {
        let tracks = [DCPS2Fixtures.dreamcastTrack(seed: 1), DiscFixtures.audioTrack(seed: 2), DCPS2Fixtures.dreamcastTrack(seed: 3)]
        let names = ["track01.bin", "track02.raw", "track03.bin"]
        for (data, name) in Swift.zip(tracks, names) { try write(data, "Dreamcast/Crazy Taxi (USA)/\(name)") }
        try write(DCPS2Fixtures.gdi(names), "Dreamcast/Crazy Taxi (USA)/Crazy Taxi (USA).gdi")
        // A .gdi whose IP.BIN is only on track 3 still identifies (track 1 here has no header).
        let late = [Data(repeating: 9, count: 2352 * 4), DiscFixtures.audioTrack(seed: 5), DCPS2Fixtures.dreamcastTrack(seed: 6)]
        for (data, name) in Swift.zip(late, names) { try write(data, "Other/Jet Set (USA)/\(name)") }
        try write(DCPS2Fixtures.gdi(names, quoted: true), "Other/Jet Set (USA)/Jet Set (USA).gdi")
        // Missing track 3: review, nothing imported.
        try write(tracks[0], "Broken/Half (USA)/track01.bin")
        try write(tracks[1], "Broken/Half (USA)/track02.raw")
        try write(DCPS2Fixtures.gdi(names), "Broken/Half (USA)/Half (USA).gdi")

        let report = try await importer.importPaths([sources.path], auth: nil)
        XCTAssertEqual(Set(report.imported.map(\.title)), ["Crazy Taxi", "Jet Set"])
        XCTAssertEqual(Set(report.imported.map(\.system)), [.dreamcast])
        XCTAssertEqual(report.needsReview.map(\.reason), ["Missing track: track03.bin"])
        let taxi = try XCTUnwrap(report.imported.first { $0.title == "Crazy Taxi" })
        XCTAssertEqual(taxi.totalSize, Int64(tracks.reduce(0) { $0 + $1.count } + DCPS2Fixtures.gdi(names).count))
        let rows = try await fileRows(taxi.id)
        XCTAssertEqual(rows, [FileRow(filename: "Crazy Taxi (USA).gdi", role: "cue", disc: 1),
                              FileRow(filename: "track01.bin", role: "disc", disc: 1),
                              FileRow(filename: "track02.raw", role: "disc", disc: 1),
                              FileRow(filename: "track03.bin", role: "disc", disc: 1)])
        XCTAssertEqual(report.unsupported, [])
    }

    func testMultiDiscGDIRewritesCollidingTrackNames() async throws {
        let names = ["track01.bin", "track02.raw", "track03.bin"]
        for disc in 1...2 {
            let folder = "Dreamcast/Shenmue (USA) (Disc \(disc))"
            let tracks = [DCPS2Fixtures.dreamcastTrack(seed: UInt8(10 * disc)), DiscFixtures.audioTrack(seed: UInt8(10 * disc + 1)),
                          DCPS2Fixtures.dreamcastTrack(seed: UInt8(10 * disc + 2))]
            for (data, name) in Swift.zip(tracks, names) { try write(data, "\(folder)/\(name)") }
            try write(DCPS2Fixtures.gdi(names), "\(folder)/Shenmue (USA) (Disc \(disc)).gdi")
        }
        let report = try await importer.importPaths([sources.path], auth: nil)
        XCTAssertEqual(report.imported.map(\.title), ["Shenmue"])
        let game = try XCTUnwrap(report.imported.first)
        let rows = try await fileRows(game.id)
        XCTAssertEqual(rows.filter { $0.disc == 2 }.map(\.filename).sorted(),
                       ["Disc 2 - track01.bin", "Disc 2 - track02.raw", "Disc 2 - track03.bin", "Shenmue (USA) (Disc 2).gdi"])
        let stored = try Data(contentsOf: store.paths.libraryFile("games/\(game.id)/Shenmue (USA) (Disc 2).gdi"))
        XCTAssertEqual(try XCTUnwrap(CueSheet(gdi: stored)).files.map(\.name), ["Disc 2 - track01.bin", "Disc 2 - track02.raw", "Disc 2 - track03.bin"],
                       "the stored .gdi points at the renamed tracks (quoted, which Flycast's parser accepts)")
        let m3u = try String(contentsOf: store.paths.libraryFile("games/\(game.id)/Shenmue.m3u"), encoding: .utf8)
        XCTAssertEqual(m3u, "Shenmue (USA) (Disc 1).gdi\nShenmue (USA) (Disc 2).gdi\n")
    }

    func testPS2CueBinIsNotMistakenForPS1() async throws {
        try writeCueGame("Discs/Homebrew Two (USA)", name: "Homebrew Two (USA)", tracks: [DCPS2Fixtures.raw2352(DCPS2Fixtures.ps2ISO(seed: 1))])
        try writeCueGame("Discs/Homebrew One (USA)", name: "Homebrew One (USA)", tracks: [DCPS2Fixtures.raw2352(DCPS2Fixtures.ps1ISO(seed: 2))])
        try writeCueGame("Discs/Plain One (USA)", name: "Plain One (USA)", tracks: [DiscFixtures.psxTrack(seed: 3)])
        try writeCueGame("Discs/Mega (USA)", name: "Mega (USA)", tracks: [DiscFixtures.segaCDTrack(seed: 4)], dataMode: "MODE1/2352")
        let report = try await importer.importPaths([sources.path], auth: nil)
        XCTAssertEqual(Dictionary(uniqueKeysWithValues: report.imported.map { ($0.title, $0.system) }),
                       ["Homebrew Two": .ps2, "Homebrew One": .psx, "Plain One": .psx, "Mega": .segacd])
    }

    func testDreamcastAndPS2SingleFileDiscs() async throws {
        let cdi = Data("DiscJuggler image".utf8) + Data(repeating: 1, count: 4000)
        try write(cdi, "Downloads/Selfboot Demo.cdi")
        let ps2 = DCPS2Fixtures.ps2ISO(seed: 1), ps1 = DCPS2Fixtures.ps1ISO(seed: 2)
        try write(ps2, "Downloads/Two (USA).iso")
        try write(ps1, "Downloads/One (USA).iso")
        let cso = DCPS2Fixtures.cso(DCPS2Fixtures.ps2ISO(seed: 3))
        try write(cso, "Downloads/Compressed (USA).cso")
        try write(DCPS2Fixtures.cso(DCPS2Fixtures.iso(systemCNF: "VMODE = NTSC\n", seed: 4)), "Downloads/Not PS2.cso")
        try write(DCPS2Fixtures.chd(tags: ["CHGD", "CHGD", "CHGD"], seed: 1), "Misc/GD Game (USA).chd")
        try write(DCPS2Fixtures.chd(tags: ["DVD "], seed: 2), "Misc/DVD Game (USA).chd")
        try write(DCPS2Fixtures.chd(tags: ["CHT2"], seed: 3), "Sony - PlayStation 2/CD Game (USA).chd")
        try write(DCPS2Fixtures.chd(tags: ["CHT2"], seed: 4), "DC/Folder Game (USA).chd")
        try write(DCPS2Fixtures.chd(tags: ["CHT2"], seed: 5), "Misc/Mystery.chd")
        try write(DCPS2Fixtures.elf(seed: 7), "PS2/Homebrew/hello.elf")

        let report = try await importer.importPaths([sources.path], auth: nil)
        XCTAssertEqual(Dictionary(uniqueKeysWithValues: report.imported.map { ($0.title, $0.system) }), [
            "Selfboot Demo": .dreamcast, "Two": .ps2, "One": .psx, "Compressed": .ps2,
            "GD Game": .dreamcast, "DVD Game": .ps2, "CD Game": .ps2, "Folder Game": .dreamcast, "hello": .ps2,
        ])
        XCTAssertEqual(Set(report.needsReview.map(\.filename)), ["Not PS2.cso", "Mystery.chd"])
        XCTAssertEqual(Set(report.needsReview.map(\.reason)), [
            "CSO image without a PS2 SYSTEM.CNF (only PS2 .cso images are supported)",
            "CHD disc image: system can't be read from the file (put it in a PS1, PS2, Sega CD or Dreamcast folder)",
        ])
        let csoGame = try XCTUnwrap(report.imported.first { $0.title == "Compressed" })
        XCTAssertEqual(csoGame.id, DiscFixtures.sha(cso))
        let rows = try await fileRows(csoGame.id)
        XCTAssertEqual(rows, [FileRow(filename: "Compressed (USA).cso", role: "disc", disc: 1)])
    }

    // MARK: BIOS

    func testDreamcastAndPS2BIOSTable() {
        let dc = KnownBIOS.all.filter { $0.system == .dreamcast }
        XCTAssertEqual(dc.map(\.relativePath), ["dc/dc_boot.bin", "dc/dc_flash.bin"])
        XCTAssertTrue(dc.allSatisfy { !$0.required })
        let ps2 = KnownBIOS.all.filter { $0.system == .ps2 }
        XCTAssertEqual(ps2.count, 73)
        XCTAssertTrue(ps2.allSatisfy { $0.size == 4_194_304 && $0.md5.count == 32 && !$0.required && $0.relativePath.hasPrefix("pcsx2/bios/ps2-") })
        XCTAssertEqual(Set(ps2.map(\.md5)).count, ps2.count, "every PS2 dump is distinct")
        XCTAssertEqual(ps2.filter(\.listed).map(\.filename), ["ps2-0230a-20080220.bin", "ps2-0230e-20080220.bin", "ps2-0230j-20080220.bin"])
        XCTAssertEqual(Set(KnownBIOS.all.map(\.md5)).count, KnownBIOS.all.count)
        XCTAssertTrue(SystemID.ps2.requiresBIOS)
        XCTAssertFalse(SystemID.dreamcast.requiresBIOS)
        XCTAssertTrue(SystemID.dreamcast.usesBIOS)
    }

    func testUnlistedPS2BIOSIsStoredAndShownOnceRecognised() async throws {
        let bytes = Data((0..<4096).map { UInt8(truncatingIfNeeded: $0 * 7) })
        let table = [KnownBIOS(filename: "ps2-0230a-20080220.bin", system: .ps2, region: "US", required: false, md5: "00", size: 4096),
                     KnownBIOS(filename: "ps2-0160a-20010427.bin", system: .ps2, region: "US", required: false,
                               md5: Insecure.MD5.hash(data: bytes).hexString, size: 4096, listed: false),
                     KnownBIOS(filename: "dc_boot.bin", system: .dreamcast, region: "World", required: false, md5: "00", size: 8192)]
        XCTAssertEqual(try BIOSLibrary.status(store: store, known: table).map(\.filename), ["ps2-0230a-20080220.bin", "dc_boot.bin"],
                       "unlisted dumps don't get a row while missing")
        try write(bytes, "Dumps/SCPH-30001 v1.60.bin")
        let report = try await LibraryImporter(store: store, knownBIOS: table).importPaths([sources.path], auth: nil)
        let sha = DiscFixtures.sha(bytes)
        XCTAssertEqual(report.bios, [BIOSFileInfo(id: sha, filename: "ps2-0160a-20010427.bin", system: .ps2, region: "US", required: false)])
        let status = try BIOSLibrary.status(store: store, known: table)
        XCTAssertEqual(status.map(\.filename), ["ps2-0230a-20080220.bin", "dc_boot.bin", "ps2-0160a-20010427.bin"])
        XCTAssertEqual(status.map(\.state), [.missing, .missing, .present])
    }

    func testUnknownPS2BIOSIsReportedWithItsVersion() async throws {
        try write(DCPS2Fixtures.ps2BIOS(), "Dumps/my ps2.bin")
        let report = try await importer.importPaths([sources.path], auth: nil)
        XCTAssertNil(report.bios)
        XCTAssertEqual(report.imported, [])
        XCTAssertEqual(report.unsupported, ["my ps2.bin: looks like a PS2 BIOS (version 0230AC20080220) but its hash isn't a known good dump"])
        XCTAssertEqual(PS2BIOS.romver(DCPS2Fixtures.ps2BIOS(romver: "0160JD20010427")), "0160JD20010427")
        XCTAssertEqual(PS2BIOS.filename(romver: "0230AC20080220"), "ps2-0230a-20080220.bin")
        XCTAssertEqual(PS2BIOS.filename(romver: "0160JD20010427"), "ps2-0160jd-20010427.bin")
        XCTAssertEqual(PS2BIOS.region(romver: "0230EC20080220"), "EU")
        XCTAssertNil(PS2BIOS.romver(Data(count: 4_194_304)))
    }
}

extension BIOSStoreTests {
    func testSyncPutsDreamcastAndPS2BIOSInCoreSubfoldersAndSkipsPS2WhereNotPlayed() async throws {
        let boot = Data("synthetic dc boot".utf8), ps2 = Data("synthetic ps2 bios".utf8)
        let list = [Self.bios(boot, "dc_boot.bin", .dreamcast, required: false), Self.bios(ps2, "ps2-0230a-20080220.bin", .ps2, required: false)]
        let served = [list[0].id: boot, list[1].id: ps2]
        let mac = BIOSStore(directory: directory, known: [], systems: Set(SystemID.allCases))
        XCTAssertFalse(BIOSStore.isSatisfied(.ps2, by: mac.installed()))
        let result = try await mac.sync(list) { try XCTUnwrap(served[$0.id]) }
        XCTAssertEqual(result.installed, list)
        XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent("dc/dc_boot.bin")), boot)
        XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent("pcsx2/bios/ps2-0230a-20080220.bin")), ps2)
        XCTAssertTrue(BIOSStore.isSatisfied(.ps2, by: mac.installed()))
        XCTAssertTrue(BIOSStore.isSatisfied(.dreamcast, by: []), "Dreamcast's BIOS is optional")

        // iPhone/iPad: PS2 isn't played there, so its BIOS isn't fetched, and a copy sync wrote earlier is removed.
        let phone = BIOSStore(directory: directory, known: [], systems: Set(SystemID.allCases).subtracting([.ps2]))
        let again = try await phone.sync(list) { try XCTUnwrap(served[$0.id]) }
        XCTAssertEqual(again.installed, [list[0]])
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("pcsx2/bios/ps2-0230a-20080220.bin").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.appendingPathComponent("dc/dc_boot.bin").path))
        #if os(macOS)
        XCTAssertTrue(SystemID.biosSyncedOnThisPlatform.contains(.ps2))
        #endif
    }

    func testUserPlacedPS2BIOSCountsUnderAnyName() throws {
        let bytes = Data("users own ps2 dump".utf8)
        let known = [KnownBIOS(filename: "ps2-0170a-20030325.bin", system: .ps2, region: "US", required: false,
                               md5: Insecure.MD5.hash(data: bytes).hexString, size: Int64(bytes.count), listed: false)]
        let store = BIOSStore(directory: directory, known: known, systems: Set(SystemID.allCases))
        XCTAssertEqual(store.installed(), [])
        let folder = directory.appendingPathComponent("pcsx2/bios", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try bytes.write(to: folder.appendingPathComponent("SCPH-50001.bin"))
        try Data("something else".utf8).write(to: folder.appendingPathComponent("notes.bin"))
        XCTAssertEqual(store.installed(), [BIOSFileInfo(id: SHA256.hash(data: bytes).hexString, filename: "SCPH-50001.bin", system: .ps2,
                                                        region: "US", required: false)])
        XCTAssertTrue(BIOSStore.isSatisfied(.ps2, by: store.installed()))
    }
}

final class DiscMetadataTests: XCTestCase {
    var directory: URL!

    override func setUp() {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("disc-meta-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDown() { try? FileManager.default.removeItem(at: directory) }

    func write(_ data: Data, _ name: String) throws -> URL {
        let url = directory.appendingPathComponent(name)
        try data.write(to: url)
        return url
    }

    func testCatalogPinsDreamcastAndPS2Redump() throws {
        let catalog = MetadataCatalog.pinned
        let dc = try XCTUnwrap(catalog.systems[.dreamcast]), ps2 = try XCTUnwrap(catalog.systems[.ps2])
        XCTAssertEqual([dc.name, dc.source, ps2.name, ps2.source], ["Sega - Dreamcast", "redump", "Sony - PlayStation 2", "redump"])
        for set in [dc, ps2] {
            XCTAssertEqual(Set(set.files.keys), ["source", "developer"])
            XCTAssertTrue(set.files.values.allSatisfy { $0.count == 64 })
            XCTAssertEqual(set.thumbnailsCommit.count, 40)
        }
        XCTAssertEqual(catalog.datURL(ps2, kind: "source").absoluteString,
                       "https://raw.githubusercontent.com/libretro/libretro-database/\(catalog.databaseCommit)/metadat/redump/Sony%20-%20PlayStation%202.dat")
        XCTAssertEqual(catalog.thumbnailURL(dc, kind: "Named_Boxarts", name: "Crazy Taxi (USA)").deletingLastPathComponent().deletingLastPathComponent().lastPathComponent,
                       dc.thumbnailsCommit)
        XCTAssertEqual(IGDBMetadataProvider.platforms[.dreamcast], 23)
        XCTAssertEqual(IGDBMetadataProvider.platforms[.ps2], 8)
    }

    func testDiscImageHashVariantsMatchRedumpISOEntries() throws {
        let iso = DCPS2Fixtures.ps2ISO(seed: 9)
        let isoHashes = ROMHasher.hash(iso)
        let cso = try write(DCPS2Fixtures.cso(iso), "Game.cso")
        XCTAssertTrue(try ROMHasher.variants(of: cso, system: .ps2).contains(isoHashes), "a .cso hashes as the .iso Redump lists")

        let sha1 = Array(Insecure.SHA1.hash(data: iso))
        let chd = try write(DCPS2Fixtures.chd(tags: ["DVD "], rawSHA1: sha1, logicalBytes: UInt64(iso.count)), "Game.chd")
        let dat = """
            game ( name "Homebrew Two (USA)" region "USA" serial "SLUS-20000" rom ( name "Homebrew Two (USA).iso" size \(iso.count) crc 00000000 md5 00 sha1 \(isoHashes.sha1) ) )
            """
        let index = DatIndex(dat: dat)
        let variants = try ROMHasher.variants(of: chd, system: .ps2)
        XCTAssertEqual(variants.compactMap(index.match).map(\.name), ["Homebrew Two (USA)"], "a DVD CHD matches by the raw SHA-1 in its header")
        let cd = try write(DCPS2Fixtures.chd(tags: ["CHT2"], rawSHA1: sha1), "CD.chd")
        XCTAssertEqual(try ROMHasher.variants(of: cd, system: .ps2).count, 1, "CD CHDs' whole-disc SHA-1 isn't a Redump track hash")
    }

    func testCSOWithOversizedTotalSizeIsRejectedNotTrapped() throws {
        var header = Data("CISO".utf8) + Data([24, 0, 0, 0])
        header += Data(repeating: 0xFF, count: 8)            // total bytes: UInt64.max
        header += Data([0x00, 0x08, 0x00, 0x00])             // block size 2048
        header += Data([1, 0, 0, 0])
        let url = directory.appendingPathComponent("Huge.cso")
        try header.write(to: url)
        XCTAssertThrowsError(try CSOImage(url: url))
    }
}
