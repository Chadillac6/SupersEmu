import CryptoKit
import Foundation
import GRDB
import HummingbirdTesting
import SupersEmuKit
@testable import SupersEmuServerCore
import XCTest

/// Synthetic disc images: only the bytes detection looks at, plus a seed so every track hashes differently.
enum DiscFixtures {
    static let licence = "          Licensed  by          Sony Computer Entertainment Amer  ica "

    /// Raw MODE2/2352 PS1 data track with the licence string in sector 4 of the system area.
    static func psxTrack(seed: UInt8, sectorSize: Int = 2352, sectors: Int = 20) -> Data {
        var bytes = [UInt8](repeating: 0, count: sectors * sectorSize)
        let offset = 4 * sectorSize + (sectorSize == 2352 ? 24 : 0)
        bytes.replaceSubrange(offset..<offset + licence.utf8.count, with: Array(licence.utf8))
        bytes[16 * sectorSize] = seed
        return Data(bytes)
    }

    /// Raw MODE1/2352 Sega CD data track: sync + header, then `SEGADISCSYSTEM` in sector 0's user data.
    static func segaCDTrack(seed: UInt8, sectors: Int = 20) -> Data {
        var bytes = [UInt8](repeating: 0, count: sectors * 2352)
        bytes.replaceSubrange(1..<11, with: [UInt8](repeating: 0xFF, count: 10))
        bytes.replaceSubrange(16..<32, with: Array("SEGADISCSYSTEM  ".utf8))
        bytes[16 * 2352] = seed
        return Data(bytes)
    }

    static func audioTrack(seed: UInt8, sectors: Int = 4) -> Data {
        Data((0..<(sectors * 2352)).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ Int(seed)) })
    }

    /// CRLF cue sheet; the first file is the data track, the rest are audio.
    static func cue(_ files: [String], dataMode: String = "MODE2/2352") -> Data {
        var lines: [String] = []
        for (index, file) in files.enumerated() {
            lines.append("FILE \"\(file)\" BINARY")
            lines.append(String(format: "  TRACK %02d %@", index + 1, index == 0 ? dataMode : "AUDIO"))
            lines.append("    INDEX 01 00:00:00")
        }
        return Data((lines.joined(separator: "\r\n") + "\r\n").utf8)
    }

    static func sha(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
}

extension LibraryTests {
    struct FileRow: Equatable { var filename: String; var role: String; var disc: Int? }

    func fileRows(_ gameID: String) async throws -> [FileRow] {
        try await store.db.read { db in
            try Row.fetchAll(db, sql: "SELECT filename, role, disc_number FROM game_files WHERE game_id = ? ORDER BY disc_number, role, filename",
                             arguments: [gameID]).map { FileRow(filename: $0["filename"], role: $0["role"], disc: $0["disc_number"]) }
        }
    }

    @discardableResult
    func writeCueGame(_ folder: String, name: String, tracks: [Data], dataMode: String = "MODE2/2352", in root: URL? = nil) throws -> URL {
        let names = tracks.indices.map { "\(name) (Track \($0 + 1)).bin" }
        for (track, file) in Swift.zip(tracks, names) { try write(track, "\(folder)/\(file)", in: root) }
        return try write(DiscFixtures.cue(names, dataMode: dataMode), "\(folder)/\(name).cue", in: root)
    }

    // MARK: Units

    func testCueSheetParsingAndNormalization() throws {
        let text = "\u{FEFF}REM x\r\nFILE \"Game (Track 1).BIN\" BINARY\r\n  TRACK 01 MODE2/2352\r\nFILE Track2.Bin BINARY\r\n  TRACK 02 AUDIO\r\n"
        let cue = try XCTUnwrap(CueSheet(data: Data(text.utf8)))
        XCTAssertEqual(cue.files.map(\.name), ["Game (Track 1).BIN", "Track2.Bin"])
        XCTAssertEqual(cue.files.map(\.isData), [true, false])
        XCTAssertEqual(String(decoding: cue.normalized, as: UTF8.self),
                       "REM x\nFILE \"game (track 1).bin\" BINARY\n  TRACK 01 MODE2/2352\nFILE track2.bin BINARY\n  TRACK 02 AUDIO\n")
        let rewritten = String(decoding: cue.rewritten(names: [3: "Disc 2 - Track2.bin"]), as: UTF8.self)
        XCTAssertTrue(rewritten.contains("FILE \"Disc 2 - Track2.bin\" BINARY"), rewritten)
        XCTAssertTrue(rewritten.contains("FILE \"Game (Track 1).BIN\" BINARY"))
        XCTAssertNil(CueSheet(data: Data("not a cue".utf8)))
        let tabbed = try XCTUnwrap(CueSheet(data: Data("FILE\tTrack.bin\tBINARY\n  TRACK 01 MODE1/2352\nFILE Two Words.bin  \t BINARY\n".utf8)))
        XCTAssertEqual(tabbed.files.map(\.name), ["Track.bin", "Two Words.bin"])
    }

    func testDiscNameParsing() {
        let a = DiscName(filename: "Final Fantasy VII (USA) (Disc 2).cue")
        XCTAssertEqual(a.title, "Final Fantasy VII")
        XCTAssertEqual(a.discNumber, 2)
        XCTAssertEqual(a.tags, "usa")
        XCTAssertEqual(DiscName(filename: "Game (Europe) (CD 1).cue").discNumber, 1)
        let b = DiscName(filename: "Game (USA) (Rev 1) Disc 3 of 4.cue")
        XCTAssertEqual(b.discNumber, 3)
        XCTAssertEqual(b.discCount, 4)
        XCTAssertEqual(b.tags, "rev 1|usa")
        XCTAssertNotEqual(DiscName(filename: "Game (USA) (Disc 1).cue").groupKey, DiscName(filename: "Game (Europe) (Disc 1).cue").groupKey)
        XCTAssertNil(DiscName(filename: "Discworld (USA).cue").discNumber)
        XCTAssertEqual(DiscName(filename: "game.cue", folder: "Game (USA) (Disc 2)").discNumber, 2)
        XCTAssertEqual(DiscName(filename: "game.cue", folder: "Game (USA) (Rev 1) (Disc 2)").tags, "rev 1|usa")
        XCTAssertEqual(DiscName(filename: "Game (USA).cue", folder: "Game (USA) (Disc 2)").tags, "usa")
    }

    func testDiscHeaderDetection() {
        XCTAssertEqual(SystemDetector.detectDisc(header: DiscFixtures.psxTrack(seed: 1)), .psx)
        XCTAssertEqual(SystemDetector.detectDisc(header: DiscFixtures.psxTrack(seed: 1, sectorSize: 2048)), .psx)
        XCTAssertEqual(SystemDetector.detectDisc(header: DiscFixtures.segaCDTrack(seed: 1)), .segacd)
        XCTAssertEqual(SystemDetector.detectDisc(header: Data("SEGA SEGASYSTEM ".utf8) + Data(count: 2032)), .segacd)
        XCTAssertNil(SystemDetector.detectDisc(header: DiscFixtures.audioTrack(seed: 1)))
    }

    // MARK: Cue / bin

    func testCueGameGroupsTracksWithSpecID() async throws {
        let data = DiscFixtures.psxTrack(seed: 1), audio = DiscFixtures.audioTrack(seed: 2)
        try writeCueGame("PS1/Wipeout (USA)", name: "Wipeout (USA)", tracks: [data, audio])

        let report = try await importer.importPaths([sources.path], auth: nil)
        XCTAssertEqual(report.needsReview, [])
        let game = try XCTUnwrap(report.imported.first)
        XCTAssertEqual(report.imported.count, 1, "tracks are part of the cue game, not separate Genesis reviews")
        XCTAssertEqual(game.system, .psx)
        XCTAssertEqual(game.title, "Wipeout")

        // ID = SHA-256(normalized cue + each track's SHA-256 hex, in cue order).
        let normalized = "FILE \"wipeout (usa) (track 1).bin\" BINARY\n  TRACK 01 MODE2/2352\n    INDEX 01 00:00:00\n"
            + "FILE \"wipeout (usa) (track 2).bin\" BINARY\n  TRACK 02 AUDIO\n    INDEX 01 00:00:00\n"
        XCTAssertEqual(game.id, DiscFixtures.sha(Data((normalized + DiscFixtures.sha(data) + DiscFixtures.sha(audio)).utf8)))
        let rows = try await fileRows(game.id)
        XCTAssertEqual(rows, [
            FileRow(filename: "Wipeout (USA).cue", role: "cue", disc: 1),
            FileRow(filename: "Wipeout (USA) (Track 1).bin", role: "disc", disc: 1),
            FileRow(filename: "Wipeout (USA) (Track 2).bin", role: "disc", disc: 1),
        ])

        // Files are served by content hash and the cue is stored byte-for-byte (names didn't change).
        let detail = try XCTUnwrap(try LibraryAccess.detail(gameID: game.id, auth: try store.authenticate(token: adminToken)!, store: store))
        XCTAssertEqual(detail.files.first { $0.role == .cue }?.id, DiscFixtures.sha(try Data(contentsOf: sources.appendingPathComponent("PS1/Wipeout (USA)/Wipeout (USA).cue"))))

        // Renaming the folder keeps the ID; re-import is a duplicate.
        try FileManager.default.moveItem(at: sources.appendingPathComponent("PS1/Wipeout (USA)"), to: sources.appendingPathComponent("PS1/Renamed"))
        let again = try await importer.importPaths([sources.path], auth: nil)
        XCTAssertEqual(again.imported, [])
        XCTAssertEqual(again.duplicates, 1)
    }

    func testMissingTrackGoesToReview() async throws {
        try write(DiscFixtures.psxTrack(seed: 3), "Broken/Broken (Track 1).bin")
        try write(DiscFixtures.cue(["Broken (Track 1).bin", "Broken (Track 2).bin"]), "Broken/Broken.cue")
        let report = try await importer.importPaths([sources.path], auth: nil)
        XCTAssertEqual(report.imported, [])
        XCTAssertEqual(report.needsReview.map(\.filename), ["Broken.cue"])
        XCTAssertEqual(report.needsReview.first?.reason, "Missing track: Broken (Track 2).bin")
        XCTAssertEqual(try importer.reviewQueue().map(\.reason), ["Missing track: Broken (Track 2).bin"])

        // Supplying the track imports the game and clears the review entry.
        try write(DiscFixtures.audioTrack(seed: 4), "Broken/Broken (Track 2).bin")
        let fixed = try await importer.importPaths([sources.path], auth: nil)
        XCTAssertEqual(fixed.imported.map(\.system), [.psx])
        XCTAssertEqual(try importer.reviewQueue(), [])
    }

    func testCueInZipAndSegaCD() async throws {
        let zipSource = sources.appendingPathComponent("zipsrc", isDirectory: true)
        try writeCueGame("Sonic CD (USA)", name: "Sonic CD (USA)", tracks: [DiscFixtures.segaCDTrack(seed: 5), DiscFixtures.audioTrack(seed: 6)],
                         dataMode: "MODE1/2352", in: zipSource)
        let archive = try zip("Sonic CD (USA).zip", in: zipSource, files: ["Sonic CD (USA)"])
        let report = try await importer.importPaths([archive.path], auth: nil)
        XCTAssertEqual(report.imported.map(\.system), [.segacd])
        XCTAssertEqual(report.imported.map(\.title), ["Sonic CD"])
        let rows = try await fileRows(try XCTUnwrap(report.imported.first?.id))
        XCTAssertEqual(rows.map(\.role).sorted(), ["cue", "disc", "disc"])
    }

    func testLooseBinKeepsGenesisDetection() async throws {
        try write(ROMFixtures.genesis(seed: 9), "Sega/Streets of Rage.bin")
        try write(DiscFixtures.segaCDTrack(seed: 1), "Sega/Loose CD.bin")
        try writeCueGame("PS1/Game", name: "Game", tracks: [DiscFixtures.psxTrack(seed: 9)])
        let report = try await importer.importPaths([sources.path], auth: nil)
        XCTAssertEqual(Set(report.imported.map(\.system)), [.genesis, .psx])
        XCTAssertEqual(report.needsReview.map(\.reason), ["Sega CD disc image without a .cue sheet"])
    }

    // MARK: Multi-disc

    func testInferredMultiDiscSetWithGeneratedM3U() async throws {
        var ids: [String] = []
        for disc in 1...3 {
            // Every disc uses the same track filename in its own folder, so stored names must be made unique.
            let track = DiscFixtures.psxTrack(seed: UInt8(10 + disc))
            try write(track, "FF7/Disc \(disc)/Track 01.bin")
            let cue = DiscFixtures.cue(["Track 01.bin"])
            try write(cue, "FF7/Disc \(disc)/Final Fantasy VII (USA) (Disc \(disc)).cue")
            let normalized = String(decoding: cue, as: UTF8.self).replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "Track 01", with: "track 01")
            ids.append(DiscFixtures.sha(Data((normalized + DiscFixtures.sha(track)).utf8)))
        }
        // Same title, other region: a separate game.
        for disc in 1...2 {
            try writeCueGame("FF7 EU", name: "Final Fantasy VII (Europe) (Disc \(disc))", tracks: [DiscFixtures.psxTrack(seed: UInt8(20 + disc))])
        }

        let report = try await importer.importPaths([sources.path], auth: nil)
        XCTAssertEqual(report.needsReview, [])
        XCTAssertEqual(report.imported.count, 2)
        let usa = try XCTUnwrap(report.imported.first { $0.id == DiscFixtures.sha(Data(ids.sorted().joined(separator: "\n").utf8)) })
        XCTAssertEqual(usa.title, "Final Fantasy VII")
        let rows = try await fileRows(usa.id)
        XCTAssertEqual(rows, [
            FileRow(filename: "Final Fantasy VII.m3u", role: "m3u", disc: nil),
            FileRow(filename: "Final Fantasy VII (USA) (Disc 1).cue", role: "cue", disc: 1),
            FileRow(filename: "Track 01.bin", role: "disc", disc: 1),
            FileRow(filename: "Final Fantasy VII (USA) (Disc 2).cue", role: "cue", disc: 2),
            FileRow(filename: "Disc 2 - Track 01.bin", role: "disc", disc: 2),
            FileRow(filename: "Final Fantasy VII (USA) (Disc 3).cue", role: "cue", disc: 3),
            FileRow(filename: "Disc 3 - Track 01.bin", role: "disc", disc: 3),
        ])
        let dir = store.paths.games.appendingPathComponent(usa.id)
        XCTAssertEqual(try String(contentsOf: dir.appendingPathComponent("Final Fantasy VII.m3u"), encoding: .utf8),
                       "Final Fantasy VII (USA) (Disc 1).cue\nFinal Fantasy VII (USA) (Disc 2).cue\nFinal Fantasy VII (USA) (Disc 3).cue\n")
        let cue2 = try String(contentsOf: dir.appendingPathComponent("Final Fantasy VII (USA) (Disc 2).cue"), encoding: .utf8)
        XCTAssertTrue(cue2.contains("FILE \"Disc 2 - Track 01.bin\" BINARY"), "stored cue points at the stored track name")
        let cueRow = try await store.db.read { db in
            try String.fetchOne(db, sql: "SELECT id FROM game_files WHERE game_id = ? AND filename = ?", arguments: [usa.id, "Final Fantasy VII (USA) (Disc 2).cue"])
        }
        XCTAssertEqual(cueRow, DiscFixtures.sha(Data(cue2.utf8)), "file IDs hash the stored bytes")
    }

    func testIncompleteDiscSetGoesToReview() async throws {
        for disc in [1, 3] { try writeCueGame("Set", name: "Game (USA) (Disc \(disc))", tracks: [DiscFixtures.psxTrack(seed: UInt8(disc))]) }
        let report = try await importer.importPaths([sources.path], auth: nil)
        XCTAssertEqual(report.imported, [])
        XCTAssertEqual(Set(report.needsReview.map(\.reason)), ["Disc set is missing Disc 2"])
        XCTAssertEqual(report.needsReview.count, 2)
    }

    func testFolderRegionsAndContradictoryCountsDoNotGroup() async throws {
        for (region, disc) in [("USA", 1), ("Europe", 2)] {
            try write(DiscFixtures.psxTrack(seed: UInt8(60 + disc)), "Game (\(region)) (Disc \(disc))/track.bin")
            try write(DiscFixtures.cue(["track.bin"]), "Game (\(region)) (Disc \(disc))/game.cue")
        }
        let regions = try await importer.importPaths([sources.path], auth: nil)
        // A lone Disc 1 is a one-disc game; the Europe Disc 2 isn't merged into it.
        XCTAssertEqual(regions.imported.count, 1)
        XCTAssertEqual(regions.needsReview.map(\.reason), ["Disc set is missing Disc 1"])
        let loneRows = try await fileRows(regions.imported[0].id)
        XCTAssertEqual(loneRows.compactMap(\.disc), [1, 1])

        let other = sources.appendingPathComponent("counts", isDirectory: true)
        for disc in 1...2 { try writeCueGame("", name: "Odd Disc \(disc) of 1", tracks: [DiscFixtures.psxTrack(seed: UInt8(70 + disc))], in: other) }
        let counts = try await importer.importPaths([other.path], auth: nil)
        XCTAssertEqual(counts.imported, [])
        XCTAssertEqual(Set(counts.needsReview.map(\.reason)), ["Disc set says 1 discs but has 2"])
    }

    func testUnreadableCueKeepsItsTracksInIncoming() async throws {
        let incoming = store.paths.incoming
        try write(Data("garbage".utf8), "Game/Game.cue", in: incoming)
        try write(ROMFixtures.genesis(seed: 77), "Game/Game (Track 1).bin", in: incoming)
        try write(ROMFixtures.genesis(seed: 78), "Game/Other Cart.bin", in: incoming)
        try write(ROMFixtures.genesis(seed: 79), "Game/Gameplay.bin", in: incoming)
        XCTAssertTrue(LibraryImporter.isTrackName("Game - Track 01.bin", of: "game"))
        XCTAssertTrue(LibraryImporter.isTrackName("GAME.bin", of: "game"))
        XCTAssertFalse(LibraryImporter.isTrackName("Gameplay.bin", of: "game"))
        let report = try await importer.scanIncoming(auth: nil)
        XCTAssertEqual(Set(report.imported.map(\.title)), ["Other Cart", "Gameplay"])
        XCTAssertEqual(report.unsupported.count, 2, "\(report.unsupported)")
        XCTAssertTrue(FileManager.default.fileExists(atPath: incoming.appendingPathComponent("Game/Game (Track 1).bin").path))
    }

    func testUserM3UOverridesInferredGrouping() async throws {
        try writeCueGame("Odd", name: "Start Here", tracks: [DiscFixtures.psxTrack(seed: 31)])
        try writeCueGame("Odd", name: "Then This", tracks: [DiscFixtures.psxTrack(seed: 32)])
        try write(Data("#EXTM3U\nStart Here.cue\nThen This.cue\n".utf8), "Odd/Odd Game (USA).m3u")
        let report = try await importer.importPaths([sources.path], auth: nil)
        XCTAssertEqual(report.needsReview, [])
        XCTAssertEqual(report.imported.map(\.title), ["Odd Game"])
        let rows = try await fileRows(try XCTUnwrap(report.imported.first?.id))
        XCTAssertEqual(rows.filter { $0.role == "cue" }.map(\.filename), ["Start Here.cue", "Then This.cue"])
        XCTAssertEqual(rows.filter { $0.role == "m3u" }.count, 1)

        try write(Data("Start Here.cue\nGone.cue\n".utf8), "Other/Broken.m3u")
        try writeCueGame("Other", name: "Start Here", tracks: [DiscFixtures.psxTrack(seed: 33)])
        let broken = try await importer.importPaths([sources.appendingPathComponent("Other").path], auth: nil)
        XCTAssertEqual(broken.needsReview.map(\.reason), ["Missing disc: Gone.cue"])
        try writeCueGame("Other", name: "Gone", tracks: [DiscFixtures.psxTrack(seed: 34)])
        let fixed = try await importer.importPaths([sources.appendingPathComponent("Other").path], auth: nil)
        XCTAssertEqual(fixed.imported.map(\.title), ["Broken"])
        XCTAssertEqual(try importer.reviewQueue(), [], "the playlist's review entry is cleared once the game imports")
    }

    func testISOAndCHDSingleFileDiscs() async throws {
        let iso = DiscFixtures.psxTrack(seed: 40, sectorSize: 2048)
        try write(iso, "Discs/Ape Escape (USA).iso")
        let chd = Data("MComprHD".utf8) + Data(repeating: 7, count: 100)
        try write(chd, "PlayStation/Crash (USA).chd")
        try write(Data("MComprHD".utf8) + Data(repeating: 8, count: 100), "Misc/Unknown.chd")
        let report = try await importer.importPaths([sources.path], auth: nil)
        XCTAssertEqual(Set(report.imported.map(\.title)), ["Ape Escape", "Crash"])
        XCTAssertEqual(Set(report.imported.map(\.system)), [.psx])
        XCTAssertEqual(Set(report.imported.map(\.id)), [DiscFixtures.sha(iso), DiscFixtures.sha(chd)], "single-file discs keep the file hash as ID")
        XCTAssertEqual(report.needsReview.map(\.filename), ["Unknown.chd"])
        let rows = try await fileRows(DiscFixtures.sha(iso))
        XCTAssertEqual(rows, [FileRow(filename: "Ape Escape (USA).iso", role: "disc", disc: 1)])
    }

    func testScanMovesDiscOnlyWhenWholeGameImported() async throws {
        let incoming = store.paths.incoming
        try writeCueGame("Good (USA)", name: "Good (USA)", tracks: [DiscFixtures.psxTrack(seed: 50), DiscFixtures.audioTrack(seed: 51)], in: incoming)
        try write(DiscFixtures.psxTrack(seed: 52), "Bad/Bad (Track 1).bin", in: incoming)
        try write(DiscFixtures.cue(["Bad (Track 1).bin", "Bad (Track 2).bin"]), "Bad/Bad.cue", in: incoming)
        let report = try await importer.scanIncoming(auth: nil)
        XCTAssertEqual(report.imported.map(\.title), ["Good"])
        let fm = FileManager.default
        let done = importer.importedDirectory.appendingPathComponent(LibraryImporter.dayFormatter.string(from: Date()))
        XCTAssertTrue(fm.fileExists(atPath: done.appendingPathComponent("Good (USA)/Good (USA).cue").path))
        XCTAssertTrue(fm.fileExists(atPath: done.appendingPathComponent("Good (USA)/Good (USA) (Track 2).bin").path))
        XCTAssertTrue(fm.fileExists(atPath: incoming.appendingPathComponent("Bad/Bad.cue").path))
        XCTAssertTrue(fm.fileExists(atPath: incoming.appendingPathComponent("Bad/Bad (Track 1).bin").path))
    }

    func testZipExtractStreamsLargeDeflatedEntries() throws {
        let zipSource = sources.appendingPathComponent("zipsrc", isDirectory: true)
        let big = Data((0..<(3 << 20)).map { UInt8(truncatingIfNeeded: $0 / 7) })
        try write(big, "big.bin", in: zipSource)
        let archive = try ZipArchive(url: try zip("big.zip", in: zipSource, files: ["big.bin"]))
        let out = sources.appendingPathComponent("out.bin")
        try archive.extract(archive.entries[0], to: out)
        XCTAssertEqual(try Data(contentsOf: out), big)
    }

    // MARK: Messy library

    func testMessyLibraryOf200Files() async throws {
        let expected = try MessyLibrary.generate(at: sources)
        XCTAssertEqual(expected.fileCount, 200)
        let report = try await importer.importPaths([sources.path], auth: nil)

        XCTAssertEqual(report.imported.count, expected.games.values.reduce(0, +), "\(report.needsReview) \(report.unsupported)")
        XCTAssertEqual(Dictionary(grouping: report.imported, by: \.system).mapValues(\.count), expected.games)
        XCTAssertEqual(report.duplicates, expected.duplicates)
        XCTAssertEqual(Set(report.needsReview.map(\.filename)), expected.review)
        XCTAssertEqual(report.unsupported.count, expected.unsupported, "\(report.unsupported)")

        let quests = report.imported.filter { $0.title == "Mega Quest" && $0.system == .psx }
        XCTAssertEqual(quests.count, 2, "USA and Europe sets stay separate")
        var discCounts: Set<Int> = []
        for quest in quests {
            let rows = try await fileRows(quest.id)
            discCounts.insert(rows.compactMap(\.disc).max() ?? 0)
            XCTAssertEqual(rows.filter { $0.role == "m3u" }.count, 1)
        }
        XCTAssertEqual(discCounts, [2, 3])
        XCTAssertEqual(report.imported.filter { $0.title == "Puzzle 03" }.count, 3, "USA, Europe and Rev 1 are separate games")

        // Everything in the library is consistent: each game's files exist under games/<id>/.
        let paths = try await store.db.read { try String.fetchAll($0, sql: "SELECT stored_path FROM game_files") }
        for path in paths { XCTAssertTrue(FileManager.default.fileExists(atPath: store.paths.root.appendingPathComponent(path).path), path) }
        let again = try await importer.importPaths([sources.path], auth: nil)
        XCTAssertEqual(again.imported, [])
    }

    // MARK: BIOS

    func testBIOSRecognizedByHashAndServed() async throws {
        let bytes = Data((0..<2048).map { UInt8(truncatingIfNeeded: $0 * 13) })
        let table = [KnownBIOS(filename: "scph5501.bin", system: .psx, region: "US", required: true,
                               md5: Insecure.MD5.hash(data: bytes).map { String(format: "%02x", $0) }.joined(), size: 2048),
                     KnownBIOS(filename: "bios_CD_U.bin", system: .segacd, region: "US", required: true, md5: "00", size: 4096)]
        try write(bytes, "Downloads/some random name.bin")
        try write(Data(count: 99), "Downloads/bios_cd_u.bin")
        let custom = LibraryImporter(store: store, knownBIOS: table)
        let report = try await custom.importPaths([sources.path], auth: nil)
        let sha = DiscFixtures.sha(bytes)
        XCTAssertEqual(report.bios, [BIOSFileInfo(id: sha, filename: "scph5501.bin", system: .psx, region: "US", required: true)])
        XCTAssertEqual(report.imported, [], "BIOS files are not games")
        XCTAssertEqual(report.unsupported.count, 1)
        XCTAssertTrue(report.unsupported[0].contains("isn't a known good dump"))
        XCTAssertEqual(try Data(contentsOf: store.paths.bios.appendingPathComponent("\(sha)/scph5501.bin")), bytes)
        XCTAssertEqual(try BIOSLibrary.status(store: store, known: table).map(\.state), [.present, .wrongHash])
        let again = try await custom.importPaths([sources.appendingPathComponent("Downloads/some random name.bin").path], auth: nil)
        XCTAssertEqual(again.duplicates, 1)

        let (_, noRead) = try store.createAPIToken(ownerUserID: admin.id, name: "saves-only", scopes: [.savesRead])
        try await app().test(.router) { client in
            try await client.execute(uri: "/v1/bios", method: .get, headers: self.auth(self.adminToken)) {
                XCTAssertEqual($0.status, .ok)
                XCTAssertEqual(try self.decode([BIOSFileInfo].self, $0).map(\.id), [sha])
            }
            try await client.execute(uri: "/v1/bios/status", method: .get, headers: self.auth(self.adminToken)) {
                XCTAssertEqual($0.status, .ok)
                XCTAssertEqual(try self.decode([BIOSStatus].self, $0).map(\.filename), KnownBIOS.all.map(\.filename))
            }
            let uri = "/v1/bios/\(sha)"
            try await client.execute(uri: uri, method: .get, headers: self.auth(self.adminToken)) {
                XCTAssertEqual($0.status, .ok)
                XCTAssertEqual($0.headers[.eTag], "\"\(sha)\"")
                XCTAssertEqual(Data(buffer: $0.body), bytes)
            }
            var headers = self.auth(self.adminToken)
            headers[.range] = "bytes=10-19"
            try await client.execute(uri: uri, method: .get, headers: headers) {
                XCTAssertEqual($0.status, .partialContent)
                XCTAssertEqual(Data(buffer: $0.body), bytes[10...19])
            }
            var conditional = self.auth(self.adminToken)
            conditional[.ifNoneMatch] = "\"\(sha)\""
            try await client.execute(uri: uri, method: .get, headers: conditional) { XCTAssertEqual($0.status, .notModified) }
            try await client.execute(uri: "/v1/bios/\(String(repeating: "0", count: 64))", method: .get, headers: self.auth(self.adminToken)) {
                XCTAssertEqual($0.status, .notFound)
            }
            for path in ["/v1/bios", uri, "/v1/bios/status"] {
                try await client.execute(uri: path, method: .get, headers: self.auth(noRead)) { XCTAssertEqual($0.status, .forbidden) }
                try await client.execute(uri: path, method: .get) { XCTAssertEqual($0.status, .unauthorized) }
            }
        }
    }

    func testKnownBIOSTableAndWrongHashWithRealTable() async throws {
        XCTAssertEqual(Set(KnownBIOS.all.map(\.filename)),
                       ["scph5500.bin", "scph5501.bin", "scph5502.bin", "bios_CD_U.bin", "bios_CD_E.bin", "bios_CD_J.bin"])
        XCTAssertTrue(KnownBIOS.all.allSatisfy { $0.md5.count == 32 })
        try write(Data(count: 524_288), "SCPH5501.BIN")
        let report = try await importer.importPaths([sources.path], auth: nil)
        XCTAssertNil(report.bios)
        XCTAssertEqual(report.imported, [])
        let status = try BIOSLibrary.status(store: store, known: KnownBIOS.all)
        XCTAssertEqual(status.first { $0.filename == "scph5501.bin" }?.state, .wrongHash)
        XCTAssertEqual(status.filter { $0.state == .missing }.count, 5)
    }
}

/// Builds a 200-file messy library at test time and records what a correct import produces.
enum MessyLibrary {
    struct Expected {
        var fileCount = 0
        var games: [SystemID: Int] = [:]
        var duplicates = 0
        var review: Set<String> = []
        var unsupported = 0
    }

    static func generate(at root: URL) throws -> Expected {
        var expected = Expected()
        func put(_ data: Data, _ path: String) throws {
            let url = root.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url)
            expected.fileCount += 1
        }
        func game(_ system: SystemID) { expected.games[system, default: 0] += 1 }
        func cueGame(_ folder: String, _ name: String, _ tracks: [Data], mode: String = "MODE2/2352") throws {
            let names = tracks.indices.map { "\(name) (Track \($0 + 1)).bin" }
            for (track, file) in zip(tracks, names) { try put(track, "\(folder)/\(file)") }
            try put(DiscFixtures.cue(names, dataMode: mode), "\(folder)/\(name).cue")
        }

        // Cartridges, nested by letter, with region/revision variants of the same title.
        for i in 0..<30 { try put(ROMFixtures.snes(seed: UInt8(i)), "SNES/\(i < 15 ? "A-M" : "N-Z")/Puzzle \(String(format: "%02d", i)) (USA).sfc"); game(.snes) }
        for i in 0..<10 { try put(ROMFixtures.snes(seed: UInt8(100 + i)), "SNES/Europe/Puzzle \(String(format: "%02d", i)) (Europe).sfc"); game(.snes) }
        for i in 0..<5 { try put(ROMFixtures.snes(seed: UInt8(150 + i)), "SNES/Revisions/Puzzle \(String(format: "%02d", i)) (USA) (Rev 1).sfc"); game(.snes) }
        for i in 0..<12 { try put(ROMFixtures.snes(seed: UInt8(i)), "SNES/Z Backups/backup copy \(i).sfc"); expected.duplicates += 1 }
        for i in 0..<15 { try put(ROMFixtures.gameBoy(seed: UInt8(i)), "Nintendo/GB/Pocket \(i).gb"); game(.gb) }
        for i in 0..<5 { try put(ROMFixtures.gameBoy(cgbFlag: 0x80, seed: UInt8(50 + i)), "Nintendo/GBC/Color \(i).gbc"); game(.gbc) }
        for i in 0..<15 { try put(ROMFixtures.gba(seed: UInt8(i)), "Nintendo/GBA/Advance \(i).gba"); game(.gba) }
        for i in 0..<10 { try put(ROMFixtures.genesis(seed: UInt8(i)), "Sega/Genesis/Blast \(i).md"); game(.genesis) }
        for i in 0..<5 { try put(ROMFixtures.genesis(seed: UInt8(100 + i)), "Sega/Genesis/Loose \(i).bin"); game(.genesis) }

        // Junk: hidden files, notes and scans are skipped without a word.
        for i in 0..<5 { try put(Data("ds".utf8), "Junk\(i)/.DS_Store") }
        for i in 0..<3 { try put(Data("apple".utf8), "SNES/._Puzzle \(i).sfc") }
        for i in 0..<5 { try put(Data("read me".utf8), "Nintendo/readme \(i).txt") }
        for i in 0..<5 { try put(Data("nfo".utf8), "Sega/release \(i).nfo") }
        for i in 0..<5 { try put(Data([0xFF, 0xD8, UInt8(i)]), "Covers/cover \(i).jpg") }
        for i in 0..<5 { try put(Data([0x89, 0x50, UInt8(i)]), "Covers/box \(i).png") }

        // Unknowns go to review; patches are reported.
        for i in 0..<6 { try put(Data(repeating: UInt8(i), count: 64), "Misc/Thing \(i).xyz"); expected.review.insert("Thing \(i).xyz") }
        for i in 0..<3 { try put(Data(repeating: UInt8(200 + i), count: 0x4000), "Misc/Blank \(i).bin"); expected.review.insert("Blank \(i).bin") }
        for i in 0..<2 { try put(Data("PATCH\(i)".utf8), "Misc/fix \(i).ips"); expected.unsupported += 1 }

        // Discs.
        for i in 0..<4 {
            try cueGame("PS1/Racer \(i) (USA)", "Racer \(i) (USA)", [DiscFixtures.psxTrack(seed: UInt8(i)), DiscFixtures.audioTrack(seed: UInt8(i))])
            game(.psx)
        }
        for disc in 1...3 { try cueGame("PS1/Mega Quest (USA)", "Mega Quest (USA) (Disc \(disc))", [DiscFixtures.psxTrack(seed: UInt8(10 + disc))]) }
        game(.psx)
        for disc in 1...2 { try cueGame("PS1/Mega Quest (Europe)", "Mega Quest (Europe) (Disc \(disc))", [DiscFixtures.psxTrack(seed: UInt8(20 + disc))]) }
        game(.psx)
        for i in 0..<3 {
            try cueGame("Sega CD/Spin \(i) (USA)", "Spin \(i) (USA)", [DiscFixtures.segaCDTrack(seed: UInt8(i)), DiscFixtures.audioTrack(seed: UInt8(40 + i))], mode: "MODE1/2352")
            game(.segacd)
        }
        try cueGame("PS1/Odd", "First", [DiscFixtures.psxTrack(seed: 60)])
        try cueGame("PS1/Odd", "Second", [DiscFixtures.psxTrack(seed: 61)])
        try put(Data("First.cue\nSecond.cue\n".utf8), "PS1/Odd/Odd Pair (USA).m3u")
        game(.psx)
        try put(DiscFixtures.psxTrack(seed: 70), "PS1/Broken/Broken (Track 1).bin")
        try put(DiscFixtures.cue(["Broken (Track 1).bin", "Broken (Track 2).bin"]), "PS1/Broken/Broken.cue")
        expected.review.insert("Broken.cue")
        for i in 0..<2 { try put(DiscFixtures.psxTrack(seed: UInt8(80 + i), sectorSize: 2048), "PS1/ISO/Image \(i) (USA).iso"); game(.psx) }
        try put(Data("MComprHD".utf8) + Data(repeating: 1, count: 64), "PS1/CHD/Compressed (USA).chd"); game(.psx)
        try put(Data("MComprHD".utf8) + Data(repeating: 2, count: 64), "Misc/Mystery.chd"); expected.review.insert("Mystery.chd")
        try cueGame("Backup/Racer 0 (USA)", "Racer 0 (USA)", [DiscFixtures.psxTrack(seed: 0), DiscFixtures.audioTrack(seed: 0)])
        expected.duplicates += 1

        // Zipped Sega CD game, built with /usr/bin/zip from a scratch folder outside the library.
        let scratch = root.deletingLastPathComponent().appendingPathComponent("messy-zip-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        let folder = scratch.appendingPathComponent("Zipped (USA)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try DiscFixtures.segaCDTrack(seed: 90).write(to: folder.appendingPathComponent("Zipped (USA) (Track 1).bin"))
        try DiscFixtures.cue(["Zipped (USA) (Track 1).bin"], dataMode: "MODE1/2352").write(to: folder.appendingPathComponent("Zipped (USA).cue"))
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        process.currentDirectoryURL = scratch
        process.arguments = ["-q", "-r", "Zipped.zip", "Zipped (USA)"]
        try process.run()
        process.waitUntilExit()
        try put(try Data(contentsOf: scratch.appendingPathComponent("Zipped.zip")), "Sega CD/Zipped.zip")
        game(.segacd)

        // Pad with more SNES carts to exactly 200 files.
        var pad = 0
        while expected.fileCount < 200 {
            try put(ROMFixtures.snes(seed: UInt8(200 + pad)), "SNES/More/Extra \(pad).smc")
            game(.snes)
            pad += 1
        }
        return expected
    }
}
