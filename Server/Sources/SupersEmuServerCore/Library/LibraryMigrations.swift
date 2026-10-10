import GRDB

enum LibraryMigrations {
    static func register(_ migrator: inout DatabaseMigrator) {
        migrator.registerMigration("v1_library") { db in
            try db.execute(sql: """
                ALTER TABLE games ADD COLUMN review_reason TEXT;
                CREATE INDEX games_needs_review ON games (needs_review);
                """)
        }
    }
}
