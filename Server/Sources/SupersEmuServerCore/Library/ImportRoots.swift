import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// Which server folders `importPaths` (and `scanIncoming`) may read. Paths are compared after resolving symlinks,
/// so a link can't point an import somewhere else. `Incoming` is always allowed (unless it is itself a symlink);
/// other folders only when the server was started with `--import-root`. The server's data folder, the library's
/// own folders, the backup destination, system folders and hidden folders are never readable.
struct ImportRoots {
    enum Check: Equatable {
        case allowed(URL)
        case refused(String)
    }

    static let systemFolders = ["/System", "/usr", "/bin", "/sbin", "/dev", "/etc", "/private/etc", "/var/root",
                                "/private/var/root", "/var/db", "/private/var/db", "/Library/Keychains"]

    /// Nil when `Incoming` doesn't resolve to `<library root>/Incoming` (e.g. it was replaced by a symlink).
    let incoming: String?
    let allowed: [String]
    let denied: [String]

    init(paths: ServerPaths, alsoDenied: [URL] = []) {
        let incoming = Self.canonical(paths.incoming)
        self.incoming = incoming == Self.canonical(paths.libraryRoot) + "/Incoming" ? incoming : nil
        allowed = paths.importRoots.map(Self.canonical)
        denied = ([paths.root, paths.libraryRoot] + alsoDenied).map(Self.canonical)
            + Self.systemFolders.map { Self.canonical(URL(fileURLWithPath: $0)) }
    }

    /// Why `url` can't be imported, or nil when it can.
    func violation(_ url: URL) -> String? {
        if case .refused(let reason) = check(url) { return reason }
        return nil
    }

    /// The real path to read `url` from, or why it can't be imported.
    func check(_ url: URL) -> Check {
        // Containment is checked before existence, so paths outside the roots can't be probed.
        if let reason = refusal(Self.canonical(url)) { return .refused(reason) }
        guard let resolved = Self.resolved(url) else { return .refused("not found") }
        if let reason = refusal(resolved) { return .refused(reason) }
        return .allowed(URL(fileURLWithPath: resolved))
    }

    private func refusal(_ path: String) -> String? {
        let root: String
        let deniedHere: [String]
        if let incoming, Self.contains(incoming, path) {
            // Incoming sits inside the library (and by default the data) folder; every other protected folder applies.
            root = incoming
            deniedHere = denied.filter { !Self.contains($0, incoming) }
        } else if let configured = allowed.filter({ Self.contains($0, path) }).max(by: { $0.count < $1.count }) {
            root = configured
            deniedHere = denied
        } else {
            return "not inside Incoming or a folder the server was started with --import-root for"
        }
        if deniedHere.contains(where: { Self.contains($0.lowercased(), path.lowercased()) }) {
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

    /// The real path with every symlink resolved, or nil if it doesn't exist or can't be resolved.
    static func resolved(_ url: URL) -> String? {
        guard let resolved = realpath(url.standardizedFileURL.path, nil) else { return nil }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    /// Like `resolved`, but for a path that doesn't exist yet (a configured root, an unknown request) its deepest
    /// resolvable ancestor is resolved and the rest appended. Only used for roots and the pre-existence check.
    static func canonical(_ url: URL) -> String {
        if let resolved = resolved(url) { return resolved }
        let path = url.standardizedFileURL.path
        let parent = (path as NSString).deletingLastPathComponent
        guard !parent.isEmpty, parent != path else { return path }
        let base = canonical(URL(fileURLWithPath: parent))
        return (base as NSString).appendingPathComponent((path as NSString).lastPathComponent)
    }
}
