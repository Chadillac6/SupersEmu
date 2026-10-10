import Foundation
import Logging

/// Runs the daily backup inside the daemon. Re-reads the config at least hourly, so schedule changes apply without a restart.
enum BackupScheduler {
    static func run(_ backups: BackupManager, logger: Logger) async {
        while !Task.isCancelled {
            guard let next = await backups.nextScheduledRun() else {
                try? await Task.sleep(for: .seconds(3600))
                continue
            }
            let wait = next.timeIntervalSinceNow
            if wait > 0 {
                try? await Task.sleep(for: .seconds(min(wait, 3600)))
                continue
            }
            do {
                let info = try await backups.create(trigger: .scheduled)
                logger.info("Scheduled backup \(info.id) written to \(info.path)")
            } catch {
                logger.error("Scheduled backup failed: \(error)")
            }
            try? await Task.sleep(for: .seconds(60))
        }
    }
}
