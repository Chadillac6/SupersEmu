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
        case daemon, session
        var id: String { rawValue }
        var title: String { self == .daemon ? "Boot daemon" : "This session" }
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

    private var process: Process?
    private let daemon = SMAppService.daemon(plistName: ServerModeModel.daemonPlistName)

    init() {
        let status = daemon.status
        daemonStatus = status
        source = status == .enabled ? .daemon : .session
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.process?.terminate() }
        }
    }

    var dataDirectory: URL {
        switch source {
        case .daemon:
            return URL(fileURLWithPath: "/Library/Application Support/SupersEmu Server", isDirectory: true)
        case .session:
            return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("SupersEmu Server", isDirectory: true)
        }
    }

    var port: Int { source == .daemon ? Self.daemonPort : Self.sessionPort }
    var localURL: URL { URL(string: "https://127.0.0.1:\(port)")! }
    var serverBinary: URL? { Bundle.main.url(forAuxiliaryExecutable: "supersemu-server") }

    var certificateSHA256: String? {
        FileManager.default.contents(atPath: dataDirectory.appendingPathComponent("tls/server.cer").path).map(CertificatePin.sha256(ofDER:))
    }

    var daemonStatusText: String {
        switch daemonStatus {
        case .notRegistered: return "Not registered"
        case .enabled: return "Enabled (starts at boot)"
        case .requiresApproval: return "Waiting for approval in System Settings › Login Items"
        case .notFound: return "Not found in app bundle"
        @unknown default: return "Unknown"
        }
    }

    private func client(authenticated: Bool) throws -> APIClient {
        var token: String?
        if authenticated {
            let tokenURL = dataDirectory.appendingPathComponent("admin.token")
            guard let data = FileManager.default.contents(atPath: tokenURL.path) else {
                throw ServerModeError("Can't read \(tokenURL.path). Start the server first (it bootstraps the admin token).")
            }
            token = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return APIClient(baseURL: localURL, token: token,
                         session: PinnedCertificateDelegate.session(certificateSHA256: certificateSHA256, timeout: 4))
    }

    func refresh() async {
        daemonStatus = daemon.status
        sessionRunning = process?.isRunning == true
        do {
            health = try await client(authenticated: false).health()
            statusError = nil
        } catch {
            health = nil
            statusError = "Not responding on \(localURL.absoluteString)"
        }
        guard health != nil else { devices = []; devicesError = nil; return }
        do {
            devices = try await client(authenticated: true).devices()
            devicesError = nil
        } catch {
            devicesError = "Couldn't load devices: \(error)"
        }
    }

    // MARK: Boot daemon

    func registerDaemon() async {
        do {
            try daemon.register()
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

struct ServerModeError: Error, CustomStringConvertible {
    var description: String
    init(_ description: String) { self.description = description }
}

/// Opens Server mode at launch with `--server-mode` or the "Open at launch" toggle.
enum ServerModeLaunch {
    static let defaultsKey = "openServerModeAtLaunch"
    static var requested: Bool {
        CommandLine.arguments.contains("--server-mode") || UserDefaults.standard.bool(forKey: defaultsKey)
    }
}
#endif
