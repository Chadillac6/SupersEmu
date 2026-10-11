import Foundation
import GRDB
import SupersEmuKit

enum LibraryMigrations {
    static func register(_ migrator: inout DatabaseMigrator) {
        migrator.registerMigration("v1_library") { db in
            try db.execute(sql: """
                ALTER TABLE games ADD COLUMN review_reason TEXT;
                CREATE INDEX games_needs_review ON games (needs_review);
                """)
        }
        // M2: BIOS files. `verified = 0` rows record a file named like a known BIOS whose hash didn't match;
        // their bytes are not stored (stored_path is NULL) and they are never served.
        migrator.registerMigration("v2_library_bios") { db in
            try db.execute(sql: """
                CREATE TABLE bios_files (
                    id TEXT PRIMARY KEY,
                    filename TEXT NOT NULL,
                    original_filename TEXT NOT NULL,
                    system TEXT NOT NULL,
                    region TEXT,
                    required INTEGER NOT NULL,
                    verified INTEGER NOT NULL,
                    size INTEGER NOT NULL,
                    stored_path TEXT,
                    created_at DATETIME NOT NULL
                );
                """)
        }
        MetadataMigrations.register(&migrator)
        // M3: what the last Incoming scan couldn't settle, so Review Needed can explain and fix files left in Incoming.
        migrator.registerMigration("v3_library_issues") { db in
            try db.execute(sql: """
                CREATE TABLE import_issues (
                    id TEXT PRIMARY KEY,
                    path TEXT NOT NULL,
                    reason TEXT NOT NULL,
                    review_id TEXT,
                    created_at DATETIME NOT NULL
                );
                """)
        }
        migrator.registerMigration("v4_library_game_updated_at") { db in
            try db.execute(sql: """
                ALTER TABLE games ADD COLUMN updated_at DATETIME;
                UPDATE games SET updated_at = created_at;
                """)
        }
        migrator.registerMigration("v5_library_hash_prefix_titles") { db in
            let games = try Row.fetchAll(db, sql: "SELECT id, title FROM games")
            for game in games {
                let title: String = game["title"]
                guard TitleNormalizer.hasHashPrefix(title) else { continue }
                let id: String = game["id"]
                try db.execute(
                    sql: "UPDATE games SET title = ?, updated_at = ? WHERE id = ?",
                    arguments: [TitleNormalizer.title(fromFilename: title), Date(), id])
            }
        }
    }
}
