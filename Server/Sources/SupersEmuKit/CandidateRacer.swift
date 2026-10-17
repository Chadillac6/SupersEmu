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
        attempt: @escaping @Sendable (URL) async -> CandidateAttempt<Value>
    ) async -> CandidateRaceResult<Value> {
        var candidates: [URL] = []
        for url in others where url != primary && !candidates.contains(url) {
            candidates.append(url)
        }

        return await withTaskGroup(of: CandidateRaceEvent<Value>.self) { group in
            var startedOthers = false
            var sawCertificateMismatch = false

            if let primary {
                group.addTask { .attempt(primary, await attempt(primary)) }
                if !candidates.isEmpty {
                    group.addTask {
                        try? await Task.sleep(for: headStart)
                        return .startOthers
                    }
                }
            } else {
                startedOthers = true
                for url in candidates {
                    group.addTask { .attempt(url, await attempt(url)) }
                }
            }

            for await event in group {
                switch event {
                case .startOthers:
                    guard !startedOthers else { continue }
                    startedOthers = true
                    for url in candidates {
                        group.addTask { .attempt(url, await attempt(url)) }
                    }
                case .attempt(let url, .success(let value)):
                    group.cancelAll()
                    return .success(url, value)
                case .attempt(_, .failure(.signedOut)):
                    group.cancelAll()
                    return .failure(.signedOut)
                case .attempt(let url, .failure(.certificateMismatch)):
                    sawCertificateMismatch = true
                    if url == primary, !startedOthers {
                        startedOthers = true
                        for candidate in candidates {
                            group.addTask { .attempt(candidate, await attempt(candidate)) }
                        }
                    }
                case .attempt(let url, .failure(.unreachable)):
                    if url == primary, !startedOthers {
                        startedOthers = true
                        for candidate in candidates {
                            group.addTask { .attempt(candidate, await attempt(candidate)) }
                        }
                    }
                }
            }

            return .failure(sawCertificateMismatch ? .certificateMismatch : .unreachable)
        }
    }
}
