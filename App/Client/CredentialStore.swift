import Foundation
import Security
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

/// App-side credential storage, behind a protocol so it can be swapped for SupersEmuKit's
/// ServerConnection/Keychain helpers once the pairing track lands.
protocol CredentialStore: Sendable {
    func load() -> ServerCredential?
    func save(_ credential: ServerCredential) throws
    func delete()
}

struct KeychainError: Error, LocalizedError {
    let status: OSStatus
    var errorDescription: String? { "Keychain error \(status)" }
}

struct KeychainCredentialStore: CredentialStore {
    var service = "com.chadillac6.supersemu.server"
    var account = "default"

    private var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
    }

    func load() -> ServerCredential? {
        var query = query
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
        return try? SupersEmuJSON.decoder().decode(ServerCredential.self, from: data)
    }

    func save(_ credential: ServerCredential) throws {
        let data = try SupersEmuJSON.encoder().encode(credential)
        SecItemDelete(query as CFDictionary)
        var item = query
        item[kSecValueData as String] = data
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(item as CFDictionary, nil)
        guard status == errSecSuccess else { throw KeychainError(status: status) }
    }

    func delete() {
        SecItemDelete(query as CFDictionary)
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
