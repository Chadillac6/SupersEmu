import Foundation

public enum CandidateAttempt<Value: Sendable>: Sendable {
    case success(Value)
    case failure(ConnectionFailure)
}

public enum CandidateRaceResult<Value: Sendable>: Sendable {
    case success(URL, Value)
    case failure(ConnectionFailure)
}

private enum CandidateRaceEvent<Value: Sendable>: Sendable {
    case attempt(URL, CandidateAttempt<Value>)
    case startOthers
}

public enum CandidateRacer {
    public static func race<Value: Sendable>(
        primary: URL?,
        others: [URL],
        headStart: Duration = .milliseconds(1500),
        clock: some Clock<Duration> = ContinuousClock(),
        attempt: @escaping @Sendable (URL) async -> CandidateAttempt<Value>
    ) async -> CandidateRaceResult<Value> {
        var candidates: [URL] = []
        for url in others where url != primary && !candidates.contains(url) {
            candidates.append(url)
        }

        return await withTaskGroup(of: CandidateRaceEvent<Value>.self) { group in
            var startedOthers = false
            var sawCertificateMismatch = false

            func startOthers() {
                guard !startedOthers else { return }
                startedOthers = true
                for url in candidates {
                    group.addTask { .attempt(url, await attempt(url)) }
                }
            }

            if let primary {
                group.addTask { .attempt(primary, await attempt(primary)) }
                if !candidates.isEmpty {
                    group.addTask {
                        try? await clock.sleep(for: headStart)
                        return .startOthers
                    }
                }
            } else {
                startOthers()
            }

            for await event in group {
                switch event {
                case .startOthers:
                    startOthers()
                case .attempt(let url, .success(let value)):
                    group.cancelAll()
                    return .success(url, value)
                case .attempt(_, .failure(.signedOut)):
                    group.cancelAll()
                    return .failure(.signedOut)
                case .attempt(let url, .failure(let reason)):
                    if reason == .certificateMismatch { sawCertificateMismatch = true }
                    if url == primary { startOthers() }
                }
            }

            return .failure(sawCertificateMismatch ? .certificateMismatch : .unreachable)
        }
    }
}
