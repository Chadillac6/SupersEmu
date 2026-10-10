import ArgumentParser
import Foundation
import SupersEmuKit

struct Tokens: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Scoped API tokens for scripts and bots (admin).", subcommands: [Create.self, List.self, Revoke.self])

    struct Create: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Create a token. The plaintext token is printed once (stdout) and never shown again.")
        @Option(help: "Name, e.g. openclaw.") var name: String
        @Option(help: "Comma-separated scopes: \(Scope.allCases.map(\.rawValue).joined(separator: ", ")). Repeatable.")
        var scope: [String]
        @OptionGroup var connection: Connection

        var scopes: [Scope] {
            get throws {
                let names = scope.flatMap { $0.split(separator: ",") }.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                var result: [Scope] = []
                for name in names {
                    guard let scope = Scope(rawValue: name) else {
                        throw ValidationError("Unknown scope '\(name)'. Valid: \(Scope.allCases.map(\.rawValue).joined(separator: ", "))")
                    }
                    if !result.contains(scope) { result.append(scope) }
                }
                return result
            }
        }

        func validate() throws {
            if name.trimmingCharacters(in: .whitespaces).isEmpty { throw ValidationError("--name must not be empty") }
            if try scopes.isEmpty { throw ValidationError("At least one --scope is required") }
        }

        func run() async throws {
            try await CLIOutput.run(json: connection.json) {
                let info = try await connection.client().createToken(CreateTokenRequest(name: name, scopes: try scopes))
                if connection.json { return try CLIOutput.json(info) }
                // stdout is just the token so `TOKEN=$(supersemu tokens create ...)` works.
                CLIOutput.stderr("Created token \(info.name) (\(info.id)) [\(info.scopes.map(\.rawValue).joined(separator: ","))]. Store it now; it is not shown again.")
                CLIOutput.stdout(info.token ?? "")
            }
        }
    }

    struct List: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "List tokens (never shows token values).")
        @OptionGroup var connection: Connection

        func run() async throws {
            try await CLIOutput.run(json: connection.json) {
                let tokens = try await connection.client().tokens()
                if connection.json { return try CLIOutput.json(tokens) }
                CLIOutput.table(["ID", "NAME", "SCOPES", "CREATED", "STATUS"], tokens.map {
                    [$0.id, $0.name, $0.scopes.map(\.rawValue).joined(separator: ","), CLIOutput.date($0.createdAt), $0.revokedAt == nil ? "active" : "revoked"]
                })
            }
        }
    }

    struct Revoke: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Revoke a token. It stops working immediately.")
        @Argument(help: "Token ID (from `tokens list`).") var id: String
        @OptionGroup var connection: Connection

        func run() async throws {
            try await CLIOutput.run(json: connection.json) {
                let info = try await connection.client().revokeToken(id)
                if connection.json { return try CLIOutput.json(info) }
                CLIOutput.stdout("Revoked token \(info.name) (\(info.id))")
            }
        }
    }
}
