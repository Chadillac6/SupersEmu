import Foundation
import SupersEmuKit
import XCTest

private actor CandidateStartRecorder {
    private(set) var started: [URL] = []

    func record(_ url: URL) {
        started.append(url)
    }
}

final class CandidateRacerTests: XCTestCase {
    private static let primary = URL(string: "https://primary.example")!
    private static let other = URL(string: "https://other.example")!

    func testFastPrimaryWins() async {
        let primary = Self.primary
        let other = Self.other
        let clock = ManualClock()
        let recorder = CandidateStartRecorder()
        let result = await CandidateRacer.race(primary: primary, others: [other], headStart: .milliseconds(80), clock: clock) { url -> CandidateAttempt<String> in
            await recorder.record(url)
            return url == primary ? .success(url.absoluteString) : .failure(.unreachable)
        }
        XCTAssertEqual(result.successURL, primary)
        XCTAssertEqual(result.successValue, primary.absoluteString)
        let started = await recorder.started
        XCTAssertEqual(started, [primary])
    }

    func testFastPrimarySuccessCancelsHeadStart() async {
        let primary = Self.primary
        let other = Self.other
        let clock = ManualClock()
        let result = await CandidateRacer.race(primary: primary, others: [other], headStart: .seconds(2), clock: clock) { url -> CandidateAttempt<String> in
            url == primary ? .success(url.absoluteString) : .failure(.unreachable)
        }
        // The clock never moved, so the race only returned because the head-start timer was cancelled.
        XCTAssertEqual(result.successURL, primary)
        XCTAssertEqual(clock.pendingSleepers, 0)
        XCTAssertEqual(clock.now.offset, .zero)
    }

    func testPrimarySignedOutCancelsHeadStart() async {
        let primary = Self.primary
        let other = Self.other
        let clock = ManualClock()
        let recorder = CandidateStartRecorder()
        let result = await CandidateRacer.race(primary: primary, others: [other], headStart: .seconds(2), clock: clock) { url -> CandidateAttempt<String> in
            await recorder.record(url)
            return url == primary ? .failure(.signedOut) : .failure(.unreachable)
        }
        XCTAssertEqual(result.failure, .signedOut)
        XCTAssertEqual(clock.pendingSleepers, 0)
        let started = await recorder.started
        XCTAssertEqual(started, [primary])
    }

    func testFastOtherWinsAfterHeadStart() async {
        let primary = Self.primary
        let other = Self.other
        let clock = ManualClock()
        let recorder = CandidateStartRecorder()
        let race = Task {
            await CandidateRacer.race(primary: primary, others: [other], headStart: .milliseconds(30), clock: clock) { url -> CandidateAttempt<String> in
                await recorder.record(url)
                if url == primary {
                    try? await clock.sleep(for: .seconds(10))
                }
                return .success(url.absoluteString)
            }
        }

        // Primary attempt and head-start timer are both waiting on the clock.
        await clock.waitForSleepers(2)
        var started = await recorder.started
        XCTAssertEqual(started, [primary])

        clock.advance(by: .milliseconds(29))
        XCTAssertEqual(clock.pendingSleepers, 2)

        clock.advance(by: .milliseconds(1))
        let result = await race.value
        XCTAssertEqual(result.successURL, other)
        XCTAssertEqual(result.successValue, other.absoluteString)
        started = await recorder.started
        XCTAssertEqual(started, [primary, other])
    }

    func testPrimaryFailureStartsOthersImmediately() async {
        let primary = Self.primary
        let other = Self.other
        let clock = ManualClock()
        let recorder = CandidateStartRecorder()
        let result = await CandidateRacer.race(primary: primary, others: [other], headStart: .milliseconds(500), clock: clock) { url -> CandidateAttempt<String> in
            await recorder.record(url)
            if url == primary { return .failure(.unreachable) }
            return .success(url.absoluteString)
        }
        // The clock never moved, so the other candidate started because the primary failed, not because the head start ran out.
        XCTAssertEqual(result.successURL, other)
        XCTAssertEqual(result.successValue, other.absoluteString)
        XCTAssertEqual(clock.now.offset, .zero)
        let started = await recorder.started
        XCTAssertEqual(started, [primary, other])
    }

    func testPrimaryCertificateMismatchStartsOthersImmediately() async {
        let primary = Self.primary
        let other = Self.other
        let clock = ManualClock()
        let result = await CandidateRacer.race(primary: primary, others: [other], headStart: .seconds(5), clock: clock) { url -> CandidateAttempt<String> in
            url == primary ? .failure(.certificateMismatch) : .success(url.absoluteString)
        }
        XCTAssertEqual(result.successURL, other)
        XCTAssertEqual(clock.now.offset, .zero)
    }

    func testSignedOutAbortsPendingCandidates() async {
        let primary = Self.primary
        let other = Self.other
        let clock = ManualClock()
        let recorder = CandidateStartRecorder()
        let (otherStarted, otherStartedContinuation) = AsyncStream<Void>.makeStream()
        let result = await CandidateRacer.race(primary: primary, others: [other], headStart: .zero, clock: clock) { url -> CandidateAttempt<String> in
            if url == primary {
                for await _ in otherStarted { break }
                return .failure(.signedOut)
            }
            await recorder.record(url)
            otherStartedContinuation.yield()
            try? await clock.sleep(for: .seconds(5))
            return .success(url.absoluteString)
        }
        // The other attempt was still sleeping when the primary signed out; the race only returned because it was cancelled.
        XCTAssertEqual(result.failure, .signedOut)
        XCTAssertEqual(clock.pendingSleepers, 0)
        let started = await recorder.started
        XCTAssertEqual(started, [other])
    }

    func testCertificateMismatchOnlyWinsWhenNothingSucceeds() async {
        let primary = Self.primary
        let other = Self.other
        let clock = ManualClock()
        let mismatch = await CandidateRacer.race(primary: primary, others: [other], headStart: .zero, clock: clock) { url -> CandidateAttempt<String> in
            url == primary ? .failure(.certificateMismatch) : .failure(.unreachable)
        }
        XCTAssertEqual(mismatch.failure, .certificateMismatch)

        let otherMismatch = await CandidateRacer.race(primary: primary, others: [other], headStart: .zero, clock: clock) { url -> CandidateAttempt<String> in
            url == primary ? .failure(.unreachable) : .failure(.certificateMismatch)
        }
        XCTAssertEqual(otherMismatch.failure, .certificateMismatch)

        let unreachable = await CandidateRacer.race(primary: primary, others: [other], headStart: .zero, clock: clock) { _ -> CandidateAttempt<String> in
            .failure(.unreachable)
        }
        XCTAssertEqual(unreachable.failure, .unreachable)

        let success = await CandidateRacer.race(primary: primary, others: [other], headStart: .zero, clock: clock) { url -> CandidateAttempt<String> in
            url == primary ? .failure(.certificateMismatch) : .success("ok")
        }
        XCTAssertEqual(success.successURL, other)
        XCTAssertEqual(success.successValue, "ok")
    }

    func testNilPrimaryStartsAllAndDeduplicatesURLs() async {
        let other = Self.other
        let clock = ManualClock()
        let recorder = CandidateStartRecorder()
        let result = await CandidateRacer.race(primary: nil, others: [other, other], headStart: .seconds(5), clock: clock) { url -> CandidateAttempt<String> in
            await recorder.record(url)
            return .success(url.absoluteString)
        }
        XCTAssertEqual(result.successURL, other)
        XCTAssertEqual(result.successValue, other.absoluteString)
        XCTAssertEqual(clock.now.offset, .zero)
        let started = await recorder.started
        XCTAssertEqual(started, [other])
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
