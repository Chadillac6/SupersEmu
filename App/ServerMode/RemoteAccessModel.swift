#if os(macOS)
import Foundation
import Observation
import SupersEmuKit

/// One step of turning on remote access, in the order the work happens: Caddy can only get a certificate
/// once the hostname resolves to this Mac.
enum RemoteAccessStep: String, CaseIterable, Identifiable {
    case caddy, dns, certificate, reachable
    var id: String { rawValue }
    var title: String {
        switch self {
        case .caddy: return "Caddy installed"
        case .dns: return "DNS points at this Mac"
        case .certificate: return "HTTPS certificate issued"
        case .reachable: return "Reachable from the internet"
        }
    }
}

enum RemoteAccessStepState: Equatable { case pending, running, done, failed }

/// Problems with one clear fix each.
enum RemoteAccessProblem: Equatable {
    case caddyMissing(homebrewInstalled: Bool)
    case portUnreachable
    case sharedIP
    case tokenRejected
    case other(String)

    var title: String {
        switch self {
        case .caddyMissing: return "Caddy isn't installed"
        case .portUnreachable: return "Port 443 isn't reachable from the internet"
        case .sharedIP: return "Your internet provider shares your IP (CGNAT)"
        case .tokenRejected: return "Cloudflare token was rejected"
        case .other(let message): return message
        }
    }

    var fix: String {
        switch self {
        case .caddyMissing(let homebrewInstalled):
            return homebrewInstalled
                ? "SupersEmu uses Caddy to serve HTTPS. Install it with Homebrew, then turn Remote Access on again."
                : "SupersEmu uses Caddy to serve HTTPS, and installs it with Homebrew. Install Homebrew first."
        case .portUnreachable:
            return "Forward TCP ports 443 and 80 to this Mac: in the Eero app, go to Settings › Network settings › Reservations & port forwarding."
        case .sharedIP: return "Port forwarding can't work on a shared IP. Ask your provider for a public IP address."
        case .tokenRejected: return "Create a new token from the \"Edit zone DNS\" template, limited to the supersemu.com zone, and paste it below."
        case .other: return "Try again. If it keeps failing, check the server log."
        }
    }
}

struct RemoteAccessStatus: Equatable {
    typealias OutsideCheck = RemoteAccessChecks.OutsideCheck

    var publicIP: String?
    var dnsUpdatedAt: Date?
    var certificateValidUntil: Date?
    var lastOutsideCheckAt: Date?
    var lastOutsideCheck: OutsideCheck?
}

enum RemoteAccessPhase: Equatable {
    case off
    case turningOn([RemoteAccessStep: RemoteAccessStepState])
    case on(RemoteAccessStatus)
    case error(RemoteAccessProblem, steps: [RemoteAccessStep: RemoteAccessStepState]?)
}

/// What the panel drives. Phase 1 ships a preview backend; the real one runs `public-access.sh` behind one
/// administrator prompt and reads `public-access.json`, `ddns-state.json` and Caddy's certificate.
/// The Cloudflare token is written to the server's data folder (mode 600) and is never read back into the app.
@MainActor
protocol RemoteAccessBackend: AnyObject {
    var tokenSaved: Bool { get }
    func currentPhase(host: String) async -> RemoteAccessPhase
    func turnOn(host: String, pastedToken: String?, progress: @escaping @MainActor (RemoteAccessPhase) -> Void) async -> RemoteAccessPhase
    func turnOff() async -> RemoteAccessPhase
    func checkNow(host: String) async -> RemoteAccessPhase
    func installCaddy() async -> RemoteAccessPhase
}

@MainActor @Observable
final class RemoteAccessModel {
    static let shared = RemoteAccessModel()
    static let defaultHost = "games.supersemu.com"
    static let homebrewURL = URL(string: "https://brew.sh")!
    static let cloudflareTokensURL = URL(string: "https://dash.cloudflare.com/profile/api-tokens")!

    var host = RemoteAccessModel.defaultHost
    var pastedToken = ""
    /// The user chose Replace on a saved token, so the paste field is shown again.
    var replacingToken = false
    private(set) var phase: RemoteAccessPhase = .off
    private(set) var busy = false
    private let backend: RemoteAccessBackend

    init(backend: RemoteAccessBackend? = nil) {
#if DEBUG
        if backend == nil, PreviewRemoteAccessBackend.debugState != nil {
            self.backend = PreviewRemoteAccessBackend.fromEnvironment()
        } else {
            self.backend = backend ?? LiveRemoteAccessBackend()
        }
#else
        self.backend = backend ?? LiveRemoteAccessBackend()
#endif
        if let preview = self.backend as? PreviewRemoteAccessBackend { phase = preview.phase }
    }

    var tokenSaved: Bool { backend.tokenSaved }
    var needsTokenEntry: Bool {
        if case .error(.tokenRejected, _) = phase { return true }
        return !tokenSaved || replacingToken
    }
    var hasPastedToken: Bool { !pastedToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    var isOn: Bool { if case .on = phase { return true } else { return false } }
    var isTurningOn: Bool { if case .turningOn = phase { return true } else { return false } }
    var canTurnOn: Bool {
        !busy && !host.trimmingCharacters(in: .whitespaces).isEmpty
            && (!needsTokenEntry || hasPastedToken)
    }
    var publicURLText: String { "https://\(host)" }
    var summary: String { isOn ? "On" : isTurningOn ? "Turning on…" : { if case .error = phase { return "Needs attention" }; return "Off" }() }

    func attach(serverMode: ServerModeModel) {
        (backend as? LiveRemoteAccessBackend)?.attach(serverMode: serverMode)
    }

    func refresh() async { phase = await backend.currentPhase(host: host) }

    func turnOn() async {
        guard canTurnOn else { return }
        busy = true
        defer { busy = false }
        let token = pastedToken.trimmingCharacters(in: .whitespacesAndNewlines)
        phase = await backend.turnOn(host: host, pastedToken: token.isEmpty ? nil : token) { [weak self] in self?.phase = $0 }
        pastedToken = ""
        replacingToken = false
    }

    func turnOff() async { await run { await $0.turnOff() } }
    func checkNow() async { await run { [host] in await $0.checkNow(host: host) } }
    func installCaddy() async { await run { await $0.installCaddy() } }

    private func run(_ action: (RemoteAccessBackend) async -> RemoteAccessPhase) async {
        busy = true
        defer { busy = false }
        phase = await action(backend)
    }
}

/// Canned states for Debug-build screenshots:
/// `SUPERSEMU_DEBUG_REMOTE_STATE=off|off-saved|progress|on|error-caddy|error-caddy-nobrew|error-port|error-cgnat|error-token`.
/// `off` has no token yet; `off-saved` has one saved from an earlier attempt.
@MainActor
final class PreviewRemoteAccessBackend: RemoteAccessBackend {
    static var debugState: String? {
        #if DEBUG
        ProcessInfo.processInfo.environment["SUPERSEMU_DEBUG_REMOTE_STATE"]
        #else
        nil
        #endif
    }

    private(set) var tokenSaved: Bool
    private(set) var phase: RemoteAccessPhase

    init(tokenSaved: Bool, phase: RemoteAccessPhase) {
        self.tokenSaved = tokenSaved
        self.phase = phase
    }

    static func fromEnvironment() -> PreviewRemoteAccessBackend {
        let now = Date()
        let onStatus = RemoteAccessStatus(
            publicIP: "107.214.48.51",
            dnsUpdatedAt: now.addingTimeInterval(-4 * 60),
            certificateValidUntil: now.addingTimeInterval(86 * 24 * 3600),
            lastOutsideCheckAt: now.addingTimeInterval(-40),
            lastOutsideCheck: .reachable)
        switch debugState {
        case "off-saved": return .init(tokenSaved: true, phase: .off)
        case "progress":
            return .init(tokenSaved: true, phase: .turningOn([.caddy: .done, .dns: .done, .certificate: .running, .reachable: .pending]))
        case "on": return .init(tokenSaved: true, phase: .on(onStatus))
        case "error-caddy": return .init(tokenSaved: true, phase: .error(.caddyMissing(homebrewInstalled: true), steps: nil))
        case "error-caddy-nobrew": return .init(tokenSaved: true, phase: .error(.caddyMissing(homebrewInstalled: false), steps: nil))
        case "error-port":
            return .init(tokenSaved: true, phase: .error(.portUnreachable, steps: [.caddy: .done, .dns: .done, .certificate: .failed, .reachable: .pending]))
        case "error-cgnat":
            return .init(tokenSaved: true, phase: .error(.sharedIP, steps: [.caddy: .done, .dns: .done, .certificate: .failed, .reachable: .pending]))
        case "error-token":
            return .init(tokenSaved: true, phase: .error(.tokenRejected, steps: [.caddy: .done, .dns: .failed, .certificate: .pending, .reachable: .pending]))
        default: return .init(tokenSaved: false, phase: .off)
        }
    }

    func currentPhase(host: String) async -> RemoteAccessPhase { phase }

    func turnOn(host: String, pastedToken: String?, progress: @escaping @MainActor (RemoteAccessPhase) -> Void) async -> RemoteAccessPhase {
        if pastedToken != nil { tokenSaved = true }
        var steps = Dictionary(uniqueKeysWithValues: RemoteAccessStep.allCases.map { ($0, RemoteAccessStepState.pending) })
        for step in RemoteAccessStep.allCases {
            steps[step] = .running
            progress(.turningOn(steps))
            try? await Task.sleep(for: .milliseconds(700))
            steps[step] = .done
        }
        phase = .on(RemoteAccessStatus(publicIP: "107.214.48.51", dnsUpdatedAt: Date(),
                                       certificateValidUntil: Date().addingTimeInterval(90 * 24 * 3600),
                                       lastOutsideCheckAt: Date(), lastOutsideCheck: .reachable))
        return phase
    }

    func turnOff() async -> RemoteAccessPhase { phase = .off; return phase }

    func checkNow(host: String) async -> RemoteAccessPhase {
        guard case .on(var status) = phase else { return phase }
        try? await Task.sleep(for: .milliseconds(500))
        status.lastOutsideCheckAt = Date()
        phase = .on(status)
        return phase
    }

    func installCaddy() async -> RemoteAccessPhase {
        try? await Task.sleep(for: .milliseconds(500))
        phase = .off
        return phase
    }
}
#endif
