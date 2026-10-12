import Foundation
import Hummingbird
import HummingbirdCore
import HummingbirdTLS
import Logging
import NIOCore
import ServiceLifecycle
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
    public var publicURL: URL?
    public var publicPort: Int?
    public var publicAccess: PublicAccessConfiguration?

    public init() {}
}

public enum ServerLauncher {
    /// Builds the HTTPS (or `--insecure-http`) application and the pairing environment it advertises.
    public static func makeApplication(store: ServerStore, options: ServerRunOptions,
                                       onServerRunning: @escaping @Sendable (any Channel) async -> Void = { _ in }) throws
        -> (application: Application<RouterResponder<SERequestContext>>,
            publicApplication: Application<RouterResponder<SERequestContext>>?,
            environment: PairingEnvironment) {
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
        let publicAccess = options.publicAccess ?? {
            guard let publicURL = options.publicURL else { return nil }
            return try? PublicAccessConfiguration(enabled: true, publicURL: publicURL, listenPort: options.publicPort ?? 8489)
        }()
        let environment = PairingEnvironment(urls: urls, certificateSHA256: pin, publicURL: publicAccess?.publicURL)
        let metadata = options.metadata ? MetadataService.standard(store: store) : nil
        let pairing = PairingServices(store: store)
        metadata?.enqueue()
        metadata?.startPeriodicRetry()
        let application = Application(
            router: buildRouter(store: store, metadata: metadata, certificateSHA256: pin,
                                 publicURL: publicAccess?.publicURL, pairing: pairing), server: server,
            configuration: .init(address: .hostname(options.hostname, port: options.port), serverName: "SupersEmu"),
            onServerRunning: onServerRunning)
        let publicApplication = publicAccess.map { access in
            Application(
                router: buildRouter(store: store, metadata: metadata, exposure: .publicInternet,
                                    certificateSHA256: pin, publicURL: access.publicURL, pairing: pairing),
                server: .http1(),
                configuration: .init(address: .hostname(Self.publicListenHost, port: access.listenPort), serverName: "SupersEmu"))
        }
        return (application, publicApplication, environment)
    }

    public static let publicListenHost = "127.0.0.1"

    /// Runs until SIGTERM/SIGINT. The launch daemon calls this. Also runs the daily backup, and for a restore stops
    /// serving, closes the database, restores and starts serving again from the restored data.
    public static func run(store initial: ServerStore, options: ServerRunOptions) async throws {
        var store = initial
        var logger = Logger(label: "supersemu-server")
        logger.logLevel = .info
        var options = options
        do {
            options.publicAccess = try PublicAccessConfiguration.load(
                root: store.paths.root, publicURL: options.publicURL, listenPort: options.publicPort)
        } catch {
            options.publicAccess = nil
            logger.warning("Ignoring invalid public-access.json or public access override; public listener disabled")
        }
        while true {
            let (application, publicApplication, environment) = try makeApplication(store: store, options: options)
            PairingEnvironment.current = environment
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
            var services: [any Service] = [application]
            if let publicApplication { services.append(publicApplication) }
            let group = ServiceGroup(services: services, gracefulShutdownSignals: [.sigterm, .sigint], logger: logger)
            let pending = PendingRestore()
            await store.backups.setRestoreHandler { info in
                pending.set(info)
                // Lets the 202 for the restore request reach the client before connections close.
                try? await Task.sleep(for: .milliseconds(500))
                await group.triggerGracefulShutdown()
            }
            let scheduler = Task { [backups = store.backups] in await BackupScheduler.run(backups, logger: logger) }
            defer { scheduler.cancel() }
            do {
                try await group.run()
            } catch {
                advertiser?.stop()
                throw error
            }
            scheduler.cancel()
            await scheduler.value
            advertiser?.stop()
            await store.backups.setRestoreHandler(nil)

            guard let info = pending.value else { return }
            let paths = store.paths
            logger.notice("Stopped serving to restore backup \(info.id) from \(info.path)")
            do {
                try store.close()
            } catch {
                logger.error("Couldn't close the database for the restore, kept the current data: \(error)")
                await store.backups.finishRestore()
                continue
            }
            var record: BackupManager.RestoreRecord?
            do {
                let restored = try BackupManager.applyRestore(folder: URL(fileURLWithPath: info.path, isDirectory: true), to: paths)
                record = restored
                logger.notice("Restored backup \(info.id); the replaced data is in \(restored.safety.path)")
            } catch {
                logger.error("Restore failed, kept the current data: \(error)")
            }
            do {
                store = try ServerStore.open(paths: paths)
            } catch {
                // Never serve a closed store: put the previous data back, or exit so launchd restarts the daemon.
                guard let record else { throw error }
                logger.error("The restored data didn't open (\(error)); putting the previous data back")
                record.revert(paths)
                store = try ServerStore.open(paths: paths)
            }
        }
    }
}

private final class PendingRestore: @unchecked Sendable {
    private let lock = NSLock()
    private var info: BackupInfo?
    func set(_ info: BackupInfo) { lock.withLock { self.info = info } }
    var value: BackupInfo? { lock.withLock { info } }
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
