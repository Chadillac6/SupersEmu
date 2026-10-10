import Foundation
import Hummingbird
import SupersEmuKit

/// Server Mode library management: uploads from any paired admin Mac, Review Needed fixes, and storage.
func registerAdminLibraryManagementRoutes(_ group: RouterGroup<SERequestContext>, store: ServerStore, metadata: MetadataService? = nil) {
    let importer = LibraryImporter(store: store)

    group.post("admin/library/upload") { request, context -> Response in
        let auth = try requireLibraryAdmin(context)
        try requireLibraryAvailable(store)
        let query = request.uri.queryParameters
        guard let batch = query["batch"].map(String.init), LibraryImporter.isSafeBatch(batch) else {
            throw HTTPError(.badRequest, message: "batch must be 1-64 letters, digits or dashes")
        }
        guard let path = query["path"].map(String.init), let parts = LibraryImporter.safeUploadPath(path),
              let destination = importer.uploadDestination(batch: batch, parts: parts) else {
            throw HTTPError(.badRequest, message: "path must be a relative path of visible names")
        }
        let staged = FileManager.default.fileExists(atPath: importer.uploadStagingRoot.appendingPathComponent(batch, isDirectory: true).path)
        try uploadGate { try store.paths.storage.beginUpload(batch: batch, owner: auth.uploadOwner, stagedOnDisk: staged) }
        defer { store.paths.storage.endUpload(batch: batch) }
        if let length = request.headers[.contentLength].flatMap({ Int64($0) }) {
            try checkUploadSize(length, store: store)
        }
        let size = try await receiveUpload(request.body, to: destination, staging: importer.uploadStagingRoot, store: store)
        return try LibraryHTTP.json(UploadResponse(path: parts.joined(separator: "/"), size: size))
    }

    group.post("admin/library/upload/{batch}/finish") { _, context -> Response in
        let auth = try requireLibraryAdmin(context)
        try requireLibraryAvailable(store)
        let batch = try context.parameters.require("batch")
        guard LibraryImporter.isSafeBatch(batch) else { throw HTTPError(.badRequest, message: "invalid batch") }
        try uploadGate { try store.paths.storage.beginFinish(batch: batch, owner: auth.uploadOwner) }
        var finished = false
        defer { store.paths.storage.endFinish(batch: batch, finished: finished) }
        try await issueErrors { try await importer.finishUpload(batch: batch) }
        finished = true
        let report = try await importer.scanIncoming(auth: auth)
        metadata?.enqueue()
        return try LibraryHTTP.json(report)
    }

    group.get("admin/library/issues") { _, context -> Response in
        _ = try requireLibraryAdmin(context)
        return try LibraryHTTP.json(try importer.issues())
    }

    group.post("admin/library/issues/{id}/system") { request, context -> Response in
        let auth = try requireLibraryAdmin(context)
        try requireLibraryAvailable(store)
        let id = try context.parameters.require("id")
        let body = try await request.decode(as: AssignSystemRequest.self, context: context)
        let result = try await issueErrors { try await importer.assignSystem(issue: id, system: body.system, auth: auth) }
        metadata?.enqueue()
        return try LibraryHTTP.json(result)
    }

    group.delete("admin/library/issues/{id}") { _, context -> HTTPResponse.Status in
        let auth = try requireLibraryAdmin(context)
        try requireLibraryAvailable(store)
        let id = try context.parameters.require("id")
        try await issueErrors { try await importer.deleteIssue(id, auth: auth) }
        return .noContent
    }

    group.get("admin/storage") { _, context -> Response in
        _ = try requireLibraryAdmin(context)
        return try LibraryHTTP.json(importer.storageStatus())
    }

    group.post("admin/storage/move") { request, context -> Response in
        let auth = try requireLibraryAdmin(context)
        let body = try await request.decode(as: MoveLibraryRequest.self, context: context)
        do {
            var response = try LibraryHTTP.json(try importer.startMove(to: body.destination, auth: auth))
            response.status = .accepted
            return response
        } catch StorageMoveError.busy {
            throw HTTPError(.conflict, message: "The library is already being moved")
        } catch StorageMoveError.unavailable {
            throw HTTPError(.serviceUnavailable, message: "The library drive isn't connected")
        } catch StorageMoveError.invalid(let message) {
            throw HTTPError(.badRequest, message: message)
        }
    }
}

/// Imports and fixes need the library folder; a moved library's drive may be unplugged, and a move must not race them.
func requireLibraryAvailable(_ store: ServerStore) throws {
    guard store.paths.storage.isAvailable else {
        throw HTTPError(.serviceUnavailable, message: "The library drive isn't connected (\(store.paths.libraryRoot.path))")
    }
    if store.paths.storage.move?.isRunning == true { throw HTTPError(.conflict, message: "The library is being moved") }
    try store.paths.createLibraryDirectories()
}

private extension AuthContext {
    var uploadOwner: String {
        switch credential {
        case .device(let id): return "device:" + id
        case .apiToken(let id, _): return "token:" + id
        }
    }
}

private func uploadGate(_ body: () throws -> Void) throws {
    do {
        try body()
    } catch let error as LibraryStorage.GateError {
        switch error {
        case .moving: throw HTTPError(.conflict, message: "The library is being moved")
        case .batchBusy: throw HTTPError(.conflict, message: "That upload batch is being finished")
        case .notOwner: throw HTTPError(.notFound, message: "No such upload batch")
        case .uploadsActive: throw HTTPError(.conflict, message: "Files in this batch are still uploading")
        }
    }
}

private func checkUploadSize(_ size: Int64, store: ServerStore) throws {
    guard size <= LibraryImporter.maxUploadFileSize else {
        throw HTTPError(.contentTooLarge, message: "Files over \(LibraryImporter.byteString(LibraryImporter.maxUploadFileSize)) can't be uploaded")
    }
    if let free = ServerStore.freeBytes(at: store.paths.libraryRoot), size + LibraryImporter.uploadFreeSpaceMargin > free {
        throw HTTPError(.init(code: 507, reasonPhrase: "Insufficient Storage"), message: "Not enough free space on the server")
    }
}

/// Streams into a hidden partial file and renames it into the batch only once complete.
private func receiveUpload(_ body: RequestBody, to destination: URL, staging: URL, store: ServerStore) async throws -> Int64 {
    let fm = FileManager.default
    try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
    guard !fm.fileExists(atPath: destination.path) else { throw HTTPError(.conflict, message: "That file was already uploaded in this batch") }
    let partial = staging.appendingPathComponent(".partial-\(UUID().uuidString)")
    guard fm.createFile(atPath: partial.path, contents: nil) else { throw HTTPError(.internalServerError, message: "Could not write the upload") }
    var size: Int64 = 0
    do {
        let handle = try FileHandle(forWritingTo: partial)
        defer { try? handle.close() }
        for try await buffer in body {
            size += Int64(buffer.readableBytes)
            try checkUploadSize(size, store: store)
            try handle.write(contentsOf: buffer.readableBytesView)
        }
        try handle.close()
        try fm.moveItem(at: partial, to: destination)
    } catch {
        try? fm.removeItem(at: partial)
        throw error
    }
    return size
}

private func issueErrors<T>(_ body: () async throws -> T) async throws -> T {
    do {
        return try await body()
    } catch LibraryIssueError.notFound {
        throw HTTPError(.notFound, message: "Not found")
    } catch LibraryIssueError.notAssignable {
        throw HTTPError(.badRequest, message: "A console can't be picked for this item")
    } catch LibraryIssueError.conflict {
        throw HTTPError(.conflict, message: "That upload batch was already finished")
    }
}
