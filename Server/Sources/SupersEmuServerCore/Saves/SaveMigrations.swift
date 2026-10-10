import GRDB

enum SaveMigrations {
    static func register(_ migrator: inout DatabaseMigrator) {
        migrator.registerMigration("v2_saves") { db in
            try db.execute(sql: """
                ALTER TABLE save_revisions ADD COLUMN branched INTEGER NOT NULL DEFAULT 0;
                -- A copy kept only as a branch (?branch=1): listed, downloadable, never the line head.
                ALTER TABLE save_revisions ADD COLUMN detached INTEGER NOT NULL DEFAULT 0;
                -- The revision each device last uploaded or downloaded per line; retention never prunes these,
                -- so a device that was away can still prove the head descends from its copy.
                CREATE TABLE save_device_bases (
                    user_id TEXT NOT NULL, device_id TEXT NOT NULL, game_id TEXT NOT NULL, kind TEXT NOT NULL,
                    slot TEXT NOT NULL, revision_id TEXT NOT NULL,
                    PRIMARY KEY (device_id, game_id, kind, slot)
                );
                CREATE INDEX save_revisions_content ON save_revisions (user_id, game_id, kind, slot, sha256);
                """)
        }
    }
}
