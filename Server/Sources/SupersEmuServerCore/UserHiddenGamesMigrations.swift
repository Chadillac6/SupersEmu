import GRDB

enum UserHiddenGamesMigrations {
    static func register(_ migrator: inout DatabaseMigrator) {
        migrator.registerMigration("v8_user_hidden_games") { db in
            try db.execute(sql: """
                CREATE TABLE user_hidden_games (
                    user_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
                    game_id TEXT NOT NULL REFERENCES games(id) ON DELETE CASCADE,
                    PRIMARY KEY (user_id, game_id)
                );
                """)
            for event in ["INSERT", "UPDATE", "DELETE"] {
                try db.execute(sql: """
                    CREATE TRIGGER library_revision_user_hidden_games_\(event.lowercased())
                    AFTER \(event) ON user_hidden_games
                    BEGIN
                        UPDATE library_revision SET value = value + 1 WHERE id = 1;
                    END;
                    """)
            }
        }
    }
}
