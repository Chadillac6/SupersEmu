#if os(macOS)
import Foundation
import Observation
import SupersEmuKit

@MainActor @Observable
final class UsersGamesModel {
    private struct PendingUpdate {
        var userID: String
        var hiddenGameIDs: [String]
    }

    let server: ServerModeModel
    private(set) var users: [UserInfo] = []
    private(set) var devices: [DeviceInfo] = []
    private(set) var games: [GameSummary] = []
    private(set) var selectedUserID: String?
    private(set) var hiddenGameIDs: Set<String> = []
    private(set) var isLoading = false
    private(set) var isLoadingAccess = false
    private(set) var error: String?
    private var confirmedHiddenByUser: [String: Set<String>] = [:]
    private var optimisticHiddenByUser: [String: Set<String>] = [:]
    private var pendingUpdates: [String: [String]] = [:]
    private var updateOrder: [String] = []
    private var updateWorker: Task<Void, Never>?
    private var selectionGeneration = 0

    init(server: ServerModeModel) {
        self.server = server
    }

    var selectedUser: UserInfo? { users.first { $0.id == selectedUserID } }
    var activeDevices: [DeviceInfo] {
        guard let selectedUserID else { return [] }
        return devices.filter { $0.userID == selectedUserID && $0.revokedAt == nil }
    }
    var visibleGameCount: Int { games.filter { !hiddenGameIDs.contains($0.id) }.count }
    var isAdminSelected: Bool { selectedUser?.role == .admin }

    func reset() {
        users = []
        devices = []
        games = []
        selectedUserID = nil
        hiddenGameIDs = []
        confirmedHiddenByUser = [:]
        optimisticHiddenByUser = [:]
        pendingUpdates = [:]
        updateOrder = []
        updateWorker?.cancel()
        updateWorker = nil
        error = nil
    }

    func refresh() async {
        isLoading = true
        defer { isLoading = false }
        do {
            let client = try server.adminClient()
            users = try await client.adminUsers()
            devices = try await client.devices()
            games = try await client.library().games
            error = nil
            let nextSelection = selectedUserID.flatMap { id in users.first(where: { $0.id == id })?.id }
                ?? users.first(where: { $0.role == .player })?.id
                ?? users.first?.id
            await selectUser(nextSelection)
        } catch {
            self.error = LibraryManagerModel.describe(error)
        }
    }

    func selectUser(_ userID: String?) async {
        selectionGeneration += 1
        let generation = selectionGeneration
        selectedUserID = userID
        hiddenGameIDs = []
        isLoadingAccess = false
        error = nil
        guard let userID, users.first(where: { $0.id == userID })?.role == .player else { return }
        if let optimistic = optimisticHiddenByUser[userID] {
            hiddenGameIDs = optimistic
            return
        }
        if let confirmed = confirmedHiddenByUser[userID] {
            hiddenGameIDs = confirmed
            return
        }
        isLoadingAccess = true
        defer { if generation == selectionGeneration { isLoadingAccess = false } }
        do {
            let client = try server.adminClient()
            let access = try await client.userGames(userID: userID)
            guard generation == selectionGeneration else { return }
            let hidden = Set(access.hiddenGameIDs)
            confirmedHiddenByUser[userID] = hidden
            hiddenGameIDs = hidden
        } catch {
            guard generation == selectionGeneration else { return }
            self.error = LibraryManagerModel.describe(error)
        }
    }

    func createFriend(displayName: String) async throws -> UserInfo {
        let client = try server.adminClient()
        let created = try await client.createUser(CreateUserRequest(displayName: displayName))
        users.append(created)
        users.sort { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
        await selectUser(created.id)
        return created
    }

    func renameSelectedUser(displayName: String) async {
        guard let selectedUserID else { return }
        do {
            let client = try server.adminClient()
            let updated = try await client.updateUser(id: selectedUserID, displayName: displayName)
            if let index = users.firstIndex(where: { $0.id == updated.id }) { users[index] = updated }
            error = nil
        } catch {
            self.error = LibraryManagerModel.describe(error)
        }
    }

    func createPairingCode(for userID: String) async throws -> PairingCode {
        let client = try server.adminClient()
        return try await client.createPairingCode(CreatePairingCodeRequest(userID: userID))
    }

    func removeSelectedUser() async {
        guard let selectedUserID else { return }
        do {
            let client = try server.adminClient()
            _ = try await client.removeUser(id: selectedUserID)
            users.removeAll { $0.id == selectedUserID }
            devices.removeAll { $0.userID == selectedUserID }
            confirmedHiddenByUser.removeValue(forKey: selectedUserID)
            optimisticHiddenByUser.removeValue(forKey: selectedUserID)
            await selectUser(users.first(where: { $0.role == .player })?.id ?? users.first?.id)
            error = nil
        } catch {
            self.error = LibraryManagerModel.describe(error)
        }
    }

    func removeDevice(_ device: DeviceInfo) async {
        do {
            let client = try server.adminClient()
            let revoked = try await client.revokeDevice(device.id)
            if let index = devices.firstIndex(where: { $0.id == revoked.id }) { devices[index] = revoked }
            error = nil
        } catch {
            self.error = LibraryManagerModel.describe(error)
        }
    }

    func setVisible(_ gameID: String, visible: Bool) {
        guard let userID = selectedUserID, selectedUser?.role == .player else { return }
        error = nil
        if visible { hiddenGameIDs.remove(gameID) } else { hiddenGameIDs.insert(gameID) }
        optimisticHiddenByUser[userID] = hiddenGameIDs
        if pendingUpdates[userID] == nil { updateOrder.append(userID) }
        pendingUpdates[userID] = hiddenGameIDs.sorted()
        if updateWorker == nil {
            updateWorker = Task { await self.flushUpdates() }
        }
    }

    private func flushUpdates() async {
        while !updateOrder.isEmpty {
            let userID = updateOrder.removeFirst()
            guard let hidden = pendingUpdates.removeValue(forKey: userID) else { continue }
            do {
                let client = try server.adminClient()
                let response = try await client.setUserGames(userID: userID, hiddenGameIDs: hidden)
                let confirmed = Set(response.hiddenGameIDs)
                confirmedHiddenByUser[userID] = confirmed
                if pendingUpdates[userID] == nil {
                    optimisticHiddenByUser.removeValue(forKey: userID)
                    if selectedUserID == userID { hiddenGameIDs = confirmed }
                    error = nil
                }
            } catch {
                if pendingUpdates[userID] == nil {
                    optimisticHiddenByUser.removeValue(forKey: userID)
                    if selectedUserID == userID { hiddenGameIDs = confirmedHiddenByUser[userID] ?? [] }
                    self.error = LibraryManagerModel.describe(error)
                }
            }
        }
        updateWorker = nil
        if !updateOrder.isEmpty { updateWorker = Task { await self.flushUpdates() } }
    }
}
#endif
