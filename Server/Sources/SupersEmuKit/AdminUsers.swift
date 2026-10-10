import Foundation

// Track: CLI + admin. Additive DTOs and client methods beyond `Contracts.swift`.

/// Phase 2 groundwork: creates a player account (no invite UI yet). Admin accounts are only created by `bootstrap`.
public struct CreateUserRequest: Codable, Sendable, Equatable {
    public var displayName: String
    public init(displayName: String) { self.displayName = displayName }
}

extension APIClient {
    public func createUser(_ request: CreateUserRequest) async throws -> UserInfo { try await send("POST", "/v1/admin/users", body: request) }
}
