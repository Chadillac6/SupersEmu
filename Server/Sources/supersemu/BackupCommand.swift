import ArgumentParser
import Foundation
import SupersEmuKit

struct Backup: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "backup",
        abstract: "Server backups: database, save revisions, BIOS index and settings (ROMs optional).",
        subcommands: [Create.self, List.self, Restore.self, Config.self])

    static func size(_ bytes: Int64) -> String { ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file) }

    struct Create: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Back up now and verify it.")
        @OptionGroup var connection: Connection
        @Flag(inversion: .prefixedNo, help: "Also copy ROMs and BIOS files (default: the configured setting).")
        var includeRoms: Bool?

        func run() async throws {
            try await CLIOutput.run(json: connection.json) {
                let info = try await connection.client().createBackup(.init(includeROMs: includeRoms))
                if connection.json { return try CLIOutput.json(info) }
                CLIOutput.stdout("Backed up \(info.id) (\(info.fileCount) files, \(Backup.size(info.sizeBytes))\(info.includesROMs ? ", with ROMs" : "")) to \(info.path)")
            }
        }
    }

    struct List: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Backups in the destination, newest first, plus the last result and next run.")
        @OptionGroup var connection: Connection
        @Flag(help: "Re-check every backup's checksums and database integrity.")
        var verify = false

        func run() async throws {
            try await CLIOutput.run(json: connection.json) {
                let client = try connection.client()
                let overview = try await client.backups()
                var verified: [String: String] = [:]
                if verify {
                    for backup in overview.backups {
                        do {
                            _ = try await client.verifyBackup(backup.id)
                            verified[backup.id] = "ok"
                        } catch {
                            verified[backup.id] = "FAILED: \(CLIError(error).description)"
                        }
                    }
                }
                if connection.json { return try CLIOutput.json(overview) }
                CLIOutput.stdout("Destination: \(overview.destination)\(overview.destinationAvailable ? "" : " (not available)")")
                if let last = overview.last {
                    CLIOutput.stdout("Last backup: \(CLIOutput.date(last.at)) \(last.trigger.rawValue), \(last.ok ? "ok" : "failed: \(last.error ?? "")")")
                }
                CLIOutput.stdout("Next scheduled: \(overview.nextScheduledAt.map { CLIOutput.date($0) } ?? "off")")
                CLIOutput.table(["ID", "CREATED", "SIZE", "FILES", "ROMS"] + (verify ? ["VERIFY"] : []), overview.backups.map {
                    [$0.id, CLIOutput.date($0.createdAt), Backup.size($0.sizeBytes), "\($0.fileCount)", $0.includesROMs ? "yes" : "no"]
                        + (verify ? [verified[$0.id] ?? "-"] : [])
                })
            }
        }
    }

    struct Restore: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Restore a backup. The server verifies it, stops serving, replaces its data and restarts.",
            discussion: "Saves and changes made after the backup are replaced; the previous data is kept in a new <data dir>/.pre-restore-<date> folder.")
        @OptionGroup var connection: Connection
        @Argument(help: "Backup ID from `supersemu backup list`.")
        var id: String
        @Flag(help: "Confirm replacing the server's current data.")
        var yes = false
        @Flag(help: "Return once the server accepts the restore instead of waiting for it to come back.")
        var noWait = false

        func run() async throws {
            try await CLIOutput.run(json: connection.json) {
                guard yes else { throw CLIError.usage("Restoring replaces the server's current data. Re-run with --yes to confirm.") }
                let resolved = try connection.resolve()
                let response = try await connection.client().restoreBackup(id)
                // The backup brings back its own TLS certificate; follow it (it came over the pinned connection).
                let newPin = response.certificateSHA256.flatMap { pin in
                    resolved.certificateSHA256 != nil && pin != resolved.certificateSHA256 ? pin : nil
                }
                if !noWait {
                    let restored = Connection.Resolved(server: resolved.server, token: resolved.token,
                                                       certificateSHA256: newPin ?? resolved.certificateSHA256)
                    let client = APIClient(baseURL: restored.server, token: restored.token, session: try Connection.session(for: restored))
                    try await Task.sleep(for: .seconds(2))
                    var healthy = false
                    for _ in 0..<60 {
                        if (try? await client.health()) != nil { healthy = true; break }
                        try await Task.sleep(for: .seconds(1))
                    }
                    guard healthy else { throw CLIError.unreachable("Server didn't come back within a minute after the restore") }
                }
                if connection.json { return try CLIOutput.json(response) }
                CLIOutput.stdout(noWait ? response.message : "Restored \(response.backup.id); the server is serving again.")
                if let newPin {
                    CLIOutput.stdout("The server's certificate is the backup's again (SHA-256 \(newPin)). Update certificateSHA256 in your CLI config; devices paired before the backup keep working.")
                }
            }
        }
    }

    struct Config: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Show or change where backups go, how many to keep and when they run.")
        @OptionGroup var connection: Connection
        @Option(help: "Destination folder, e.g. /Volumes/Backup/SupersEmu. Pass \"\" for the default (<data dir>/Backups).")
        var destination: String?
        @Option(help: "Number of backups to keep.")
        var keep: Int?
        @Option(help: "Local hour (0-23) of the daily backup.")
        var hour: Int?
        @Flag(inversion: .prefixedNo, help: "Include ROMs and BIOS files in backups.")
        var includeRoms: Bool?
        @Flag(inversion: .prefixedNo, help: "Run the daily backup.")
        var schedule: Bool?

        func run() async throws {
            try await CLIOutput.run(json: connection.json) {
                let client = try connection.client()
                let update = BackupConfigUpdate(destination: destination, keep: keep, includeROMs: includeRoms, scheduleEnabled: schedule, hour: hour)
                let config = update == BackupConfigUpdate() ? try await client.backupConfig() : try await client.updateBackupConfig(update)
                if connection.json { return try CLIOutput.json(config) }
                CLIOutput.stdout("Destination: \(config.destination ?? "<data dir>/Backups (default)")")
                CLIOutput.stdout("Keep: \(config.keep)")
                CLIOutput.stdout("Include ROMs: \(config.includeROMs ? "yes" : "no")")
                CLIOutput.stdout("Schedule: \(config.scheduleEnabled ? String(format: "daily at %02d:00", config.hour) : "off")")
            }
        }
    }
}
