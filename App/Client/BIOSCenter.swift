import Foundation
import Observation
import SupersEmuKit

/// Keeps `AppPaths.system` in sync with the server's BIOS files (`GET /v1/bios`) and tracks which
/// disc systems are ready to boot.
@MainActor
@Observable
final class BIOSCenter {
    /// Verified BIOS files in the system directory.
    private(set) var installed: [BIOSFileInfo] = []
    private(set) var isSyncing = false

    @ObservationIgnored let store: BIOSStore
    @ObservationIgnored private var syncTask: Task<Void, Never>?
    /// Bumped when a sync starts so an older disk scan can't overwrite a newer result.
    @ObservationIgnored private var generation = 0

    init(store: BIOSStore = BIOSStore(directory: AppPaths.system)) {
        self.store = store
        Task { await reloadFromDisk() }
    }

    /// True when `system` can't launch until a BIOS is synced (PlayStation, Sega CD).
    func isMissing(_ system: SystemID?) -> Bool {
        guard let system else { return false }
        return !BIOSStore.isSatisfied(system, by: installed)
    }

    /// Fetches the server's list and installs anything new. Offline, keeps whatever already verifies on disk.
    func sync(using server: ServerSession) async {
        if let syncTask { return await syncTask.value }
        let task = Task { await performSync(client: server.client()) }
        syncTask = task
        await task.value
        syncTask = nil
    }

    private func performSync(client: APIClient?) async {
        generation += 1
        isSyncing = true
        defer { isSyncing = false }
        let store = store
        if let client {
            do {
                let list: [BIOSFileInfo] = try await client.get("/v1/bios")
                let result = try await store.sync(list) { bios in try await client.raw("GET", "/v1/bios/\(bios.id)") }
                installed = result.installed
                return
            } catch {
                // Unreachable server (or one without BIOS routes yet): fall back to what's on disk.
            }
        }
        await reloadFromDisk()
    }

    private func reloadFromDisk() async {
        let store = store
        let generation = generation
        let found = await Task.detached(priority: .userInitiated) { store.installed() }.value
        guard generation == self.generation else { return }
        installed = found
    }
}

extension SystemID {
    /// "Needs PlayStation BIOS" / "Needs Sega CD BIOS".
    var missingBIOSMessage: String { "Needs \(displayName) BIOS" }
}
