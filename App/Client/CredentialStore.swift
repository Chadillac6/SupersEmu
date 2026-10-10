import Foundation
import SupersEmuKit

/// What this device needs to talk to its server after pairing.
struct ServerCredential: Codable, Equatable, Sendable {
    var serverName: String
    /// Tried in order (LAN first, then Tailscale).
    var urls: [URL]
    var certificateSHA256: String?
    var token: String
    var deviceID: String
    var user: UserInfo
}

/// App-side credential storage. The Keychain item is written through SupersEmuKit's `KeychainTokenStore`.
protocol CredentialStore: Sendable {
    func load() -> ServerCredential?
    func save(_ credential: ServerCredential) throws
    func delete()
}

struct KeychainCredentialStore: CredentialStore {
    var service = "com.chadillac6.supersemu.server"
    var account = "default"

    private var keychain: KeychainTokenStore { KeychainTokenStore(service: service) }

    func load() -> ServerCredential? {
        guard let json = try? keychain.token(for: account) else { return nil }
        return try? SupersEmuJSON.decoder().decode(ServerCredential.self, from: Data(json.utf8))
    }

    func save(_ credential: ServerCredential) throws {
        try keychain.setToken(String(decoding: try SupersEmuJSON.encoder().encode(credential), as: UTF8.self), for: account)
    }

    func delete() {
        try? keychain.removeToken(for: account)
    }
}

#if DEBUG
/// UI-test/dev hook: launch with SUPERSEMU_SERVER_URL + SUPERSEMU_SERVER_TOKEN to skip pairing
/// (e.g. against a local `supersemu-server` using its bootstrap token). Never touches the Keychain.
final class LaunchEnvironmentCredentialStore: CredentialStore, @unchecked Sendable {
    private var credential: ServerCredential?

    init?(environment: [String: String] = ProcessInfo.processInfo.environment) {
        guard let raw = environment["SUPERSEMU_SERVER_URL"], let url = URL(string: raw),
              let token = environment["SUPERSEMU_SERVER_TOKEN"], !token.isEmpty else { return nil }
        credential = ServerCredential(
            serverName: environment["SUPERSEMU_SERVER_NAME"] ?? "Local SupersEmu Server", urls: [url],
            certificateSHA256: nil, token: token, deviceID: "launch-environment",
            user: UserInfo(id: "launch-environment", displayName: "Test", role: .admin))
    }

    func load() -> ServerCredential? { credential }
    func save(_ credential: ServerCredential) throws { self.credential = credential }
    func delete() { credential = nil }
}
#endif
