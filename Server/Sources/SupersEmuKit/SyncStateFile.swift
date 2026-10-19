import Foundation
import os

/// Reads and writes the small JSON files the sync engines keep their bookkeeping in, all in the `SupersEmuJSON`
/// format. Writes throw so callers that can still undo a change (e.g. queueing an upload) report the failure.
enum SyncStateFile {
    private static let logger = Logger(subsystem: "com.chadillac6.supersemu", category: "sync-state")

    static func read<Value: Decodable>(_ type: Value.Type, from url: URL) -> Value? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        if let value = try? SupersEmuJSON.decoder().decode(type, from: data) { return value }
        // Save sync state written before the shared format stored dates as seconds since 2001.
        return try? JSONDecoder().decode(type, from: data)
    }

    static func write<Value: Encodable>(_ value: Value, to url: URL) throws {
        try SupersEmuJSON.encoder().encode(value).write(to: url, options: .atomic)
    }

    /// For bookkeeping the caller can't undo or report: the in-memory state stays current and the next successful
    /// write catches the file up.
    static func writeOrLog<Value: Encodable>(_ value: Value, to url: URL) {
        do {
            try write(value, to: url)
        } catch {
            logger.error("Couldn't save \(url.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }
}
