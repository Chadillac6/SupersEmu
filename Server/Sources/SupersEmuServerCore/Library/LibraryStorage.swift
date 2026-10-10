import Foundation
import SupersEmuKit

/// The library root shared by every copy of `ServerPaths`, so Move Library can switch it while the server runs.
public final class LibraryStorage: @unchecked Sendable {
    struct Config: Codable { var libraryPath: String }

    private let lock = NSLock()
    private var _root: URL
    private var _isDefault = true
    private var _move: StorageMove?
    private var activeUploads: [String: Int] = [:]
    private var batchOwners: [String: String] = [:]
    private var finishing = Set<String>()

    init(root: URL) { _root = root }

    public var root: URL { lock.withLock { _root } }
    public var isDefault: Bool { lock.withLock { _isDefault } }
    public var move: StorageMove? {
        get { lock.withLock { _move } }
        set { lock.withLock { _move = newValue } }
    }

    /// A moved library on an unplugged drive is unavailable until the drive comes back; nothing is created in its place.
    public var isAvailable: Bool {
        let (root, isDefault) = lock.withLock { (_root, _isDefault) }
        if isDefault { return true }
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: root.path, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    func load(config: URL, dataRoot: URL) throws {
        guard let data = try? Data(contentsOf: config) else { return }
        let decoded = try JSONDecoder().decode(Config.self, from: data)
        let url = URL(fileURLWithPath: decoded.libraryPath, isDirectory: true).standardizedFileURL
        lock.withLock {
            _root = url
            _isDefault = url.path == dataRoot.standardizedFileURL.path
        }
    }

    func switchTo(_ url: URL, config: URL, dataRoot: URL) throws {
        let url = url.standardizedFileURL
        let isDefault = url.path == dataRoot.standardizedFileURL.path
        if isDefault {
            if FileManager.default.fileExists(atPath: config.path) { try FileManager.default.removeItem(at: config) }
        } else {
            let data = try JSONEncoder().encode(Config(libraryPath: url.path))
            try data.write(to: config, options: .atomic)
        }
        lock.withLock {
            _root = url
            _isDefault = isDefault
        }
    }

    enum GateError: Error { case moving, batchBusy, notOwner, uploadsActive }

    /// Uploads, batch finishes and Move Library exclude each other, and a batch belongs to the credential that started it.
    func beginUpload(batch: String, owner: String) throws {
        try lock.withLock {
            if _move?.isRunning == true { throw GateError.moving }
            if finishing.contains(batch) { throw GateError.batchBusy }
            if let existing = batchOwners[batch], existing != owner { throw GateError.notOwner }
            batchOwners[batch] = owner
            activeUploads[batch, default: 0] += 1
        }
    }

    func endUpload(batch: String) {
        lock.withLock {
            let count = (activeUploads[batch] ?? 1) - 1
            activeUploads[batch] = count > 0 ? count : nil
        }
    }

    func beginFinish(batch: String, owner: String) throws {
        try lock.withLock {
            guard batchOwners[batch] == owner else { throw GateError.notOwner }
            if activeUploads[batch] != nil { throw GateError.uploadsActive }
            if !finishing.insert(batch).inserted { throw GateError.batchBusy }
        }
    }

    func endFinish(batch: String, finished: Bool) {
        lock.withLock {
            finishing.remove(batch)
            if finished { batchOwners[batch] = nil }
        }
    }

    func beginMove(_ move: StorageMove) throws {
        try lock.withLock {
            if _move?.isRunning == true { throw GateError.moving }
            if !activeUploads.isEmpty || !finishing.isEmpty { throw GateError.uploadsActive }
            _move = move
        }
    }

    /// The boot daemon runs as root; let admin accounts drop files into Incoming from Finder.
    func shareIncomingWithAdmins(_ incoming: URL) {
        guard getuid() == 0, FileManager.default.fileExists(atPath: incoming.path) else { return }
        chown(incoming.path, 0, 80)
        chmod(incoming.path, 0o775)
    }
}
