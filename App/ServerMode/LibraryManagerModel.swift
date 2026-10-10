#if os(macOS)
import AppKit
import Foundation
import Observation
import SupersEmuKit

/// Library management for whichever server Server Mode is pointed at. Everything goes through the admin API
/// (uploads included), so it works the same on the Mac mini and from another paired admin Mac.
@MainActor @Observable
final class LibraryManagerModel {
    struct ImportProgress: Equatable {
        var filesDone = 0, filesTotal = 0
        var bytesDone: Int64 = 0, bytesTotal: Int64 = 0
        var current = ""
        var scanning = false
    }

    struct UploadItem: Sendable { var url: URL; var relativePath: String; var size: Int64 }

    let server: ServerModeModel
    private(set) var progress: ImportProgress?
    private(set) var report: ImportReport?
    private(set) var issues: [LibraryIssue] = []
    private(set) var bios: [BIOSStatus] = []
    private(set) var biosGames: [GameSummary] = []
    private(set) var storage: StorageStatus?
    private(set) var error: String?

    init(server: ServerModeModel) { self.server = server }

    var canImport: Bool { progress == nil && storage?.move?.isRunning != true && storage?.available == true }

    /// Called when Server Mode switches servers: nothing from the previous one may be acted on.
    func reset() {
        report = nil
        issues = []
        bios = []
        biosGames = []
        storage = nil
        error = nil
    }

    func refreshAll() async {
        await refreshStorage()
        await refreshIssues()
        await refreshBIOS()
    }

    private func perform(_ body: (APIClient) async throws -> Void) async {
        do {
            do {
                try await body(try server.adminClient())
            } catch is URLError where !server.isLocal {
                await server.resolvePairedURL()
                try await body(try server.adminClient())
            }
            error = nil
        } catch {
            self.error = Self.describe(error)
        }
    }

    static func describe(_ error: Error) -> String {
        if case APIClientError.http(let status, let message) = error { return message ?? "The server returned \(status)." }
        if let error = error as? URLError { return error.localizedDescription }
        return "\(error)"
    }

    // MARK: Import

    func chooseAndImport(title: String = "Add Games") {
        let panel = NSOpenPanel()
        panel.title = title
        panel.prompt = "Add"
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        let urls = panel.urls
        Task { await importItems(urls) }
    }

    /// Uploads files, folders and .zip archives into one Incoming batch, then scans it.
    func importItems(_ urls: [URL]) async {
        guard canImport else { return }
        let items = await Task.detached { Self.collect(urls) }.value
        guard !items.isEmpty else { error = "There were no files to add."; return }
        progress = ImportProgress(filesTotal: items.count, bytesTotal: items.reduce(0) { $0 + $1.size })
        report = nil
        do {
            let client = try server.adminClient(timeout: 300)
            let batch = UUID().uuidString.lowercased()
            var sent: Int64 = 0
            for (index, item) in items.enumerated() {
                progress?.current = item.relativePath
                progress?.filesDone = index
                let start = sent
                _ = try await client.uploadFile(item.url, batch: batch, relativePath: item.relativePath) { bytes in
                    Task { @MainActor [weak self] in self?.progress?.bytesDone = start + bytes }
                }
                sent += item.size
                progress?.bytesDone = sent
            }
            progress?.filesDone = items.count
            progress?.scanning = true
            report = try await client.finishUpload(batch: batch)
            error = nil
        } catch {
            self.error = Self.describe(error)
        }
        progress = nil
        await refreshIssues()
        await refreshBIOS()
    }

    nonisolated static func collect(_ urls: [URL]) -> [UploadItem] {
        var items: [UploadItem] = [], used = Set<String>()
        func add(_ url: URL, _ relative: String) {
            let size = Int64((try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
            var path = relative, n = 2
            while used.contains(path.lowercased()) { path = "\(n)/\(relative)"; n += 1 }
            used.insert(path.lowercased())
            items.append(UploadItem(url: url, relativePath: path, size: size))
        }
        for url in urls {
            let name = clean(url.lastPathComponent)
            guard !name.isEmpty else { continue }
            guard (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true else { add(url, name); continue }
            let root = url.resolvingSymlinksInPath().path
            let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
                                                            options: [.skipsHiddenFiles, .skipsPackageDescendants])
            while let file = enumerator?.nextObject() as? URL {
                guard (try? file.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true else { continue }
                let parts = file.resolvingSymlinksInPath().path.dropFirst(root.count).split(separator: "/").map { clean(String($0)) }
                guard !parts.isEmpty, !parts.contains(where: \.isEmpty) else { continue }
                add(file, ([name] + parts).joined(separator: "/"))
            }
        }
        return items
    }

    nonisolated static func clean(_ name: String) -> String {
        var name = name.replacingOccurrences(of: ":", with: "_").replacingOccurrences(of: "\\", with: "_")
        while name.hasPrefix(".") { name.removeFirst() }
        return name
    }

    func scan() async {
        guard canImport else { return }
        progress = ImportProgress(scanning: true)
        report = nil
        await perform { report = try await $0.scanIncoming() }
        progress = nil
        await refreshIssues()
        await refreshBIOS()
    }

    func openIncoming() {
        guard server.isLocal, let path = storage?.incomingDirectory else { return }
        NSWorkspace.shared.open(URL(fileURLWithPath: path, isDirectory: true))
    }

    // MARK: Review Needed

    func refreshIssues() async { await perform { issues = try await $0.libraryIssues() } }

    func assign(_ issue: LibraryIssue, to system: SystemID) async {
        await perform { _ = try await $0.assignSystem(issue: issue.id, system: system) }
        await refreshIssues()
    }

    func delete(_ issue: LibraryIssue) async {
        await perform { try await $0.deleteIssue(issue.id) }
        await refreshIssues()
    }

    func revealInIncoming(_ issue: LibraryIssue) {
        guard server.isLocal, let incoming = storage?.incomingDirectory, let path = issue.incomingPath else { return }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: incoming).appendingPathComponent(path)])
    }

    // MARK: BIOS

    func refreshBIOS() async {
        await perform { client in
            bios = try await client.biosStatus()
            biosGames = try await client.library().games.filter(\.system.requiresBIOS)
        }
    }

    // MARK: Storage

    func refreshStorage() async { await perform { storage = try await $0.storageStatus() } }

    func chooseMoveDestination() {
        let panel = NSOpenPanel()
        panel.title = "Move Library"
        panel.message = "Choose a folder or drive. The library is copied into a “SupersEmu Library” folder there."
        panel.prompt = "Move Here"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { await move(to: url.path) }
    }

    func move(to path: String) async {
        await perform { storage = try await $0.moveLibrary(to: path) }
        while storage?.move?.isRunning == true {
            try? await Task.sleep(nanoseconds: 500_000_000)
            await refreshStorage()
        }
        await refreshAll()
    }
}
#endif
