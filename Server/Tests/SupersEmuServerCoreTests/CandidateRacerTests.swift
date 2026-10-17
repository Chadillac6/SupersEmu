import Foundation
import SupersEmuKit
import XCTest

private actor CandidateStartRecorder {
    private var startTimes: [URL: ContinuousClock.Instant] = [:]

    func record(_ url: URL) {
        startTimes[url] = .now
    }

    func time(for url: URL) -> ContinuousClock.Instant? {
        startTimes[url]
    }
}

final class CandidateRacerTests: XCTestCase {
    private static let primary = URL(string: "https://primary.example")!
    private static let other = URL(string: "https://other.example")!

    func testFastPrimaryWins() async {
        let primary = Self.primary
        let other = Self.other
        let result = await CandidateRacer.race(primary: primary, others: [other], headStart: .milliseconds(80)) { url -> CandidateAttempt<String> in
            if url == primary {
                try? await Task.sleep(for: .milliseconds(5))
                return .success(url.absoluteString)
            }
            return .failure(.unreachable)
        }
        XCTAssertEqual(result.successURL, primary)
        XCTAssertEqual(result.successValue, primary.absoluteString)
    }

    func testFastPrimarySuccessCancelsHeadStart() async {
        let primary = Self.primary
        let other = Self.other
        let clock = ContinuousClock()
        let start = clock.now
        let result = await CandidateRacer.race(primary: primary, others: [other], headStart: .seconds(2)) { url -> CandidateAttempt<String> in
            try? await Task.sleep(for: .milliseconds(10))
            return url == primary ? .success(url.absoluteString) : .failure(.unreachable)
        }
        XCTAssertEqual(result.successURL, primary)
        XCTAssertLessThan(start.duration(to: clock.now), .milliseconds(500))
    }

    func testPrimarySignedOutCancelsHeadStart() async {
        let primary = Self.primary
        let other = Self.other
        let clock = ContinuousClock()
        let start = clock.now
        let result = await CandidateRacer.race(primary: primary, others: [other], headStart: .seconds(2)) { url -> CandidateAttempt<String> in
            try? await Task.sleep(for: .milliseconds(10))
            return url == primary ? .failure(.signedOut) : .failure(.unreachable)
        }
        XCTAssertEqual(result.failure, .signedOut)
        XCTAssertLessThan(start.duration(to: clock.now), .milliseconds(500))
    }

    func testFastOtherWinsAfterHeadStart() async {
        let primary = Self.primary
        let other = Self.other
        let recorder = CandidateStartRecorder()
        let result = await CandidateRacer.race(primary: primary, others: [other], headStart: .milliseconds(30)) { url -> CandidateAttempt<String> in
            await recorder.record(url)
            if url == primary {
                try? await Task.sleep(for: .milliseconds(200))
                return .success(url.absoluteString)
            }
            try? await Task.sleep(for: .milliseconds(5))
            return .success(url.absoluteString)
        }
        XCTAssertEqual(result.successURL, other)
        XCTAssertEqual(result.successValue, other.absoluteString)
        let primaryStart = await recorder.time(for: primary)
        let otherStart = await recorder.time(for: other)
        XCTAssertNotNil(primaryStart)
        XCTAssertNotNil(otherStart)
        if let primaryStart, let otherStart {
            XCTAssertGreaterThanOrEqual(primaryStart.duration(to: otherStart), .milliseconds(20))
        }
    }

    func testPrimaryFailureStartsOthersImmediately() async {
        let primary = Self.primary
        let other = Self.other
        let recorder = CandidateStartRecorder()
        let result = await CandidateRacer.race(primary: primary, others: [other], headStart: .milliseconds(500)) { url -> CandidateAttempt<String> in
            await recorder.record(url)
            if url == primary { return .failure(.unreachable) }
            return .success(url.absoluteString)
        }
        XCTAssertEqual(result.successURL, other)
        XCTAssertEqual(result.successValue, other.absoluteString)
        let primaryStart = await recorder.time(for: primary)
        let otherStart = await recorder.time(for: other)
        XCTAssertNotNil(primaryStart)
        XCTAssertNotNil(otherStart)
        if let primaryStart, let otherStart {
            XCTAssertLessThan(primaryStart.duration(to: otherStart), .milliseconds(100))
        }
    }

    func testSignedOutAbortsPendingCandidates() async {
        let primary = Self.primary
        let other = Self.other
        let recorder = CandidateStartRecorder()
        let result = await CandidateRacer.race(primary: primary, others: [other], headStart: .zero) { url -> CandidateAttempt<String> in
            if url == primary {
                try? await Task.sleep(for: .milliseconds(20))
                return .failure(.signedOut)
            }
            await recorder.record(url)
            try? await Task.sleep(for: .seconds(5))
            return .success(url.absoluteString)
        }
        XCTAssertEqual(result.failure, .signedOut)
        let otherStart = await recorder.time(for: other)
        XCTAssertNotNil(otherStart)
    }

    func testCertificateMismatchOnlyWinsWhenNothingSucceeds() async {
        let primary = Self.primary
        let other = Self.other
        let mismatch = await CandidateRacer.race(primary: primary, others: [other], headStart: .zero) { url -> CandidateAttempt<String> in
            url == primary ? .failure(.certificateMismatch) : .failure(.unreachable)
        }
        XCTAssertEqual(mismatch.failure, .certificateMismatch)

        let success = await CandidateRacer.race(primary: primary, others: [other], headStart: .zero) { url -> CandidateAttempt<String> in
            url == primary ? .failure(.certificateMismatch) : .success("ok")
        }
        XCTAssertEqual(success.successURL, other)
        XCTAssertEqual(success.successValue, "ok")
    }

    func testNilPrimaryStartsAllAndDeduplicatesURLs() async {
        let other = Self.other
        let recorder = CandidateStartRecorder()
        let result = await CandidateRacer.race(primary: nil, others: [other, other], headStart: .seconds(5)) { url -> CandidateAttempt<String> in
            await recorder.record(url)
            return .success(url.absoluteString)
        }
        XCTAssertEqual(result.successURL, other)
        XCTAssertEqual(result.successValue, other.absoluteString)
        let otherStart = await recorder.time(for: other)
        XCTAssertNotNil(otherStart)
    }
}

private extension CandidateRaceResult where Value == String {
    var successURL: URL? {
        guard case .success(let url, _) = self else { return nil }
        return url
    }

    var successValue: String? {
        guard case .success(_, let value) = self else { return nil }
        return value
    }

    var failure: ConnectionFailure? {
        guard case .failure(let failure) = self else { return nil }
        return failure
    }
}
