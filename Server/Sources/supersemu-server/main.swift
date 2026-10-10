import ArgumentParser
import Foundation
import Hummingbird
import SupersEmuKit
import SupersEmuServerCore

@main
struct SupersEmuServerCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "supersemu-server",
        abstract: "SupersEmu home server: library, users and saves for the SupersEmu apps.",
        subcommands: [Run.self, Bootstrap.self],
        defaultSubcommand: Run.self)

    struct Options: ParsableArguments {
        @Option(help: "Data directory (library, games, saves).")
        var dataDir: String = ServerPaths.defaultRoot.path
        var paths: ServerPaths { ServerPaths(root: URL(fileURLWithPath: dataDir, isDirectory: true)) }
    }

    struct Run: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Run the server (the launch daemon runs this).")
        @OptionGroup var options: Options
        @Option var hostname = "0.0.0.0"
        @Option var port = ServerDefaults.port
        @Flag(help: "Serve plain HTTP instead of HTTPS (tests and local debugging only).")
        var insecureHTTP = false
        @Option(name: .customLong("advertise-url"), help: "URL to put in pairing QR codes (repeatable; default: detected LAN + Tailscale).")
        var advertiseURLs: [String] = []
        @Option(help: "Tailscale MagicDNS name of this Mac, e.g. mac-mini.tail1234.ts.net.")
        var tailscaleHost: String?
        @Flag(help: "Don't advertise _supersemu._tcp over Bonjour.")
        var noBonjour = false
        @Flag(help: "Don't match games against libretro-database or download artwork.")
        var noMetadata = false
        @Flag(help: "Create the admin user and local admin token on first run if missing.")
        var bootstrap = false
        @Option(help: "Admin display name used by --bootstrap.")
        var adminName = "Chad"

        func run() async throws {
            let store = try ServerStore.open(paths: options.paths)
            if bootstrap {
                let (admin, wroteToken) = try ServerBootstrap.ensureAdmin(store: store, displayName: adminName)
                if wroteToken { print("Admin \(admin.displayName) (\(admin.id)). Local admin token written to \(options.paths.adminToken.path)") }
            }
            var runOptions = ServerRunOptions()
            runOptions.hostname = hostname
            runOptions.port = port
            runOptions.insecureHTTP = insecureHTTP
            runOptions.advertiseURLs = try advertiseURLs.map { value in
                guard let url = URL(string: value), url.scheme != nil, url.host != nil else {
                    throw ValidationError("Invalid --advertise-url \(value)")
                }
                return url
            }
            runOptions.tailscaleHost = tailscaleHost
            runOptions.bonjour = !noBonjour
            runOptions.metadata = !noMetadata
            try await ServerLauncher.run(store: store, options: runOptions)
        }
    }

    struct Bootstrap: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "First-run setup: create the admin user and a local admin token for the CLI.")
        @OptionGroup var options: Options
        @Option(help: "Admin display name.") var name = "Chad"

        func run() async throws {
            let store = try ServerStore.open(paths: options.paths)
            let (admin, _) = try ServerBootstrap.ensureAdmin(store: store, displayName: name, rotateToken: true)
            print("Admin \(admin.displayName) (\(admin.id)). Local CLI token written to \(options.paths.adminToken.path)")
        }
    }
}
