import ArgumentParser
import Foundation
import SupersEmuKit

struct Login: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Save a server URL and token to ~/.config/supersemu/config.json (mode 0600).",
        discussion: "The token is checked against /v1/me first. Env SUPERSEMU_CONFIG overrides the file path.")

    @Option(help: "Server URL, e.g. https://games.supersemu.com.") var server: String
    @Option(help: "Token. Prefer --token-stdin so it stays out of shell history.") var token: String?
    @Flag(help: "Read the token from stdin.") var tokenStdin = false
    @Option(help: "Server certificate SHA-256 to pin for the check (self-signed server).") var certificateSHA256: String?
    @Flag(help: "Save without checking the token against the server.") var noVerify = false
    @Flag(help: "Print JSON.") var json = false

    func validate() throws {
        if (token == nil) == !tokenStdin { throw ValidationError("Pass exactly one of --token or --token-stdin") }
    }

    struct Output: Encodable { var server: String; var configPath: String; var me: MeResponse? }

    func run() async throws {
        try await CLIOutput.run(json: json) {
            let value = (token ?? readLine(strippingNewline: true) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty else { throw CLIError.usage("Empty token") }
            var connection = Connection()
            connection.server = server
            connection.token = value
            connection.certificateSHA256 = certificateSHA256
            let resolved = try connection.resolve(environment: [:], useSavedConfig: false)
            let me = noVerify ? nil : try await APIClient(baseURL: resolved.server, token: value, session: try Connection.session(for: resolved)).me()
            let url = CLIConfigFile.defaultURL()
            try CLIConfigFile(server: server, token: value, certificateSHA256: resolved.certificateSHA256).write(to: url)
            if json { return try CLIOutput.json(Output(server: server, configPath: url.path, me: me)) }
            if let me { CLIOutput.stdout("Signed in to \(server) as \(me.user.displayName) [\(me.user.role.rawValue)]") }
            CLIOutput.stdout("Saved \(url.path)")
        }
    }
}
