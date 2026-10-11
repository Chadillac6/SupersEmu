import GRDB

enum MetadataMigrations {
    static func register(_ migrator: inout DatabaseMigrator) {
        // One row per (game, provider); every field optional. `MetadataMerge` picks per field by provider precedence,
        // falling back to what the importer stored in `games`.
        // `metadata_jobs.match_status`: 'matched' / 'unmatched'; NULL or a stale `dataset_version` means try again.
        // `artwork_status` is 'done' once every artwork candidate was tried without a network error.
        migrator.registerMigration("v3_metadata") { db in
            try db.execute(sql: """
                CREATE TABLE game_metadata (
                    game_id TEXT NOT NULL REFERENCES games(id) ON DELETE CASCADE,
                    provider TEXT NOT NULL,
                    provider_ref TEXT,
                    title TEXT,
                    region TEXT,
                    year INTEGER,
                    publisher TEXT,
                    developer TEXT,
                    genres TEXT,
                    description TEXT,
                    players INTEGER,
                    critic_score INTEGER,
                    critic_source TEXT,
                    critic_url TEXT,
                    source_name TEXT,
                    source_url TEXT,
                    updated_at DATETIME NOT NULL,
                    PRIMARY KEY (game_id, provider)
                );
                CREATE TABLE game_artwork (
                    game_id TEXT NOT NULL REFERENCES games(id) ON DELETE CASCADE,
                    provider TEXT NOT NULL,
                    kind TEXT NOT NULL,
                    position INTEGER NOT NULL DEFAULT 0,
                    path TEXT NOT NULL,
                    source_url TEXT,
                    updated_at DATETIME NOT NULL,
                    PRIMARY KEY (game_id, provider, kind, position)
                );
                CREATE TABLE metadata_jobs (
                    game_id TEXT NOT NULL REFERENCES games(id) ON DELETE CASCADE,
                    provider TEXT NOT NULL,
                    match_status TEXT,
                    artwork_status TEXT,
                    dataset_version TEXT,
                    updated_at DATETIME NOT NULL,
                    PRIMARY KEY (game_id, provider)
                );
                """)
        }
        migrator.registerMigration("v4_metadata_artwork_version") { db in
            try db.execute(sql: "ALTER TABLE metadata_jobs ADD COLUMN artwork_version TEXT")
        }
    }

    static func registerReviews(_ migrator: inout DatabaseMigrator) {
        // Reviews (Wikipedia reception, IGDB/IGN link) and artwork URLs a provider found during lookup (SteamGridDB).
        migrator.registerMigration("v5_metadata_reviews") { db in
            for column in ["reception", "reception_source", "reception_url", "review_name", "review_url", "artwork_urls"] {
                try db.execute(sql: "ALTER TABLE game_metadata ADD COLUMN \(column) TEXT")
            }
            // The title a name-searching provider looked up; an unmatched game is retried when a better title appears.
            try db.execute(sql: "ALTER TABLE metadata_jobs ADD COLUMN search_title TEXT")
        }
    }
}
