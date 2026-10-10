import ArgumentParser
import Foundation
import SupersEmuKit

struct Users: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Server users (admin).", subcommands: [List.self, Create.self])

    struct List: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "List users.")
        @OptionGroup var connection: Connection

        func run() async throws {
            try await CLIOutput.run(json: connection.json) {
                let users = try await connection.client().users()
                if connection.json { return try CLIOutput.json(users) }
                CLIOutput.table(["ID", "NAME", "ROLE"], users.map { [$0.id, $0.displayName, $0.role.rawValue] })
            }
        }
    }

    struct Create: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Create a player account (Phase 2 groundwork; pair their device with a pairing code).")
        @Argument(help: "Display name.") var name: String
        @OptionGroup var connection: Connection

        func run() async throws {
            try await CLIOutput.run(json: connection.json) {
                let user = try await connection.client().createUser(CreateUserRequest(displayName: name))
                if connection.json { return try CLIOutput.json(user) }
                CLIOutput.stdout("Created \(user.role.rawValue) \(user.displayName) (\(user.id))")
            }
        }
    }
}
