import GRDB

// Track: cheats. One row per cheat; deletes are kept as tombstones so other devices learn about them.
enum CheatMigrations {
    static func register(_ migrator: inout DatabaseMigrator) {
        migrator.registerMigration("v9_cheats") { db in
            try db.execute(sql: """
                CREATE TABLE cheats (
                    user_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
                    id TEXT NOT NULL,
                    game_id TEXT NOT NULL,
                    label TEXT NOT NULL,
                    code TEXT NOT NULL,
                    format TEXT NOT NULL,
                    enabled INTEGER NOT NULL,
                    created_at REAL NOT NULL,
                    label_updated_at REAL NOT NULL,
                    code_updated_at REAL NOT NULL,
                    enabled_updated_at REAL NOT NULL,
                    deleted INTEGER NOT NULL DEFAULT 0,
                    deleted_at REAL,
                    revision INTEGER NOT NULL,
                    updated_by_device TEXT,
                    PRIMARY KEY (user_id, id)
                );
                CREATE INDEX cheats_user_game ON cheats(user_id, game_id);
                CREATE INDEX cheats_user_revision ON cheats(user_id, revision);
                """)
        }
    }
}
