import Foundation

// Track: CLI + admin. Additive DTOs and client methods beyond `Contracts.swift`.

/// Phase 2 groundwork: creates a player account (no invite UI yet). Admin accounts are only created by `bootstrap`.
public struct CreateUserRequest: Codable, Sendable, Equatable {
    public var displayName: String
    public init(displayName: String) { self.displayName = displayName }
}

extension APIClient {
    public func createUser(_ request: CreateUserRequest) async throws -> UserInfo { try await send("POST", "/v1/admin/users", body: request) }

    public func userGames(userID: String) async throws -> UserGameAccess {
        try await get("/v1/admin/users/\(userID)/games")
    }

    public func setUserGames(userID: String, hiddenGameIDs: [String]) async throws -> UserGameAccess {
        try await send("PUT", "/v1/admin/users/\(userID)/games", body: SetUserGamesRequest(hiddenGameIDs: hiddenGameIDs))
    }

    public func updateUser(id: String, displayName: String) async throws -> UserInfo {
        try await send("PATCH", "/v1/admin/users/\(id)", body: UpdateUserRequest(displayName: displayName))
    }

    public func removeUser(id: String) async throws -> UserInfo {
        try await send("DELETE", "/v1/admin/users/\(id)", body: Optional<String>.none)
    }
}
