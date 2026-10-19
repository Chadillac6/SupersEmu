import CryptoKit
import Foundation
import SupersEmuKit
import XCTest

final class SharedHelpersTests: XCTestCase {
    func testSHA256HexIsLowercaseAndMatchesKnownVector() {
        XCTAssertEqual(Hashing.sha256Hex(Data("abc".utf8)), "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        XCTAssertEqual(Hashing.sha256Hex(Data()), "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
    }

    func testHexStringFormatsEveryByteAsTwoLowercaseDigits() {
        XCTAssertEqual([UInt8]([0x00, 0x0a, 0xff, 0x7f]).hexString, "000aff7f")
        XCTAssertEqual(Insecure.MD5.hash(data: Data("abc".utf8)).hexString, "900150983cd24fb0d6963f7d28e17f72")
    }

    func testFileHashMatchesInMemoryHashAcrossChunkBoundary() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("hash-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: url) }
        let data = Data((0..<((1 << 20) + 17)).map { UInt8(truncatingIfNeeded: $0 * 31) })
        try data.write(to: url)
        XCTAssertEqual(try Hashing.sha256Hex(ofFileAt: url), Hashing.sha256Hex(data))

        var hasher = SHA256()
        XCTAssertEqual(try Hashing.update(&hasher, withContentsOf: url), Int64(data.count))
        XCTAssertEqual(hasher.finalize().hexString, Hashing.sha256Hex(data))
    }

    func testLockedValueReadsWritesAndMutatesUnderConcurrency() async {
        let counter = LockedValue(0)
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<100 { group.addTask { counter.withLock { $0 += 1 } } }
        }
        XCTAssertEqual(counter.value, 100)
        counter.value = 7
        XCTAssertEqual(counter.withLock { $0 * 2 }, 14)
    }

    func testOnceContinuationResumesOnlyTheFirstCaller() async {
        let once = OnceContinuation<Int, Never>()
        let firstWon = LockedValue<Bool?>(nil)
        let laterWon = LockedValue<Bool?>(nil)
        let value = await withCheckedContinuation { continuation in
            once.install(continuation)
            firstWon.value = once.resume(returning: 1)
            laterWon.value = once.resume(returning: 2)
        }
        XCTAssertEqual(value, 1)
        XCTAssertEqual(firstWon.value, true)
        XCTAssertEqual(laterWon.value, false)
        XCTAssertFalse(once.resume(returning: 3))
    }

    func testOnceContinuationBeforeInstallIsANoOp() async throws {
        let once = OnceContinuation<Int, Error>()
        XCTAssertFalse(once.resume(throwing: CancellationError()))
        let value = try await withCheckedThrowingContinuation { continuation in
            once.install(continuation)
            once.resume(returning: 5)
        }
        XCTAssertEqual(value, 5)
    }
}
