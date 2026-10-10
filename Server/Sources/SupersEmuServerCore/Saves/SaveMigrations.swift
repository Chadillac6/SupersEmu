import GRDB

enum SaveMigrations {
    static func register(_ migrator: inout DatabaseMigrator) {
        migrator.registerMigration("v2_saves") { db in
            try db.execute(sql: """
                ALTER TABLE save_revisions ADD COLUMN branched INTEGER NOT NULL DEFAULT 0;
                CREATE INDEX save_revisions_content ON save_revisions (user_id, game_id, kind, slot, sha256);
                """)
        }
    }
}
