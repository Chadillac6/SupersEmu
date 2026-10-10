import ArgumentParser
import Foundation
import SupersEmuKit

struct Devices: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Paired devices (admin).", subcommands: [List.self, Revoke.self])

    struct List: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "List devices, including revoked ones.")
        @OptionGroup var connection: Connection

        func run() async throws {
            try await CLIOutput.run(json: connection.json) {
                let devices = try await connection.client().devices()
                if connection.json { return try CLIOutput.json(devices) }
                CLIOutput.table(["ID", "NAME", "USER", "LAST SEEN", "STATUS"], devices.map {
                    [$0.id, $0.name, $0.userID, CLIOutput.date($0.lastSeenAt), $0.revokedAt == nil ? "active" : "revoked"]
                })
            }
        }
    }

    struct Revoke: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Revoke a device. Its token stops working immediately.")
        @Argument(help: "Device ID (from `devices list`).") var id: String
        @OptionGroup var connection: Connection

        func run() async throws {
            try await CLIOutput.run(json: connection.json) {
                let device = try await connection.client().revokeDevice(id)
                if connection.json { return try CLIOutput.json(device) }
                CLIOutput.stdout("Revoked device \(device.name) (\(device.id))")
            }
        }
    }
}
