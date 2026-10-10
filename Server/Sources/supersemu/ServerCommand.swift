import ArgumentParser
import Foundation
import SupersEmuKit

struct Server: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Server health and status.", subcommands: [Status.self])

    struct Status: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Health, signed-in identity and (for admins) disk space and counts.")
        @OptionGroup var connection: Connection

        struct Output: Encodable {
            var health: HealthResponse
            var me: MeResponse?
            var admin: AdminStatus?
        }

        func run() async throws {
            try await CLIOutput.run(json: connection.json) {
                let client = try connection.client()
                let health = try await client.health()
                var me: MeResponse?
                var admin: AdminStatus?
                if client.token != nil {
                    me = try await client.me()
                    // Scoped tokens without users:admin still get health + identity.
                    do { admin = try await client.adminStatus() } catch APIClientError.http(status: 403, _) {}
                }
                if connection.json { return try CLIOutput.json(Output(health: health, me: me, admin: admin)) }
                CLIOutput.stdout("\(health.serverName): \(health.status) (server \(health.serverVersion), API \(health.apiVersion))")
                if let me {
                    let via = me.deviceID.map { "device \($0)" } ?? "token [\((me.scopes ?? []).map(\.rawValue).joined(separator: ","))]"
                    CLIOutput.stdout("Signed in as \(me.user.displayName) [\(me.user.role.rawValue)] via \(via)")
                } else {
                    CLIOutput.stdout("Not signed in (no token)")
                }
                if let admin {
                    let free = admin.freeBytes.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) } ?? "unknown"
                    CLIOutput.stdout("Data: \(admin.dataDirectory) (\(free) free)")
                    CLIOutput.stdout("Games: \(admin.gameCount), needs review: \(admin.reviewCount), users: \(admin.userCount), devices: \(admin.deviceCount)")
                }
            }
        }
    }
}
