import Foundation

// Track: backups. /v1/admin/backups (admin only).

public struct BackupConfig: Codable, Sendable, Equatable {
    /// Folder that receives backups, e.g. `/Volumes/Backup/SupersEmu`. `nil` means `<data dir>/Backups`.
    public var destination: String?
    /// How many complete backups to keep; older ones are deleted after each successful backup.
    public var keep: Int
    /// Also copy ROMs (`games/`) and BIOS files. Off by default: they're large and can be re-imported.
    public var includeROMs: Bool
    public var scheduleEnabled: Bool
    /// Local hour (0–23) of the daily backup.
    public var hour: Int

    public init(destination: String? = nil, keep: Int = 7, includeROMs: Bool = false, scheduleEnabled: Bool = true, hour: Int = 3) {
        self.destination = destination
        self.keep = keep
        self.includeROMs = includeROMs
        self.scheduleEnabled = scheduleEnabled
        self.hour = hour
    }
}

/// Partial update for `PUT /v1/admin/backups/config`. An empty `destination` resets it to the default.
public struct BackupConfigUpdate: Codable, Sendable, Equatable {
    public var destination: String?
    public var keep: Int?
    public var includeROMs: Bool?
    public var scheduleEnabled: Bool?
    public var hour: Int?

    public init(destination: String? = nil, keep: Int? = nil, includeROMs: Bool? = nil, scheduleEnabled: Bool? = nil, hour: Int? = nil) {
        self.destination = destination
        self.keep = keep
        self.includeROMs = includeROMs
        self.scheduleEnabled = scheduleEnabled
        self.hour = hour
    }
}

public struct BackupInfo: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var createdAt: Date
    public var path: String
    public var sizeBytes: Int64
    public var fileCount: Int
    public var includesROMs: Bool
    public var serverVersion: String

    public init(id: String, createdAt: Date, path: String, sizeBytes: Int64, fileCount: Int, includesROMs: Bool, serverVersion: String) {
        self.id = id
        self.createdAt = createdAt
        self.path = path
        self.sizeBytes = sizeBytes
        self.fileCount = fileCount
        self.includesROMs = includesROMs
        self.serverVersion = serverVersion
    }
}

public enum BackupTrigger: String, Codable, Sendable { case scheduled, manual }

public struct BackupRunResult: Codable, Sendable, Equatable {
    public var at: Date
    public var trigger: BackupTrigger
    public var ok: Bool
    public var backupID: String?
    public var error: String?

    public init(at: Date, trigger: BackupTrigger, ok: Bool, backupID: String? = nil, error: String? = nil) {
        self.at = at
        self.trigger = trigger
        self.ok = ok
        self.backupID = backupID
        self.error = error
    }
}

public struct BackupOverview: Codable, Sendable, Equatable {
    public var config: BackupConfig
    /// Resolved destination folder.
    public var destination: String
    /// False when the destination (or the external drive it lives on) isn't there.
    public var destinationAvailable: Bool
    public var last: BackupRunResult?
    public var lastSuccessAt: Date?
    public var nextScheduledAt: Date?
    public var running: Bool
    public var backups: [BackupInfo]

    public init(config: BackupConfig, destination: String, destinationAvailable: Bool, last: BackupRunResult?, lastSuccessAt: Date?,
                nextScheduledAt: Date?, running: Bool, backups: [BackupInfo]) {
        self.config = config
        self.destination = destination
        self.destinationAvailable = destinationAvailable
        self.last = last
        self.lastSuccessAt = lastSuccessAt
        self.nextScheduledAt = nextScheduledAt
        self.running = running
        self.backups = backups
    }
}

public struct CreateBackupRequest: Codable, Sendable, Equatable {
    /// Overrides the configured `includeROMs` for this backup.
    public var includeROMs: Bool?
    public init(includeROMs: Bool? = nil) { self.includeROMs = includeROMs }
}

public struct RestoreBackupResponse: Codable, Sendable, Equatable {
    public var backup: BackupInfo
    public var message: String
    /// The restored server's certificate (the backup's), so a pinned client can follow it.
    public var certificateSHA256: String?
    public init(backup: BackupInfo, message: String, certificateSHA256: String? = nil) {
        self.backup = backup
        self.message = message
        self.certificateSHA256 = certificateSHA256
    }
}

extension APIClient {
    public func backups() async throws -> BackupOverview { try await get("/v1/admin/backups") }
    public func createBackup(_ request: CreateBackupRequest = .init()) async throws -> BackupInfo {
        try await send("POST", "/v1/admin/backups", body: request)
    }
    public func verifyBackup(_ id: String) async throws -> BackupInfo {
        try await send("POST", "/v1/admin/backups/\(id)/verify", body: Optional<String>.none)
    }
    /// Verifies the backup, then the server stops serving, restores it and comes back up.
    public func restoreBackup(_ id: String) async throws -> RestoreBackupResponse {
        try await send("POST", "/v1/admin/backups/\(id)/restore", body: Optional<String>.none)
    }
    public func backupConfig() async throws -> BackupConfig { try await get("/v1/admin/backups/config") }
    public func updateBackupConfig(_ update: BackupConfigUpdate) async throws -> BackupConfig {
        try await send("PUT", "/v1/admin/backups/config", body: update)
    }
}
