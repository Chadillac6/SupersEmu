import CryptoKit
import Foundation

// Track: client. Device-side download cache shared by the apps (and usable by the CLI).
// Layout: <root>/<gameID>/<filename> plus <root>/<gameID>/manifest.json once every file is verified.

/// A game whose files are all downloaded and verified on this device.
public struct CachedGame: Codable, Sendable, Equatable {
    public var detail: GameDetail
    public var downloadedAt: Date
    public init(detail: GameDetail, downloadedAt: Date) { self.detail = detail; self.downloadedAt = downloadedAt }
}

public struct GameCache: Sendable {
    public let root: URL
    public init(root: URL) { self.root = root }

    public func directory(for gameID: String) -> URL { root.appendingPathComponent(gameID, isDirectory: true) }
    func manifestURL(for gameID: String) -> URL { directory(for: gameID).appendingPathComponent("manifest.json") }
    public func partialURL(gameID: String, file: GameFileInfo) -> URL {
        directory(for: gameID).appendingPathComponent(".\(file.id).part")
    }
    public func fileURL(gameID: String, file: GameFileInfo) -> URL {
        directory(for: gameID).appendingPathComponent(Self.safeFilename(file.filename, fallback: file.id))
    }

    /// Game and file IDs come from the server; only accept plain path components so nothing escapes the cache.
    public static func isSafeID(_ id: String) -> Bool {
        !id.isEmpty && id != "." && id != ".." && !id.contains("/") && !id.contains("\\") && !id.contains(":") && !id.hasPrefix(".")
    }

    static func isSHA256(_ id: String) -> Bool {
        id.count == 64 && id.allSatisfy(\.isHexDigit)
    }

    public func cachedGame(_ gameID: String) -> CachedGame? {
        guard Self.isSafeID(gameID), let data = try? Data(contentsOf: manifestURL(for: gameID)),
              let cached = try? SupersEmuJSON.decoder().decode(CachedGame.self, from: data) else { return nil }
        let complete = cached.detail.files.allSatisfy { file in
            let url = fileURL(gameID: gameID, file: file)
            guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
                  (attributes[.size] as? NSNumber)?.int64Value == file.size else { return false }
            return Self.verifiedSHA256(of: url, size: file.size, modified: attributes[.modificationDate] as? Date) == file.id.lowercased()
        }
        return complete ? cached : nil
    }

    /// Hashes each cached file once per (size, mtime) so launches re-verify bytes without rehashing every refresh.
    static func verifiedSHA256(of url: URL, size: Int64, modified: Date?) -> String? {
        if let hit = hashMemo.lookup(url.path, size: size, modified: modified) { return hit }
        guard let sha = try? GameDownloader.sha256(of: url) else { return nil }
        hashMemo.store(url.path, size: size, modified: modified, sha256: sha)
        return sha
    }

    private static let hashMemo = HashMemo()

    private final class HashMemo: @unchecked Sendable {
        private struct Entry { var size: Int64; var modified: Date?; var sha256: String }
        private let lock = NSLock()
        private var entries: [String: Entry] = [:]

        func lookup(_ path: String, size: Int64, modified: Date?) -> String? {
            lock.withLock {
                guard let entry = entries[path], entry.size == size, entry.modified == modified else { return nil }
                return entry.sha256
            }
        }

        func store(_ path: String, size: Int64, modified: Date?, sha256: String) {
            lock.withLock { entries[path] = Entry(size: size, modified: modified, sha256: sha256) }
        }
    }

    public func cachedGames() -> [CachedGame] {
        let ids = (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
        return ids.compactMap(cachedGame).sorted { $0.detail.game.title.localizedStandardCompare($1.detail.game.title) == .orderedAscending }
    }

    /// The file a core should load: the playlist/cue for multi-file games, otherwise the ROM or first disc.
    public func launchFileURL(for cached: CachedGame) -> URL? {
        let files = cached.detail.files
        let order: [GameFileRole] = [.m3u, .cue, .rom, .disc]
        guard let file = order.lazy.compactMap({ role in files.first { $0.role == role } }).first ?? files.first else { return nil }
        return fileURL(gameID: cached.detail.game.id, file: file)
    }

    /// Bytes already on disk for `gameID`, including partial downloads.
    public func bytesOnDisk(for gameID: String) -> Int64 {
        let dir = directory(for: gameID)
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        return names.reduce(0) { total, name in
            let size = (try? FileManager.default.attributesOfItem(atPath: dir.appendingPathComponent(name).path)[.size] as? NSNumber)?.int64Value
            return total + (size ?? 0)
        }
    }

    public func remove(_ gameID: String) throws {
        let dir = directory(for: gameID)
        if FileManager.default.fileExists(atPath: dir.path) { try FileManager.default.removeItem(at: dir) }
    }

    /// Every file needs a SHA-256 ID and its own destination: no duplicates (APFS is case-insensitive),
    /// no file that is also another file's parent directory, and nothing that shadows manifest.json.
    func validateLayout(_ files: [GameFileInfo]) throws {
        var paths = Set<String>()
        for file in files {
            let path = Self.safeFilename(file.filename, fallback: file.id).lowercased()
            guard Self.isSHA256(file.id), path != "manifest.json", paths.insert(path).inserted else {
                throw DownloadError.invalidFile(file.filename)
            }
        }
        for path in paths where paths.contains(where: { $0.hasPrefix(path + "/") }) {
            throw DownloadError.invalidFile(path)
        }
    }

    func writeManifest(_ cached: CachedGame) throws {
        try SupersEmuJSON.encoder().encode(cached).write(to: manifestURL(for: cached.detail.game.id), options: .atomic)
    }

    /// Keeps the server's relative layout (e.g. "Disc 1/Track 01.bin") so cue/m3u references still resolve,
    /// but drops anything that could leave the game's directory.
    static func safeFilename(_ name: String, fallback: String) -> String {
        let parts = name.split(whereSeparator: { $0 == "/" || $0 == "\\" })
            .map { $0.replacingOccurrences(of: ":", with: "_") }
            .filter { !$0.isEmpty && $0 != "." && $0 != ".." }
        guard !parts.isEmpty, !parts.contains(where: { $0.hasPrefix(".") }) else { return fallback }
        return parts.joined(separator: "/")
    }
}

public struct DownloadProgress: Sendable, Equatable {
    public var receivedBytes: Int64
    public var totalBytes: Int64
    public var fraction: Double { totalBytes > 0 ? min(1, Double(receivedBytes) / Double(totalBytes)) : 0 }
    public init(receivedBytes: Int64, totalBytes: Int64) { self.receivedBytes = receivedBytes; self.totalBytes = totalBytes }
}

public enum DownloadError: Error, Equatable, CustomStringConvertible {
    case http(status: Int)
    case checksumMismatch(filename: String)
    case unexpectedRange
    case noFiles
    case invalidFile(String)

    public var description: String {
        switch self {
        case .http(let status): return "Download failed (HTTP \(status))"
        case .checksumMismatch(let filename): return "\(filename) didn't match the server's checksum, so it was discarded"
        case .unexpectedRange: return "The server sent an unexpected byte range"
        case .noFiles: return "This game has no files on the server"
        case .invalidFile(let name): return "The server listed an invalid file (\(name))"
        }
    }
}

/// Downloads every file of a game into the `GameCache`, resuming partial files with HTTP Range and
/// verifying each file's SHA-256 (its `GameFileInfo.id`) before it becomes playable.
public final class GameDownloader: Sendable {
    public typealias TrustHandler = @Sendable (URLAuthenticationChallenge) -> (URLSession.AuthChallengeDisposition, URLCredential?)

    let client: APIClient
    let cache: GameCache
    let session: URLSession
    let delegate: StreamingDelegate

    public init(client: APIClient, cache: GameCache, configuration: URLSessionConfiguration = .default, trust: TrustHandler? = nil) {
        self.client = client
        self.cache = cache
        let delegate = StreamingDelegate(trust: trust)
        self.delegate = delegate
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        self.session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: queue)
    }

    deinit { session.finishTasksAndInvalidate() }

    @discardableResult
    public func download(gameID: String, progress: @escaping @Sendable (DownloadProgress) -> Void = { _ in }) async throws -> CachedGame {
        let detail = try await client.gameDetail(gameID)
        return try await download(detail, progress: progress)
    }

    @discardableResult
    public func download(_ detail: GameDetail, progress: @escaping @Sendable (DownloadProgress) -> Void = { _ in }) async throws -> CachedGame {
        let gameID = detail.game.id
        guard !detail.files.isEmpty else { throw DownloadError.noFiles }
        guard GameCache.isSafeID(gameID) else { throw DownloadError.invalidFile(gameID) }
        try cache.validateLayout(detail.files)
        try FileManager.default.createDirectory(at: cache.directory(for: gameID), withIntermediateDirectories: true)
        let total = detail.files.reduce(0) { $0 + $1.size }
        var finished: Int64 = 0
        for file in detail.files {
            let destination = cache.fileURL(gameID: gameID, file: file)
            if FileManager.default.fileExists(atPath: destination.path) {
                // A same-named file from an older version of the game must not count as current.
                guard try Self.sha256(of: destination) == file.id.lowercased() else {
                    try FileManager.default.removeItem(at: destination)
                    let base = finished
                    try await downloadFile(gameID: gameID, file: file) { received in
                        progress(.init(receivedBytes: base + received, totalBytes: total))
                    }
                    finished += file.size
                    continue
                }
                finished += file.size
                progress(.init(receivedBytes: finished, totalBytes: total))
                continue
            }
            let base = finished
            try await downloadFile(gameID: gameID, file: file) { received in
                progress(.init(receivedBytes: base + received, totalBytes: total))
            }
            finished += file.size
        }
        let cached = CachedGame(detail: detail, downloadedAt: Date())
        try cache.writeManifest(cached)
        return cached
    }

    func downloadFile(gameID: String, file: GameFileInfo, progress: @escaping @Sendable (Int64) -> Void) async throws {
        let part = cache.partialURL(gameID: gameID, file: file)
        if !FileManager.default.fileExists(atPath: part.path) { FileManager.default.createFile(atPath: part.path, contents: nil) }
        var hasher = SHA256()
        var offset = try Hashing.update(&hasher, withContentsOf: part)
        if offset > file.size {
            try Data().write(to: part)
            hasher = SHA256()
            offset = 0
        }

        if offset < file.size {
            var request = URLRequest(url: client.baseURL.appending(path: client.filePath(gameID: gameID, fileID: file.id)))
            if let token = client.token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
            if offset > 0 { request.setValue("bytes=\(offset)-", forHTTPHeaderField: "Range") }
            hasher = try await delegate.stream(request, session: session, to: part, offset: offset, hasher: hasher, progress: progress)
        }

        let digest = hasher.finalize().hexString
        guard digest == file.id.lowercased() else {
            try? FileManager.default.removeItem(at: part)
            throw DownloadError.checksumMismatch(filename: file.filename)
        }
        let destination = cache.fileURL(gameID: gameID, file: file)
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.moveItem(at: part, to: destination)
    }

    static func sha256(of url: URL) throws -> String {
        try Hashing.sha256Hex(ofFileAt: url)
    }
}

/// Streams response bodies straight to disk so large discs never sit in memory.
final class StreamingDelegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private struct Transfer {
        var handle: FileHandle
        var hasher: SHA256
        var offset: Int64
        var received: Int64
        var progress: @Sendable (Int64) -> Void
        var continuation: CheckedContinuation<SHA256, Error>
        var failure: Error?
    }

    private let trust: GameDownloader.TrustHandler?
    private let lock = NSLock()
    private var transfers: [Int: Transfer] = [:]

    init(trust: GameDownloader.TrustHandler?) { self.trust = trust }

    func stream(_ request: URLRequest, session: URLSession, to url: URL, offset: Int64, hasher: SHA256,
                progress: @escaping @Sendable (Int64) -> Void) async throws -> SHA256 {
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        let task = session.dataTask(with: request)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                lock.withLock {
                    transfers[task.taskIdentifier] = Transfer(handle: handle, hasher: hasher, offset: offset, received: offset,
                                                              progress: progress, continuation: continuation)
                }
                progress(offset)
                task.resume()
            }
        } onCancel: {
            task.cancel()
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let disposition: URLSession.ResponseDisposition = lock.withLock {
            guard var transfer = transfers[dataTask.taskIdentifier] else { return .cancel }
            switch status {
            case 206:
                let range = (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Range") ?? ""
                guard Self.rangeStart(range) == transfer.offset else { transfer.failure = DownloadError.unexpectedRange; break }
                transfers[dataTask.taskIdentifier] = transfer
                return .allow
            case 200:
                // The server ignored the Range header: start the file over.
                do {
                    try transfer.handle.truncate(atOffset: 0)
                    transfer.hasher = SHA256()
                    transfer.offset = 0
                    transfer.received = 0
                    transfers[dataTask.taskIdentifier] = transfer
                    return .allow
                } catch { transfer.failure = error }
            case 416:
                transfer.failure = DownloadError.unexpectedRange
            default:
                transfer.failure = DownloadError.http(status: status)
            }
            transfers[dataTask.taskIdentifier] = transfer
            return .cancel
        }
        completionHandler(disposition)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        let update: (@Sendable (Int64) -> Void, Int64)? = lock.withLock {
            guard var transfer = transfers[dataTask.taskIdentifier] else { return nil }
            do {
                try transfer.handle.write(contentsOf: data)
                transfer.hasher.update(data: data)
                transfer.received += Int64(data.count)
            } catch {
                transfer.failure = error
                dataTask.cancel()
            }
            transfers[dataTask.taskIdentifier] = transfer
            return (transfer.progress, transfer.received)
        }
        if let (progress, received) = update { progress(received) }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let transfer = lock.withLock({ transfers.removeValue(forKey: task.taskIdentifier) }) else { return }
        try? transfer.handle.synchronize()
        try? transfer.handle.close()
        if let failure = transfer.failure ?? error {
            transfer.continuation.resume(throwing: failure)
        } else {
            transfer.continuation.resume(returning: transfer.hasher)
        }
    }

    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        if let trust {
            let (disposition, credential) = trust(challenge)
            completionHandler(disposition, credential)
        } else {
            completionHandler(.performDefaultHandling, nil)
        }
    }

    /// "bytes 100-199/200" -> 100
    static func rangeStart(_ header: String) -> Int64? {
        guard let range = header.split(separator: " ").last?.split(separator: "-").first else { return nil }
        return Int64(range)
    }
}

// MARK: Pairing links

public enum PairingLinkParser {
    public static let defaultPort = 8487

    /// Parses `supersemu://pair?d=<base64url(JSON PairingPayload)>`.
    public static func payload(fromLink link: String) -> PairingPayload? {
        try? PairingLink.payload(from: link.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// Typed entry: "mac-mini.local", "192.168.1.20:8487" or a full URL, plus the 6-digit code.
    public static func payload(address: String, code: String) -> PairingPayload? {
        let digits = code.filter(\.isNumber)
        guard digits.count == 6, let url = serverURL(fromAddress: address) else { return nil }
        return PairingPayload(serverName: url.host ?? address, urls: [url], certificateSHA256: nil, code: digits)
    }

    public static func serverURL(fromAddress address: String) -> URL? {
        var text = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        // The server speaks HTTPS (pinned self-signed cert); plain HTTP only when typed explicitly.
        if !text.contains("://") { text = "https://" + text }
        guard var components = URLComponents(string: text), let host = components.host, !host.isEmpty,
              ["http", "https"].contains(components.scheme?.lowercased() ?? "") else { return nil }
        if components.port == nil { components.port = defaultPort }
        components.path = ""
        components.query = nil
        return components.url
    }

    public static func publicURLCandidate(fromAddress address: String) -> URL? {
        var text = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if !text.contains("://") { text = "https://" + text }
        guard let components = URLComponents(string: text), let host = components.host?.lowercased(),
              components.port == nil, components.scheme?.lowercased() == "https",
              !host.hasSuffix(".local"), !isIPAddress(host) else { return nil }
        return URL(string: "https://\(host)")
    }

    private static func isIPAddress(_ host: String) -> Bool {
        if host.contains(":") { return true }
        let parts = host.split(separator: ".", omittingEmptySubsequences: false)
        return parts.count == 4 && parts.allSatisfy { part in
            guard let value = UInt8(part) else { return false }
            return String(value) == part
        }
    }

    public static func link(for payload: PairingPayload) throws -> String {
        try PairingLink.url(for: payload).absoluteString
    }
}
