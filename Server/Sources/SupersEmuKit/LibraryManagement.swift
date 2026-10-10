import Foundation

// MARK: Library management (Server Mode: upload, review fixes, storage)

public struct UploadResponse: Codable, Sendable, Equatable {
    public var path: String
    public var size: Int64
    public init(path: String, size: Int64) { self.path = path; self.size = size }
}

/// Something the last scan or import couldn't settle: a review-queue copy, a file left in Incoming, or both.
public struct LibraryIssue: Codable, Sendable, Equatable, Identifiable {
    public enum Kind: String, Codable, Sendable {
        case missingFiles = "missing-files"
        case unknownSystem = "unknown-system"
        case ambiguous
        case unsupportedFormat = "unsupported-format"
        case wrongBIOS = "wrong-bios"
        case other
    }

    public var id: String
    public var kind: Kind
    public var filename: String
    public var reason: String
    /// Relative to Incoming while the source is still there.
    public var incomingPath: String?
    /// The queued copy in the review queue, if one was stored.
    public var reviewID: String?
    /// Consoles the user may assign; empty when assigning isn't safe (discs, unsupported formats).
    public var candidateSystems: [SystemID]

    public init(id: String, kind: Kind, filename: String, reason: String, incomingPath: String?, reviewID: String?, candidateSystems: [SystemID]) {
        self.id = id; self.kind = kind; self.filename = filename; self.reason = reason
        self.incomingPath = incomingPath; self.reviewID = reviewID; self.candidateSystems = candidateSystems
    }
}

public struct AssignSystemRequest: Codable, Sendable, Equatable {
    public var system: SystemID
    public init(system: SystemID) { self.system = system }
}

public struct StorageMove: Codable, Sendable, Equatable {
    public enum Phase: String, Codable, Sendable { case copying, verifying, switching, cleaning, done, failed }
    public var destination: String
    public var phase: Phase
    public var bytesDone: Int64
    public var bytesTotal: Int64
    public var error: String?
    public init(destination: String, phase: Phase, bytesDone: Int64, bytesTotal: Int64, error: String? = nil) {
        self.destination = destination; self.phase = phase; self.bytesDone = bytesDone; self.bytesTotal = bytesTotal; self.error = error
    }
    public var isRunning: Bool { phase != .done && phase != .failed }
}

public struct StorageStatus: Codable, Sendable, Equatable {
    public var dataDirectory: String
    public var libraryDirectory: String
    public var incomingDirectory: String
    /// The library lives in the data folder (never moved, or moved back).
    public var isDefault: Bool
    /// False when a moved library's drive isn't connected.
    public var available: Bool
    public var freeBytes: Int64?
    public var libraryBytes: Int64
    public var move: StorageMove?
    public init(dataDirectory: String, libraryDirectory: String, incomingDirectory: String, isDefault: Bool, available: Bool,
                freeBytes: Int64?, libraryBytes: Int64, move: StorageMove?) {
        self.dataDirectory = dataDirectory; self.libraryDirectory = libraryDirectory; self.incomingDirectory = incomingDirectory
        self.isDefault = isDefault; self.available = available; self.freeBytes = freeBytes; self.libraryBytes = libraryBytes; self.move = move
    }
}

public struct MoveLibraryRequest: Codable, Sendable, Equatable {
    /// A folder on the server; the library is copied into `<destination>/SupersEmu Library`.
    /// Pass the data folder itself to move the library back.
    public var destination: String
    public init(destination: String) { self.destination = destination }
}

extension APIClient {
    public func libraryIssues() async throws -> [LibraryIssue] { try await get("/v1/admin/library/issues") }

    public func assignSystem(issue id: String, system: SystemID) async throws -> GameSummary {
        try await send("POST", "/v1/admin/library/issues/\(id)/system", body: AssignSystemRequest(system: system))
    }

    public func deleteIssue(_ id: String) async throws { _ = try await raw("DELETE", "/v1/admin/library/issues/\(id)") }

    public func storageStatus() async throws -> StorageStatus { try await get("/v1/admin/storage") }

    public func moveLibrary(to destination: String) async throws -> StorageStatus {
        try await send("POST", "/v1/admin/storage/move", body: MoveLibraryRequest(destination: destination))
    }

    /// Streams one file into the batch's hidden staging folder in Incoming. Call `finishUpload` once every file is sent.
    public func uploadFile(_ file: URL, batch: String, relativePath: String,
                           progress: (@Sendable (Int64) -> Void)? = nil) async throws -> UploadResponse {
        var components = URLComponents()
        components.queryItems = [URLQueryItem(name: "batch", value: batch), URLQueryItem(name: "path", value: relativePath)]
        let query = (components.percentEncodedQuery ?? "").replacingOccurrences(of: "+", with: "%2B")
        var url = baseURL.appending(path: "/v1/admin/library/upload")
        if var parts = URLComponents(url: url, resolvingAgainstBaseURL: false) {
            parts.percentEncodedQuery = query
            url = parts.url ?? url
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 3600
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        let delegate = progress.map(UploadProgressDelegate.init)
        let (data, response) = try await session.upload(for: request, fromFile: file, delegate: delegate)
        try Self.check(data, response)
        return try SupersEmuJSON.decoder().decode(UploadResponse.self, from: data)
    }

    /// Moves the uploaded batch into Incoming and scans it.
    public func finishUpload(batch: String) async throws -> ImportReport {
        try await send("POST", "/v1/admin/library/upload/\(batch)/finish", body: Optional<AssignSystemRequest>.none)
    }
}

private final class UploadProgressDelegate: NSObject, URLSessionTaskDelegate, Sendable {
    let progress: @Sendable (Int64) -> Void
    init(_ progress: @escaping @Sendable (Int64) -> Void) { self.progress = progress }
    func urlSession(_ session: URLSession, task: URLSessionTask, didSendBodyData bytesSent: Int64, totalBytesSent: Int64, totalBytesExpectedToSend: Int64) {
        progress(totalBytesSent)
    }
}
