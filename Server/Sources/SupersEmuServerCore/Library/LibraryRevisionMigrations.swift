import GRDB

enum LibraryRevisionMigrations {
    static func register(_ migrator: inout DatabaseMigrator) {
        migrator.registerMigration("v6_library_revision") { db in
            try db.execute(sql: """
                CREATE TABLE library_revision (
                    id INTEGER PRIMARY KEY CHECK (id = 1),
                    value INTEGER NOT NULL
                );
                INSERT INTO library_revision (id, value) VALUES (1, 1);
                """)

            for table in ["games", "game_metadata", "game_artwork", "game_permissions", "group_members"] {
                for event in ["INSERT", "UPDATE", "DELETE"] {
                    try db.execute(sql: """
                        CREATE TRIGGER library_revision_\(table)_\(event.lowercased())
                        AFTER \(event) ON \(table)
                        BEGIN
                            UPDATE library_revision SET value = value + 1 WHERE id = 1;
                        END;
                        """)
                }
            }
            for event in ["INSERT", "DELETE"] {
                try db.execute(sql: """
                    CREATE TRIGGER library_revision_metadata_jobs_\(event.lowercased())
                    AFTER \(event) ON metadata_jobs
                    BEGIN
                        UPDATE library_revision SET value = value + 1 WHERE id = 1;
                    END;
                    """)
            }
            try db.execute(sql: """
                CREATE TRIGGER library_revision_metadata_jobs_update
                AFTER UPDATE ON metadata_jobs
                WHEN OLD.match_status IS NOT NEW.match_status
                    OR OLD.artwork_status IS NOT NEW.artwork_status
                    OR OLD.dataset_version IS NOT NEW.dataset_version
                    OR OLD.artwork_version IS NOT NEW.artwork_version
                    OR OLD.search_title IS NOT NEW.search_title
                BEGIN
                    UPDATE library_revision SET value = value + 1 WHERE id = 1;
                END;
                """)
        }
    }
}
