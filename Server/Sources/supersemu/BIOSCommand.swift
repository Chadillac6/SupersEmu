import ArgumentParser
import Foundation
import SupersEmuKit

struct BIOS: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "bios",
        abstract: "BIOS files on the server. Import them like games; they're recognised by hash.",
        subcommands: [Status.self])

    struct Status: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Present, missing or wrong-hash for each known BIOS, per system.")
        @OptionGroup var connection: Connection

        func run() async throws {
            try await CLIOutput.run(json: connection.json) {
                let status = try await connection.client().biosStatus()
                if connection.json { return try CLIOutput.json(status) }
                CLIOutput.table(["SYSTEM", "FILE", "REGION", "NEEDED", "STATUS"], status.map {
                    [$0.system.rawValue, $0.filename, $0.region, $0.required ? "required" : "optional", $0.state.rawValue]
                })
                let missing = status.filter { $0.required && $0.state != .present }
                if !missing.isEmpty {
                    CLIOutput.stdout("Missing required BIOS: \(missing.map(\.filename).joined(separator: ", ")). Import it with `supersemu library import <file>`.")
                }
            }
        }
    }
}
