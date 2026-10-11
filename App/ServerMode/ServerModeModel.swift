#if os(macOS)
import AppKit
import Foundation
import Observation
import ServiceManagement
import SupersEmuKit

/// Server mode on the Mac mini: registers the boot-time launch daemon, or runs the embedded server for this
/// session, and talks to it as the local admin (token file + pinned certificate from the data directory).
@MainActor @Observable
final class ServerModeModel {
    enum Source: String, CaseIterable, Identifiable {
        case daemon, session, paired
        var id: String { rawValue }
        var title: String {
            switch self {
            case .daemon: return "Boot daemon"
            case .session: return "This session"
            case .paired: return "Paired server"
            }
        }
    }

    static let daemonPlistName = "com.chadillac6.supersemu.server.plist"
    static let daemonPort = 8487
    static let sessionPort = 8488

    var source: Source
    private(set) var daemonStatus: SMAppService.Status
    private(set) var sessionRunning = false
    private(set) var health: HealthResponse?
    private(set) var statusError: String?
    private(set) var pairing: PairingCode?
    private(set) var pairingError: String?
    private(set) var devices: [DeviceInfo] = []
    private(set) var devicesError: String?
    private(set) var message: String?
    private(set) var busy = false

    private var process: Process? {
        get { SessionServerProcess.shared.process }
        set { SessionServerProcess.shared.process = newValue }
    }
    private let daemon = SMAppService.daemon(plistName: ServerModeModel.daemonPlistName)

    /// The server this Mac is paired with as a player, managed remotely when it's an admin device.
    let pairedCredential = ServerSession.defaultStore().load()
    var sources: [Source] { pairedCredential == nil ? [.daemon, .session] : Source.allCases }
    var isLocal: Bool { source != .paired }

    init() {
        let status = daemon.status
        daemonStatus = status
        source = status == .enabled ? .daemon : .session
    }

    var dataDirectory: URL {
        switch source {
        case .daemon:
            return URL(fileURLWithPath: "/Library/Application Support/SupersEmu Server", isDirectory: true)
        case .session, .paired:
            return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("SupersEmu Server", isDirectory: true)
        }
    }

    var port: Int { source == .daemon ? Self.daemonPort : Self.sessionPort }
    var localURL: URL { URL(string: "https://127.0.0.1:\(port)")! }
    private(set) var pairedURL: URL?
    var serverURL: URL { isLocal ? localURL : pairedURL ?? pairedCredential?.urls.first ?? localURL }

    /// Paired servers have LAN and Tailscale addresses; keep using whichever answered last.
    func resolvePairedURL() async {
        guard !isLocal, (try? await client(authenticated: false).health()) == nil else { return }
        for url in pairedCredential?.urls ?? [] where url != serverURL {
            let candidate = APIClient(baseURL: url, token: nil,
                                      session: PinnedCertificateDelegate.session(certificateSHA256: certificateSHA256, timeout: 4))
            if (try? await candidate.health()) != nil { pairedURL = url; return }
        }
    }
    static var daemonPlistEmbedded: Bool {
        FileManager.default.fileExists(atPath: Bundle.main.bundleURL
            .appendingPathComponent("Contents/Library/LaunchDaemons/\(daemonPlistName)").path)
    }

    var serverBinary: URL? { Bundle.main.url(forAuxiliaryExecutable: "supersemu-server") }

    var certificateSHA256: String? {
        if !isLocal { return pairedCredential?.certificateSHA256 }
        return FileManager.default.contents(atPath: dataDirectory.appendingPathComponent("tls/server.cer").path).map(CertificatePin.sha256(ofDER:))
    }

    var daemonStatusText: String {
        switch daemonStatus {
        case .notRegistered: return "Not registered"
        case .enabled: return "Enabled (starts at boot)"
        case .requiresApproval: return "Waiting for approval in System Settings › Login Items"
        case .notFound:
            // SMAppService reports .notFound for a daemon that was never registered.
            return Self.daemonPlistEmbedded ? "Not registered" : "Not found in app bundle"
        @unknown default: return "Unknown"
        }
    }

    func adminClient(timeout: TimeInterval = 15) throws -> APIClient { try client(authenticated: true, timeout: timeout) }

    private func client(authenticated: Bool, timeout: TimeInterval = 4) throws -> APIClient {
        var token: String?
        if !isLocal {
            guard let pairedCredential else { throw ServerModeError("This Mac isn't paired with a server.") }
            token = authenticated ? pairedCredential.token : nil
        } else if authenticated {
            let tokenURL = dataDirectory.appendingPathComponent("admin.token")
            guard let data = FileManager.default.contents(atPath: tokenURL.path) else {
                throw ServerModeError("Can't read \(tokenURL.path). Start the server first (it bootstraps the admin token).")
            }
            token = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return APIClient(baseURL: serverURL, token: token,
                         session: PinnedCertificateDelegate.session(certificateSHA256: certificateSHA256, timeout: timeout))
    }

    func refresh() async {
        daemonStatus = daemon.status
        sessionRunning = process?.isRunning == true
        await resolvePairedURL()
        do {
            health = try await client(authenticated: false).health()
            statusError = nil
        } catch {
            health = nil
            statusError = "Not responding on \(serverURL.absoluteString)"
        }
        guard health != nil else { devices = []; devicesError = nil; return }
        do {
            devices = try await client(authenticated: true).devices()
            devicesError = nil
        } catch APIClientError.http(status: 404, _) {
            devicesError = "This server doesn't provide the device list (/v1/admin/devices) yet."
        } catch {
            devicesError = "Couldn't load devices: \(error)"
        }
    }

    // MARK: Boot daemon

    func registerDaemon() async {
        do {
            try daemon.register()
            UserDefaults.standard.set(true, forKey: ServerStatusMonitor.showIconDefaultsKey)
            message = "Daemon registered."
        } catch {
            message = "Register failed: \(error.localizedDescription)"
        }
        source = .daemon
        await refresh()
        if daemonStatus == .requiresApproval { SMAppService.openSystemSettingsLoginItems() }
    }

    func unregisterDaemon() async {
        do {
            try await daemon.unregister()
            message = "Daemon unregistered."
        } catch {
            message = "Unregister failed: \(error.localizedDescription)"
        }
        await refresh()
    }

    func openLoginItems() { SMAppService.openSystemSettingsLoginItems() }

    // MARK: Session server

    func startSession() async {
        guard process?.isRunning != true else { return }
        guard let binary = serverBinary else { message = "supersemu-server isn't embedded in this app build."; return }
        source = .session
        busy = true
        defer { busy = false }
        do {
            try FileManager.default.createDirectory(at: dataDirectory, withIntermediateDirectories: true)
            let logURL = dataDirectory.appendingPathComponent("server.log")
            FileManager.default.createFile(atPath: logURL.path, contents: nil)
            let log = try FileHandle(forWritingTo: logURL)
            let process = Process()
            process.executableURL = binary
            process.arguments = ["run", "--data-dir", dataDirectory.path, "--port", "\(Self.sessionPort)", "--bootstrap"]
            process.standardOutput = log
            process.standardError = log
            try process.run()
            self.process = process
            UserDefaults.standard.set(true, forKey: ServerStatusMonitor.showIconDefaultsKey)
            for _ in 0..<40 {
                try await Task.sleep(nanoseconds: 250_000_000)
                await refresh()
                if health != nil || !process.isRunning { break }
            }
            message = health != nil ? "Server running for this session." : "Server didn't start; see \(logURL.path)."
        } catch {
            message = "Couldn't start the server: \(error.localizedDescription)"
        }
    }

    func stopSession() async {
        process?.terminate()
        process?.waitUntilExit()
        process = nil
        message = "Session server stopped."
        await refresh()
    }

    // MARK: Pairing

    func createPairingCode() async {
        do {
            pairing = try await client(authenticated: true).createPairingCode()
            pairingError = nil
        } catch {
            pairingError = "\(error)"
        }
    }
}

/// Owns the session server child process for the app's lifetime, so closing and reopening the Server mode
/// window keeps control of it, and quitting the app stops it.
@MainActor
final class SessionServerProcess {
    static let shared = SessionServerProcess()
    var process: Process?

    private init() {
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated {
                SessionServerProcess.shared.process?.terminate()
                SessionServerProcess.shared.process?.waitUntilExit()
            }
        }
    }
}

struct ServerModeError: Error, CustomStringConvertible {
    var description: String
    init(_ description: String) { self.description = description }
}

/// Opens Server mode at launch with `--server-mode` or the "Open at launch" toggle.
@MainActor
enum ServerModeLaunch {
    static let defaultsKey = "openServerModeAtLaunch"
    private static var handled = false

    /// True once per launch when Server mode was requested.
    static func consumeRequest() -> Bool {
        guard !handled else { return false }
        handled = true
        return requested
    }

    static var requested: Bool {
        CommandLine.arguments.contains("--server-mode") || UserDefaults.standard.bool(forKey: defaultsKey)
    }
}
#endif
