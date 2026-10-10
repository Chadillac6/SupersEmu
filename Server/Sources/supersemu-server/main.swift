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
        @Option var port = 8487

        func run() async throws {
            let store = try ServerStore.open(paths: options.paths)
            let app = buildApplication(store: store, configuration: .init(address: .hostname(hostname, port: port), serverName: "SupersEmu"))
            try await app.runService()
        }
    }

    struct Bootstrap: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "First-run setup: create the admin user and a local admin token for the CLI.")
        @OptionGroup var options: Options
        @Option(help: "Admin display name.") var name = "Chad"

        func run() async throws {
            let store = try ServerStore.open(paths: options.paths)
            let admin = try store.adminUser() ?? store.createUser(displayName: name, role: .admin)
            let (_, token) = try store.createAPIToken(ownerUserID: admin.id, name: "local-cli", scopes: Scope.allCases)
            let url = options.paths.adminToken
            FileManager.default.createFile(atPath: url.path, contents: Data(token.utf8), attributes: [.posixPermissions: 0o600])
            print("Admin \(admin.displayName) (\(admin.id)). Local CLI token written to \(url.path)")
        }
    }
}
