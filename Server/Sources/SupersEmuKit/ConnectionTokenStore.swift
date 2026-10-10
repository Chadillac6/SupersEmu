import Foundation
import Security

/// Where a paired device keeps its device token. One token per server (keyed by certificate pin or name).
public protocol DeviceTokenStore: Sendable {
    func token(for account: String) throws -> String?
    func setToken(_ token: String, for account: String) throws
    func removeToken(for account: String) throws
}

public struct KeychainError: Error, Equatable, CustomStringConvertible {
    public var status: OSStatus
    public var description: String { "Keychain error \(status)" }
}

/// Generic-password Keychain items. `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` so background save
/// sync works after the first unlock and the token never leaves the device in a backup.
public struct KeychainTokenStore: DeviceTokenStore {
    public var service: String

    public init(service: String = "com.chadillac6.supersemu.device-token") {
        self.service = service
    }

    private func query(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
    }

    public func token(for account: String) throws -> String? {
        var query = query(account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else { throw KeychainError(status: status) }
        return String(data: data, encoding: .utf8)
    }

    public func setToken(_ token: String, for account: String) throws {
        let data = Data(token.utf8)
        let update: [String: Any] = [kSecValueData as String: data]
        let status = SecItemUpdate(query(account) as CFDictionary, update as CFDictionary)
        if status == errSecSuccess { return }
        guard status == errSecItemNotFound else { throw KeychainError(status: status) }
        var add = query(account)
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let addStatus = SecItemAdd(add as CFDictionary, nil)
        guard addStatus == errSecSuccess else { throw KeychainError(status: addStatus) }
    }

    public func removeToken(for account: String) throws {
        let status = SecItemDelete(query(account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw KeychainError(status: status) }
    }
}

/// For tests and previews.
public final class InMemoryTokenStore: DeviceTokenStore, @unchecked Sendable {
    private let lock = NSLock()
    private var tokens: [String: String] = [:]

    public init() {}

    public func token(for account: String) throws -> String? { lock.withLock { tokens[account] } }
    public func setToken(_ token: String, for account: String) throws { lock.withLock { tokens[account] = token } }
    public func removeToken(for account: String) throws { lock.withLock { _ = tokens.removeValue(forKey: account) } }
}
