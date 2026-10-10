import GRDB

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
    }
}
