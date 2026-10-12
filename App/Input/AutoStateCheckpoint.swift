import Foundation

enum AutoStateCheckpoint {
    static func moveAside(_ autoState: URL, fileManager: FileManager = .default) throws {
        guard fileManager.fileExists(atPath: autoState.path) else { return }
        let backup = URL(fileURLWithPath: autoState.path + ".before-start-over")
        if fileManager.fileExists(atPath: backup.path) {
            try fileManager.removeItem(at: backup)
        }
        try fileManager.moveItem(at: autoState, to: backup)
    }
}
