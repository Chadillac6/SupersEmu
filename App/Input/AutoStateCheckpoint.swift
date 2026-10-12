import Foundation

enum AutoStateCheckpoint {
    static func isPending(_ autoState: URL, fileManager: FileManager = .default) -> Bool {
        fileManager.fileExists(atPath: pendingURL(for: autoState).path)
    }

    static func markPending(_ autoState: URL, fileManager: FileManager = .default) throws {
        try Data().write(to: pendingURL(for: autoState), options: .atomic)
    }

    static func moveAside(_ autoState: URL, fileManager: FileManager = .default) throws {
        guard fileManager.fileExists(atPath: autoState.path) else { return }
        let backup = URL(fileURLWithPath: autoState.path + ".before-start-over")
        if fileManager.fileExists(atPath: backup.path) {
            try fileManager.removeItem(at: backup)
        }
        try fileManager.moveItem(at: autoState, to: backup)
    }

    static func clearPending(_ autoState: URL, fileManager: FileManager = .default) throws {
        let pending = pendingURL(for: autoState)
        if fileManager.fileExists(atPath: pending.path) {
            try fileManager.removeItem(at: pending)
        }
    }

    private static func pendingURL(for autoState: URL) -> URL {
        URL(fileURLWithPath: autoState.path + ".start-over-pending")
    }
}
