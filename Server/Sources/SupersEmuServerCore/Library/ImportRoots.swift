import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// Which server folders `importPaths` (and `scanIncoming`) may read. Paths are compared after resolving symlinks,
/// so a link can't point an import somewhere else. `Incoming` is always allowed; other folders only when the
/// server was started with `--import-root`. The server's data folder, the library's own folders, the backup
/// destination and system folders are never readable, even inside an import root.
struct ImportRoots {
    static let systemFolders = ["/System", "/usr", "/bin", "/sbin", "/dev", "/etc", "/private/etc", "/var/root",
                                "/private/var/root", "/var/db", "/private/var/db", "/Library/Keychains"]

    let incoming: String
    let allowed: [String]
    let denied: [String]

    init(paths: ServerPaths, alsoDenied: [URL] = []) {
        incoming = Self.canonical(paths.incoming)
        allowed = paths.importRoots.map(Self.canonical)
        denied = ([paths.root, paths.libraryRoot] + alsoDenied).map(Self.canonical)
            + Self.systemFolders.map { Self.canonical(URL(fileURLWithPath: $0)) }
    }

    /// Why `url` can't be imported, or nil when it can.
    func violation(_ url: URL) -> String? {
        let path = Self.canonical(url)
        if Self.contains(incoming, path) { return nil }
        guard let root = allowed.filter({ Self.contains($0, path) }).max(by: { $0.count < $1.count }) else {
            return "not inside Incoming or a folder the server was started with --import-root for"
        }
        if denied.contains(where: { Self.contains($0.lowercased(), path.lowercased()) }) {
            return "inside the server's data, library, backup or system folders"
        }
        if path.dropFirst(root.count).split(separator: "/").contains(where: { $0.hasPrefix(".") }) {
            return "hidden files and folders can't be imported"
        }
        return nil
    }

    static func contains(_ root: String, _ path: String) -> Bool {
        root == "/" || path == root || path.hasPrefix(root + "/")
    }

    /// The real path with every symlink resolved. For a path that doesn't exist yet, its deepest existing ancestor
    /// is resolved and the rest appended.
    static func canonical(_ url: URL) -> String {
        let path = url.standardizedFileURL.path
        if let resolved = realpath(path, nil) {
            defer { free(resolved) }
            return String(cString: resolved)
        }
        let parent = (path as NSString).deletingLastPathComponent
        guard !parent.isEmpty, parent != path else { return path }
        let base = canonical(URL(fileURLWithPath: parent))
        return (base as NSString).appendingPathComponent((path as NSString).lastPathComponent)
    }
}
