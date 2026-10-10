import ArgumentParser
import Foundation
import SupersEmuKit

struct SupersEmuCLI: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "supersemu",
        abstract: "Control a SupersEmu Server from scripts and bots (OpenClaw).",
        discussion: "Docs: docs/specs/cli.md. Exit codes: 0 ok, 1 error, 2 not found, 3 unauthorized, 4 forbidden, 5 server unreachable, 6 bad request, 7 server error, 64 usage.",
        // One line per command group; other tracks append theirs here.
        subcommands: [
            Login.self,
            Server.self,
            Users.self,
            Devices.self,
            Tokens.self,
            Library.self,
        ])
}

// Entry point. main.swift can't use @main in a multi-file module, and calling `run()` straight from
// top-level code picks ParsableCommand's synchronous `run()` (which only prints help), so go
// through an async function.
func runSupersEmuCLI() async {
    do {
        var command = try SupersEmuCLI.parseAsRoot()
        if var asyncCommand = command as? AsyncParsableCommand {
            try await asyncCommand.run()
        } else {
            try command.run()
        }
    } catch {
        SupersEmuCLI.exit(withError: error)
    }
}

await runSupersEmuCLI()
