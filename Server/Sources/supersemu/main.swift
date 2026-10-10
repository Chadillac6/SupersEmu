import ArgumentParser
import Foundation
import SupersEmuKit

@main
struct SupersEmuCLI: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "supersemu",
        abstract: "Control a SupersEmu Server from scripts and bots (OpenClaw).",
        subcommands: [Server.self])

    struct Connection: ParsableArguments {
        @Option(help: "Server URL. Env: SUPERSEMU_SERVER.")
        var server: String = ProcessInfo.processInfo.environment["SUPERSEMU_SERVER"] ?? "https://127.0.0.1:8487"
        @Option(help: "API token. Env: SUPERSEMU_TOKEN. Default: the server's admin.token when run on the Mac mini.")
        var token: String?
        @Option(help: "Server certificate SHA-256 to pin. Env: SUPERSEMU_CERT_SHA256. Default: the local server's tls/server.cer.")
        var certificateSHA256: String?
        @Flag(help: "Print JSON instead of text.") var json = false

        func client() throws -> APIClient {
            guard let url = URL(string: server) else { throw ValidationError("Invalid --server URL") }
            let pin = certificateSHA256 ?? ProcessInfo.processInfo.environment["SUPERSEMU_CERT_SHA256"]
                ?? FileManager.default.contents(atPath: "/Library/Application Support/SupersEmu Server/tls/server.cer").map(CertificatePin.sha256(ofDER:))
            let session = url.scheme == "https" ? PinnedCertificateDelegate.session(certificateSHA256: pin) : URLSession.shared
            let resolved = token ?? ProcessInfo.processInfo.environment["SUPERSEMU_TOKEN"]
                ?? (try? String(contentsOfFile: "/Library/Application Support/SupersEmu Server/admin.token", encoding: .utf8))
            return APIClient(baseURL: url, token: resolved?.trimmingCharacters(in: .whitespacesAndNewlines), session: session)
        }
    }

    struct Server: AsyncParsableCommand {
        static let configuration = CommandConfiguration(subcommands: [Status.self])

        struct Status: AsyncParsableCommand {
            @OptionGroup var connection: Connection

            func run() async throws {
                let client = try connection.client()
                let health = try await client.health()
                let me = try? await client.me()
                if connection.json {
                    struct Out: Encodable { var health: HealthResponse; var me: MeResponse? }
                    print(String(decoding: try SupersEmuJSON.encoder().encode(Out(health: health, me: me)), as: UTF8.self))
                } else {
                    print("\(health.serverName): \(health.status) (server \(health.serverVersion), API \(health.apiVersion))")
                    if let me { print("Signed in as \(me.user.displayName) [\(me.user.role.rawValue)]") }
                }
            }
        }
    }
}
