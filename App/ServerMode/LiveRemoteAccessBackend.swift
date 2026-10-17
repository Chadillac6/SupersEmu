#if os(macOS)
import Foundation
import SupersEmuKit

@MainActor
final class LiveRemoteAccessBackend: RemoteAccessBackend {
    private struct ProcessResult {
        var status: Int
        var stdout: String
        var stderr: String

        var lastMessage: String {
            (stderr + "\n" + stdout).split(whereSeparator: \.isNewline).last.map(String.init)
                ?? "Command failed (exit status \(status))."
        }
    }

    private weak var attachedServer: ServerModeModel?
    private var latestStatus: RemoteAccessStatusResponse?
    private var lastHost = RemoteAccessModel.defaultHost
    private let defaults = UserDefaults.standard

    private var server: ServerModeModel { attachedServer ?? ServerStatusMonitor.shared.model }
    var tokenSaved: Bool {
        latestStatus?.tokenSaved
            ?? FileManager.default.fileExists(atPath: server.dataDirectory.appendingPathComponent("cloudflare.token").path)
    }

    func attach(serverMode: ServerModeModel) {
        attachedServer = serverMode
    }

    func currentPhase(host: String) async -> RemoteAccessPhase {
        lastHost = host
        let server = server
        do {
            try await checkServerIsRunning(server)
        } catch {
            return .error(.other("Start the SupersEmu server to manage Remote Access"), steps: nil)
        }
        do {
            return phase(from: try await fetchStatus(server), host: host)
        } catch {
            return .error(.other(error.localizedDescription), steps: nil)
        }
    }

    func turnOn(host: String, pastedToken: String?, progress: @escaping @MainActor (RemoteAccessPhase) -> Void) async -> RemoteAccessPhase {
        lastHost = host
        let server = server
        guard server.isLocal else {
            return .error(.other("Select a local server to manage Remote Access"), steps: nil)
        }
        do {
            try await checkServerIsRunning(server)
        } catch {
            return .error(.other("Start the SupersEmu server to manage Remote Access"), steps: nil)
        }
        guard Self.findCaddy() != nil else {
            return .error(.caddyMissing(homebrewInstalled: Self.findBrew() != nil), steps: nil)
        }
        guard let script = Bundle.main.resourceURL?.appendingPathComponent("public-access.sh"),
              FileManager.default.isExecutableFile(atPath: script.path) else {
            return .error(.other("The bundled Remote Access helper is missing."), steps: nil)
        }

        var steps = Self.pendingSteps
        steps[.caddy] = .done
        steps[.dns] = .running
        progress(.turningOn(steps))

        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("supersemu-remote-access-\(UUID().uuidString)", isDirectory: true)
        var arguments = [script.path, "enable", "--host", host, "--data-dir", server.dataDirectory.path]
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }
        if let pastedToken, !pastedToken.isEmpty {
            do {
                try FileManager.default.createDirectory(
                    at: temporaryDirectory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
                let tokenFile = temporaryDirectory.appendingPathComponent("cloudflare.token")
                guard FileManager.default.createFile(
                    atPath: tokenFile.path, contents: Data(pastedToken.utf8), attributes: [.posixPermissions: 0o600])
                else { throw CocoaError(.fileWriteUnknown) }
                arguments += ["--cloudflare-token-file", tokenFile.path]
            } catch {
                return .error(.other("Couldn't prepare the Cloudflare token file: \(error.localizedDescription)"), steps: nil)
            }
        }
        let result = await Self.runAdministratorCommand(arguments)
        let exitStatus = RemoteAccessChecks.osascriptExitStatus(stderr: result.stderr) ?? result.status
        guard exitStatus == 0 else {
            if exitStatus == -128 { return .off }
            if exitStatus == 5 {
                return .error(.caddyMissing(homebrewInstalled: Self.findBrew() != nil), steps: nil)
            }
            if exitStatus == 3 {
                steps[.dns] = .failed
                return .error(.tokenRejected, steps: steps)
            }
            return .error(.other(result.lastMessage), steps: nil)
        }

        await restartSessionIfNeeded(server)
        let session = Self.ephemeralSession()
        defer { session.invalidateAndCancel() }
        guard let publicIP = await Self.publicIPv4(using: session) else {
            steps[.dns] = .failed
            return .error(.other("Couldn't determine this Mac's public IP address."), steps: steps)
        }

        let clock = ContinuousClock()
        let dnsDeadline = clock.now.advanced(by: .seconds(120))
        var dnsMatches = false
        while clock.now < dnsDeadline, !Task.isCancelled {
            let addresses = await Self.dohAAnswers(for: host, using: session)
            if addresses.contains(publicIP) {
                dnsMatches = true
                break
            }
            try? await Task.sleep(for: .seconds(5))
        }
        guard dnsMatches else {
            steps[.dns] = .failed
            return .error(.other("DNS hasn't updated yet. Try Check Now in a few minutes."), steps: steps)
        }
        steps[.dns] = .done
        steps[.certificate] = .running
        progress(.turningOn(steps))

        let certificateDeadline = clock.now.advanced(by: .seconds(90))
        var status: RemoteAccessStatusResponse?
        while clock.now < certificateDeadline, !Task.isCancelled {
            if let latest = try? await fetchStatus(server), latest.certificateValidUntil != nil {
                status = latest
                break
            }
            try? await Task.sleep(for: .seconds(3))
        }
        guard status != nil else {
            steps[.certificate] = .failed
            return .error(.portUnreachable, steps: steps)
        }
        steps[.certificate] = .done
        steps[.reachable] = .running
        progress(.turningOn(steps))

        let check = await outsideCheck(host: host, publicIP: publicIP, certificatePresent: true, using: session)
        let checkedAt = Date()
        saveOutsideCheck(check, at: checkedAt, host: host)
        if case .failed = check {
            steps[.reachable] = .failed
        } else {
            steps[.reachable] = .done
        }
        guard var response = try? await fetchStatus(server) else {
            return .error(.other("Remote Access was enabled, but its status couldn't be refreshed."), steps: steps)
        }
        response.certificateValidUntil = status?.certificateValidUntil
        latestStatus = response
        if case .failed = check {
            return .error(.portUnreachable, steps: steps)
        }
        return .on(makeStatus(response, outsideCheck: check, checkedAt: checkedAt))
    }

    func turnOff() async -> RemoteAccessPhase {
        let host = lastHost
        let server = server
        guard server.isLocal else {
            return .error(.other("Select a local server to manage Remote Access"), steps: nil)
        }
        do {
            try await checkServerIsRunning(server)
        } catch {
            return .error(.other("Start the SupersEmu server to manage Remote Access"), steps: nil)
        }
        guard let script = Bundle.main.resourceURL?.appendingPathComponent("public-access.sh"),
              FileManager.default.isExecutableFile(atPath: script.path) else {
            return .error(.other("The bundled Remote Access helper is missing."), steps: nil)
        }
        let result = await Self.runAdministratorCommand([script.path, "disable", "--data-dir", server.dataDirectory.path])
        let exitStatus = RemoteAccessChecks.osascriptExitStatus(stderr: result.stderr) ?? result.status
        guard exitStatus == 0 else {
            if exitStatus == -128 { return await currentPhase(host: host) }
            return .error(.other(result.lastMessage), steps: nil)
        }
        await restartSessionIfNeeded(server)
        latestStatus = try? await fetchStatus(server)
        return .off
    }

    func checkNow(host: String) async -> RemoteAccessPhase {
        lastHost = host
        let server = server
        guard let response = try? await fetchStatus(server), response.enabled else {
            return await currentPhase(host: host)
        }
        let session = Self.ephemeralSession()
        defer { session.invalidateAndCancel() }
        guard let publicIP = await Self.publicIPv4(using: session) ?? response.ddnsIP else {
            return .error(.other("Couldn't determine this Mac's public IP address."), steps: nil)
        }
        let check = await outsideCheck(
            host: host, publicIP: publicIP, certificatePresent: response.certificateValidUntil != nil, using: session)
        let checkedAt = Date()
        saveOutsideCheck(check, at: checkedAt, host: host)
        latestStatus = response
        return .on(makeStatus(response, outsideCheck: check, checkedAt: checkedAt))
    }

    func installCaddy() async -> RemoteAccessPhase {
        guard let brew = Self.findBrew() else {
            return .error(.caddyMissing(homebrewInstalled: false), steps: nil)
        }
        let result = await Self.runProcess(executableURL: brew, arguments: ["install", "caddy"], captureStderr: false)
        guard result.status == 0 else { return .error(.other(result.lastMessage), steps: nil) }
        return await currentPhase(host: lastHost)
    }

    private func phase(from response: RemoteAccessStatusResponse, host: String) -> RemoteAccessPhase {
        latestStatus = response
        guard response.enabled else { return .off }
        let (checkedAt, check) = loadOutsideCheck(host: host)
        return .on(makeStatus(response, outsideCheck: check, checkedAt: checkedAt))
    }

    private func makeStatus(
        _ response: RemoteAccessStatusResponse,
        outsideCheck: RemoteAccessChecks.OutsideCheck?,
        checkedAt: Date?
    ) -> RemoteAccessStatus {
        RemoteAccessStatus(
            publicIP: response.ddnsIP,
            dnsUpdatedAt: response.ddnsUpdatedAt,
            certificateValidUntil: response.certificateValidUntil,
            lastOutsideCheckAt: checkedAt,
            lastOutsideCheck: outsideCheck)
    }

    private func checkServerIsRunning(_ server: ServerModeModel) async throws {
        guard server.isLocal else { throw ServerModeError("Remote Access is available for a local server only.") }
        let client = APIClient(
            baseURL: server.serverURL, token: nil,
            session: PinnedCertificateDelegate.session(certificateSHA256: server.certificateSHA256, timeout: 4))
        _ = try await client.health()
    }

    private func fetchStatus(_ server: ServerModeModel) async throws -> RemoteAccessStatusResponse {
        let response = try await server.adminClient(timeout: 4).remoteAccessStatus()
        latestStatus = response
        return response
    }

    private func restartSessionIfNeeded(_ server: ServerModeModel) async {
        guard server.source == .session, server.sessionRunning else { return }
        await server.stopSession()
        await server.startSession()
    }

    private func outsideCheck(
        host: String,
        publicIP: String,
        certificatePresent: Bool,
        using session: URLSession
    ) async -> RemoteAccessChecks.OutsideCheck {
        async let healthOK = Self.publicHealthIsAvailable(host: host, using: session)
        async let dnsAddresses = Self.dohAAnswers(for: host, using: session)
        let (healthy, addresses) = await (healthOK, dnsAddresses)
        return RemoteAccessChecks.classifyOutsideCheck(
            healthOK: healthy, dnsAddresses: addresses, publicIP: publicIP, certificatePresent: certificatePresent)
    }

    private func saveOutsideCheck(_ check: RemoteAccessChecks.OutsideCheck, at date: Date, host: String) {
        let values: [String: Any]
        switch check {
        case .reachable:
            values = ["kind": "reachable", "date": date]
        case .unverifiedFromInside:
            values = ["kind": "unverifiedFromInside", "date": date]
        case .failed(let reason):
            values = ["kind": "failed", "date": date, "reason": reason]
        }
        defaults.set(values, forKey: Self.outsideCheckKey(host))
    }

    private func loadOutsideCheck(host: String) -> (Date?, RemoteAccessChecks.OutsideCheck?) {
        guard let values = defaults.dictionary(forKey: Self.outsideCheckKey(host)),
              let kind = values["kind"] as? String else { return (nil, nil) }
        let date = values["date"] as? Date
        switch kind {
        case "reachable": return (date, .reachable)
        case "unverifiedFromInside": return (date, .unverifiedFromInside)
        case "failed": return (date, .failed(values["reason"] as? String ?? "Couldn't verify the connection."))
        default: return (date, nil)
        }
    }

    private static let pendingSteps: [RemoteAccessStep: RemoteAccessStepState] =
        Dictionary(uniqueKeysWithValues: RemoteAccessStep.allCases.map { ($0, .pending) })

    private static func outsideCheckKey(_ host: String) -> String { "remoteAccess.outsideCheck.\(host)" }

    private static func ephemeralSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 8
        return URLSession(configuration: configuration)
    }

    private static func findCaddy() -> URL? {
        let pathCandidates = (ProcessInfo.processInfo.environment["PATH"] ?? "")
            .split(separator: ":").map { URL(fileURLWithPath: String($0), isDirectory: true).appendingPathComponent("caddy") }
        return (pathCandidates + [
            URL(fileURLWithPath: "/opt/homebrew/bin/caddy"),
            URL(fileURLWithPath: "/usr/local/bin/caddy")
        ]).first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    private static func findBrew() -> URL? {
        [
            URL(fileURLWithPath: "/opt/homebrew/bin/brew"),
            URL(fileURLWithPath: "/usr/local/bin/brew")
        ].first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    private static func publicIPv4(using session: URLSession) async -> String? {
        for endpoint in ["https://api.ipify.org", "https://checkip.amazonaws.com"] {
            guard let url = URL(string: endpoint) else { continue }
            do {
                let (data, response) = try await session.data(from: url)
                guard (response as? HTTPURLResponse)?.statusCode == 200,
                      let address = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
                      RemoteAccessChecks.isIPv4Address(address) else { continue }
                return address
            } catch {
                continue
            }
        }
        return nil
    }

    private static func dohAAnswers(for host: String, using session: URLSession) async -> [String] {
        var components = URLComponents(string: "https://cloudflare-dns.com/dns-query")
        components?.queryItems = [URLQueryItem(name: "name", value: host), URLQueryItem(name: "type", value: "A")]
        guard let url = components?.url else { return [] }
        var request = URLRequest(url: url)
        request.setValue("application/dns-json", forHTTPHeaderField: "accept")
        do {
            let (data, response) = try await session.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { return [] }
            return RemoteAccessChecks.dohAAnswers(from: data)
        } catch {
            return []
        }
    }

    private static func publicHealthIsAvailable(host: String, using session: URLSession) async -> Bool {
        var components = URLComponents()
        components.scheme = "https"
        components.host = host
        components.path = "/v1/health"
        guard let url = components.url else { return false }
        var request = URLRequest(url: url)
        request.timeoutInterval = 8
        do {
            let (_, response) = try await session.data(for: request)
            guard let response = response as? HTTPURLResponse else { return false }
            return (200..<300).contains(response.statusCode)
        } catch {
            return false
        }
    }

    private static func runAdministratorCommand(_ arguments: [String]) async -> ProcessResult {
        let command = arguments.map(shellQuote).joined(separator: " ")
        let appleScript = "do shell script \"\(appleScriptQuote(command))\" with administrator privileges"
        return await runProcess(
            executableURL: URL(fileURLWithPath: "/usr/bin/osascript"), arguments: ["-e", appleScript])
    }

    private static func runProcess(
        executableURL: URL,
        arguments: [String],
        captureStderr: Bool = true
    ) async -> ProcessResult {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                let stderrPipe = captureStderr ? Pipe() : nil
                process.executableURL = executableURL
                process.arguments = arguments
                process.standardOutput = FileHandle.nullDevice
                process.standardError = stderrPipe?.fileHandleForWriting ?? FileHandle.nullDevice
                do {
                    try process.run()
                    process.waitUntilExit()
                    stderrPipe?.fileHandleForWriting.closeFile()
                    let errorText = stderrPipe.flatMap {
                        String(data: $0.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)
                    } ?? ""
                    continuation.resume(returning: ProcessResult(status: Int(process.terminationStatus), stdout: "", stderr: errorText))
                } catch {
                    continuation.resume(returning: ProcessResult(status: -1, stdout: "", stderr: error.localizedDescription))
                }
            }
        }
    }

    private static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private static func appleScriptQuote(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
    }
}
#endif
