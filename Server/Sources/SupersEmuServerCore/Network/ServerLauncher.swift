import Foundation
import Hummingbird
import HummingbirdCore
import HummingbirdTLS
import Logging
import NIOCore
import SupersEmuKit

/// Options for `supersemu-server run`.
public struct ServerRunOptions: Sendable {
    public var hostname = "0.0.0.0"
    public var port = ServerDefaults.port
    /// Plain HTTP, for tests and local debugging only. Pairing payloads then carry no certificate pin.
    public var insecureHTTP = false
    /// Overrides the URLs put into pairing QR codes (otherwise LAN + Tailscale are detected).
    public var advertiseURLs: [URL] = []
    /// Tailscale MagicDNS name, e.g. `mac-mini.tail1234.ts.net`, added after the LAN URLs.
    public var tailscaleHost: String?
    public var bonjour = true
    /// Background libretro-database matching and thumbnail downloads after imports.
    public var metadata = true

    public init() {}
}

public enum ServerLauncher {
    /// Builds the HTTPS (or `--insecure-http`) application and the pairing environment it advertises.
    public static func makeApplication(store: ServerStore, options: ServerRunOptions,
                                       onServerRunning: @escaping @Sendable (any Channel) async -> Void = { _ in }) throws
        -> (application: some ApplicationProtocol, environment: PairingEnvironment) {
        let scheme = options.insecureHTTP ? "http" : "https"
        var server: HTTPServerBuilder = .http1()
        var pin: String?
        if !options.insecureHTTP {
            let identity = try TLSIdentity.loadOrCreate(paths: store.paths, commonName: store.serverName)
            server = try .tls(.http1(), tlsConfiguration: identity.serverConfiguration())
            pin = identity.sha256
        }
        let urls = options.advertiseURLs.isEmpty
            ? LocalNetwork.advertisedURLs(scheme: scheme, port: options.port, tailscaleHost: options.tailscaleHost)
            : options.advertiseURLs
        let environment = PairingEnvironment(urls: urls, certificateSHA256: pin)
        let metadata = options.metadata ? MetadataService(store: store) : nil
        metadata?.startPeriodicRetry()
        let application = Application(
            router: buildRouter(store: store, metadata: metadata), server: server,
            configuration: .init(address: .hostname(options.hostname, port: options.port), serverName: "SupersEmu"),
            onServerRunning: onServerRunning)
        return (application, environment)
    }

    /// Runs until SIGTERM/SIGINT. The launch daemon calls this.
    public static func run(store: ServerStore, options: ServerRunOptions) async throws {
        let (application, environment) = try makeApplication(store: store, options: options)
        PairingEnvironment.current = environment
        var logger = Logger(label: "supersemu-server")
        logger.logLevel = .info
        logger.info("Serving \(options.insecureHTTP ? "HTTP (insecure)" : "HTTPS") on \(options.hostname):\(options.port)")
        logger.info("Pairing URLs: \(environment.urls.map(\.absoluteString).joined(separator: ", "))")
        if let pin = environment.certificateSHA256 { logger.info("Certificate SHA-256: \(pin)") }
        var advertiser: BonjourAdvertiser?
        if options.bonjour {
            do {
                advertiser = try BonjourAdvertiser(
                    name: store.serverName, port: options.port,
                    txt: SupersEmuBonjour.txtRecord(scheme: options.insecureHTTP ? "http" : "https",
                                                    certificateSHA256: environment.certificateSHA256, serverName: store.serverName))
            } catch {
                logger.warning("\(error)")
            }
        }
        defer { advertiser?.stop() }
        try await application.runService()
    }
}

/// First-run setup shared by `bootstrap` and `run --bootstrap`.
public enum ServerBootstrap {
    /// Creates the admin user if there is none and, when missing, a local admin token file that Server mode
    /// and the CLI read. As root (the launch daemon) the file is `root:admin 0640` so local admins can read it.
    @discardableResult
    public static func ensureAdmin(store: ServerStore, displayName: String, rotateToken: Bool = false) throws -> (admin: UserInfo, wroteToken: Bool) {
        let admin = try store.adminUser() ?? store.createUser(displayName: displayName, role: .admin)
        let url = store.paths.adminToken
        guard rotateToken || !FileManager.default.fileExists(atPath: url.path) else { return (admin, false) }
        let (_, token) = try store.createAPIToken(ownerUserID: admin.id, name: "local-cli", scopes: Scope.allCases)
        let runningAsRoot = getuid() == 0
        try? FileManager.default.removeItem(at: url)
        FileManager.default.createFile(atPath: url.path, contents: Data(token.utf8),
                                       attributes: [.posixPermissions: runningAsRoot ? 0o640 : 0o600])
        if runningAsRoot { chown(url.path, 0, 80) } // gid 80 = admin
        return (admin, true)
    }
}
