#if os(macOS)
import Foundation
import Observation
import SupersEmuKit

private struct ServerSelectionChangedError: LocalizedError {
    var errorDescription: String? { "The selected server changed before the request completed." }
}

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
    private var resetGeneration = 0
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
        resetGeneration += 1
        selectionGeneration += 1
        users = []
        devices = []
        games = []
        selectedUserID = nil
        hiddenGameIDs = []
        isLoading = false
        isLoadingAccess = false
        confirmedHiddenByUser = [:]
        optimisticHiddenByUser = [:]
        pendingUpdates = [:]
        updateOrder = []
        updateWorker?.cancel()
        updateWorker = nil
        error = nil
    }

    func refresh() async {
        let generation = resetGeneration
        isLoading = true
        defer { if generation == resetGeneration { isLoading = false } }
        do {
            let client = try server.adminClient()
            let refreshedUsers = try await client.adminUsers()
            guard generation == resetGeneration else { return }
            users = refreshedUsers
            let refreshedDevices = try await client.devices()
            guard generation == resetGeneration else { return }
            devices = refreshedDevices
            let refreshedGames = try await client.library().games
            guard generation == resetGeneration else { return }
            games = refreshedGames
            error = nil
            let gameIDs = Set(refreshedGames.map(\.id))
            confirmedHiddenByUser = [:]
            optimisticHiddenByUser = optimisticHiddenByUser.mapValues { $0.intersection(gameIDs) }
            pendingUpdates = pendingUpdates.mapValues { $0.filter { gameIDs.contains($0) } }
            updateOrder.removeAll { pendingUpdates[$0] == nil }
            if let selectedUserID, let optimistic = optimisticHiddenByUser[selectedUserID] {
                hiddenGameIDs = optimistic
            } else {
                hiddenGameIDs = hiddenGameIDs.intersection(gameIDs)
            }
            let nextSelection = selectedUserID.flatMap { id in users.first(where: { $0.id == id })?.id }
                ?? users.first(where: { $0.role == .player })?.id
                ?? users.first?.id
            await selectUser(nextSelection)
            guard generation == resetGeneration else { return }
        } catch {
            guard generation == resetGeneration else { return }
            self.error = LibraryManagerModel.describe(error)
        }
    }

    func selectUser(_ userID: String?) async {
        let resetGeneration = self.resetGeneration
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
            guard resetGeneration == self.resetGeneration, generation == selectionGeneration else { return }
            let hidden = Set(access.hiddenGameIDs)
            confirmedHiddenByUser[userID] = hidden
            hiddenGameIDs = hidden
        } catch {
            guard resetGeneration == self.resetGeneration, generation == selectionGeneration else { return }
            self.error = LibraryManagerModel.describe(error)
        }
    }

    func createFriend(displayName: String) async throws -> UserInfo {
        let generation = resetGeneration
        let client = try server.adminClient()
        let created = try await client.createUser(CreateUserRequest(displayName: displayName))
        guard generation == resetGeneration else { throw ServerSelectionChangedError() }
        users.append(created)
        users.sort { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
        await selectUser(created.id)
        guard generation == resetGeneration else { throw ServerSelectionChangedError() }
        return created
    }

    func renameSelectedUser(displayName: String) async throws {
        guard let selectedUserID else { throw ServerSelectionChangedError() }
        let generation = resetGeneration
        let client = try server.adminClient()
        let updated = try await client.updateUser(id: selectedUserID, displayName: displayName)
        guard generation == resetGeneration else { throw ServerSelectionChangedError() }
        if let index = users.firstIndex(where: { $0.id == updated.id }) { users[index] = updated }
        error = nil
    }

    func createPairingCode(for userID: String) async throws -> PairingCode {
        let generation = resetGeneration
        let client = try server.adminClient()
        let pairing = try await client.createPairingCode(CreatePairingCodeRequest(userID: userID))
        guard generation == resetGeneration else { throw ServerSelectionChangedError() }
        return pairing
    }

    func removeSelectedUser() async {
        guard let selectedUserID else { return }
        let userID = selectedUserID
        let generation = resetGeneration
        do {
            let client = try server.adminClient()
            _ = try await client.removeUser(id: userID)
            guard generation == resetGeneration else { return }
            users.removeAll { $0.id == userID }
            devices.removeAll { $0.userID == userID }
            confirmedHiddenByUser.removeValue(forKey: userID)
            optimisticHiddenByUser.removeValue(forKey: userID)
            pendingUpdates.removeValue(forKey: userID)
            updateOrder.removeAll { $0 == userID }
            if selectedUserID == userID {
                let nextSelection = users.first(where: { $0.role == .player })?.id ?? users.first?.id
                await selectUser(nextSelection)
                guard generation == resetGeneration else { return }
            }
            error = nil
        } catch {
            guard generation == resetGeneration else { return }
            self.error = LibraryManagerModel.describe(error)
        }
    }

    func removeDevice(_ device: DeviceInfo) async {
        let generation = resetGeneration
        do {
            let client = try server.adminClient()
            let revoked = try await client.revokeDevice(device.id)
            guard generation == resetGeneration else { return }
            if let index = devices.firstIndex(where: { $0.id == revoked.id }) { devices[index] = revoked }
            error = nil
        } catch {
            guard generation == resetGeneration else { return }
            self.error = LibraryManagerModel.describe(error)
        }
    }

    func setVisible(_ gameID: String, visible: Bool) {
        guard let userID = selectedUserID, selectedUser?.role == .player else { return }
        let gameIDs = Set(games.map(\.id))
        guard gameIDs.contains(gameID) else { return }
        error = nil
        if visible { hiddenGameIDs.remove(gameID) } else { hiddenGameIDs.insert(gameID) }
        hiddenGameIDs.formIntersection(gameIDs)
        optimisticHiddenByUser[userID] = hiddenGameIDs
        if pendingUpdates[userID] == nil { updateOrder.append(userID) }
        pendingUpdates[userID] = hiddenGameIDs.intersection(gameIDs).sorted()
        if updateWorker == nil {
            let generation = resetGeneration
            updateWorker = Task { await self.flushUpdates(for: generation) }
        }
    }

    private func flushUpdates(for generation: Int) async {
        while !updateOrder.isEmpty {
            guard generation == resetGeneration else { return }
            let userID = updateOrder.removeFirst()
            guard let hidden = pendingUpdates.removeValue(forKey: userID) else { continue }
            let writeGeneration = resetGeneration
            guard writeGeneration == generation else { return }
            do {
                let client = try server.adminClient()
                let response = try await client.setUserGames(userID: userID, hiddenGameIDs: hidden)
                guard writeGeneration == resetGeneration, generation == resetGeneration else { return }
                let gameIDs = Set(games.map(\.id))
                let confirmed = Set(response.hiddenGameIDs).intersection(gameIDs)
                confirmedHiddenByUser[userID] = confirmed
                if pendingUpdates[userID] == nil {
                    optimisticHiddenByUser.removeValue(forKey: userID)
                    if selectedUserID == userID { hiddenGameIDs = confirmed }
                    error = nil
                }
            } catch {
                guard writeGeneration == resetGeneration, generation == resetGeneration else { return }
                if pendingUpdates[userID] == nil {
                    optimisticHiddenByUser.removeValue(forKey: userID)
                    if selectedUserID == userID { hiddenGameIDs = confirmedHiddenByUser[userID] ?? [] }
                    self.error = LibraryManagerModel.describe(error)
                }
            }
        }
        guard generation == resetGeneration else { return }
        updateWorker = nil
        if !updateOrder.isEmpty {
            updateWorker = Task { await self.flushUpdates(for: generation) }
        }
    }
}
#endif
