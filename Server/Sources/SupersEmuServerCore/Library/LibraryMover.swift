import CryptoKit
import Foundation
import SupersEmuKit

enum StorageMoveError: Error, Equatable {
    case busy, unavailable
    case invalid(String)
    case verifyFailed(String)
}

/// Move Library: copy, verify every byte, switch `storage.json`, then remove the old copy. Nothing is removed until the switch.
extension LibraryImporter {
    static let libraryFolderName = "SupersEmu Library"
    static let movableFolders = ["games", "bios", "artwork", "Incoming", "Imported"]
    static let moveFreeSpaceMargin: Int64 = 256 << 20

    public func storageStatus() -> StorageStatus {
        let paths = store.paths, available = paths.storage.isAvailable
        return StorageStatus(
            dataDirectory: paths.root.path, libraryDirectory: paths.libraryRoot.path, incomingDirectory: paths.incoming.path,
            isDefault: paths.storage.isDefault, available: available,
            freeBytes: available ? ServerStore.freeBytes(at: paths.libraryRoot) : nil,
            libraryBytes: available ? Self.libraryFiles(at: paths.libraryRoot).reduce(0) { $0 + $1.size } : 0,
            move: paths.storage.move)
    }

    /// Files Move Library carries over. Import staging and unfinished upload batches stay behind.
    static func libraryFiles(at root: URL) -> [(relative: String, size: Int64)] {
        let fm = FileManager.default
        let rootPath = root.resolvingSymlinksInPath().standardizedFileURL.path
        var files: [(String, Int64)] = []
        for folder in movableFolders {
            guard let enumerator = fm.enumerator(at: root.appendingPathComponent(folder, isDirectory: true),
                                                 includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey, .fileSizeKey]) else { continue }
            for case let url as URL in enumerator {
                let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isDirectoryKey, .fileSizeKey])
                if values?.isDirectory == true, [".staging", uploadStagingFolder].contains(url.lastPathComponent) {
                    enumerator.skipDescendants()
                    continue
                }
                guard values?.isRegularFile == true else { continue }
                let path = url.resolvingSymlinksInPath().standardizedFileURL.path
                guard path.hasPrefix(rootPath + "/") else { continue }
                files.append((String(path.dropFirst(rootPath.count + 1)), Int64(values?.fileSize ?? 0)))
            }
        }
        return files
    }

    public func startMove(to destination: String, auth: AuthContext?) throws -> StorageStatus {
        let paths = store.paths, storage = paths.storage, fm = FileManager.default
        guard storage.move?.isRunning != true else { throw StorageMoveError.busy }
        guard storage.isAvailable else { throw StorageMoveError.unavailable }
        guard destination.hasPrefix("/") else { throw StorageMoveError.invalid("Choose a folder on the server.") }
        let chosen = URL(fileURLWithPath: destination, isDirectory: true).resolvingSymlinksInPath().standardizedFileURL
        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: chosen.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw StorageMoveError.invalid("\(chosen.path) doesn't exist or isn't connected.")
        }
        guard fm.isWritableFile(atPath: chosen.path) else { throw StorageMoveError.invalid("The server can't write to \(chosen.path).") }
        let dataRoot = paths.root.resolvingSymlinksInPath().standardizedFileURL
        let current = paths.libraryRoot.resolvingSymlinksInPath().standardizedFileURL
        let toDataRoot = chosen.path == dataRoot.path
        let target = toDataRoot ? dataRoot : chosen.appendingPathComponent(Self.libraryFolderName, isDirectory: true)
        guard target.path != current.path else { throw StorageMoveError.invalid("The library is already there.") }
        guard toDataRoot || !(target.path + "/").hasPrefix(current.path + "/") && !current.path.hasPrefix(target.path + "/") else {
            throw StorageMoveError.invalid("Choose a folder outside the current library.")
        }
        if toDataRoot {
            for folder in Self.movableFolders where !((try? fm.contentsOfDirectory(atPath: target.appendingPathComponent(folder).path)) ?? []).isEmpty {
                throw StorageMoveError.invalid("\(target.appendingPathComponent(folder).path) already has files in it.")
            }
        } else if let contents = try? fm.contentsOfDirectory(atPath: target.path), !contents.allSatisfy({ $0 == ".DS_Store" }) {
            throw StorageMoveError.invalid("\(target.path) already exists and isn't empty.")
        }
        let files = Self.libraryFiles(at: current)
        let total = files.reduce(0) { $0 + $1.size }
        if let free = ServerStore.freeBytes(at: chosen), free < total + Self.moveFreeSpaceMargin {
            throw StorageMoveError.invalid("Not enough free space on that drive: the library needs \(Self.byteString(total)), \(Self.byteString(free)) is free.")
        }
        do {
            try storage.beginMove(StorageMove(destination: target.path, phase: .copying, bytesDone: 0, bytesTotal: total))
        } catch LibraryStorage.GateError.uploadsActive {
            throw StorageMoveError.invalid("Games are being added right now. Try again when that's finished.")
        } catch {
            throw StorageMoveError.busy
        }
        try store.audit(auth, action: "storage.move.start", detail: "\(current.path) -> \(target.path)")
        Task.detached { [self] in
            try? await run { importer in
                // Snapshot inside the serial queue so imports queued before the move are included.
                let files = Self.libraryFiles(at: current)
                storage.move?.bytesTotal = files.reduce(0) { $0 + $1.size }
                try importer.moveLibrary(from: current, to: target, files: files, toDataRoot: toDataRoot)
            }
            if let move = storage.move { try? store.audit(auth, action: "storage.move.\(move.phase.rawValue)", detail: move.error ?? target.path) }
        }
        return storageStatus()
    }

    func moveLibrary(from source: URL, to target: URL, files: [(relative: String, size: Int64)], toDataRoot: Bool) throws {
        let fm = FileManager.default, paths = store.paths, storage = paths.storage
        let total = files.reduce(0) { $0 + $1.size }
        func update(_ phase: StorageMove.Phase, _ done: Int64, _ error: String? = nil) {
            storage.move = StorageMove(destination: target.path, phase: phase, bytesDone: done, bytesTotal: total, error: error)
        }
        func rollBack() {
            if toDataRoot {
                for folder in Self.movableFolders { try? fm.removeItem(at: target.appendingPathComponent(folder)) }
            } else {
                try? fm.removeItem(at: target)
            }
        }
        do {
            try fm.createDirectory(at: target, withIntermediateDirectories: true)
            var done: Int64 = 0
            for file in files {
                let destination = target.appendingPathComponent(file.relative)
                try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                try fm.copyItem(at: source.appendingPathComponent(file.relative), to: destination)
                done += file.size
                update(.copying, done)
            }
            for folder in ["games", "artwork", "Incoming"] {
                try fm.createDirectory(at: target.appendingPathComponent(folder, isDirectory: true), withIntermediateDirectories: true)
            }
            update(.verifying, 0)
            done = 0
            for file in files {
                let original = source.appendingPathComponent(file.relative), copy = target.appendingPathComponent(file.relative)
                let copySize = (try? copy.resourceValues(forKeys: [.fileSizeKey]))?.fileSize.map(Int64.init)
                guard copySize == file.size, try Self.sha256(of: original) == Self.sha256(of: copy) else {
                    throw StorageMoveError.verifyFailed(file.relative)
                }
                done += file.size
                update(.verifying, done)
            }
            update(.switching, total)
            try storage.switchTo(target, config: paths.storageConfig, dataRoot: paths.root)
        } catch {
            rollBack()
            let message: String
            if case StorageMoveError.verifyFailed(let file) = error { message = "The copy of \(file) didn't match; nothing was changed." }
            else { message = "\(error.localizedDescription) Nothing was changed." }
            update(.failed, 0, message)
            throw error
        }
        update(.cleaning, total)
        storage.shareIncomingWithAdmins(paths.incoming)
        for folder in Self.movableFolders { try? fm.removeItem(at: source.appendingPathComponent(folder)) }
        if source.path != paths.root.resolvingSymlinksInPath().standardizedFileURL.path,
           ((try? fm.contentsOfDirectory(atPath: source.path)) ?? []).allSatisfy({ $0 == ".DS_Store" }) {
            try? fm.removeItem(at: source)
        }
        update(.done, total)
    }

    static func sha256(of url: URL) throws -> String {
        try Hashing.sha256Hex(ofFileAt: url)
    }

    static func byteString(_ bytes: Int64) -> String { ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file) }
}
