import Foundation
import SupersEmuKit

/// The library root shared by every copy of `ServerPaths`, so Move Library can switch it while the server runs.
public final class LibraryStorage: @unchecked Sendable {
    struct Config: Codable { var libraryPath: String }

    private let lock = NSLock()
    private var _root: URL
    private var _isDefault = true
    private var _move: StorageMove?

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
            try? FileManager.default.removeItem(at: config)
        } else {
            let data = try JSONEncoder().encode(Config(libraryPath: url.path))
            try data.write(to: config, options: .atomic)
        }
        lock.withLock {
            _root = url
            _isDefault = isDefault
        }
    }

    /// The boot daemon runs as root; let admin accounts drop files into Incoming from Finder.
    func shareIncomingWithAdmins(_ incoming: URL) {
        guard getuid() == 0, FileManager.default.fileExists(atPath: incoming.path) else { return }
        chown(incoming.path, 0, 80)
        chmod(incoming.path, 0o775)
    }
}
